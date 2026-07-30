import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
import TranscriptionShared
@testable import TranscriptionCore

@Suite("OnDeviceTranscriptionAdapter")
struct OnDeviceTranscriptionAdapterTests {

    private func makeMultipartBody(boundary: String, fileBytes: [UInt8]) -> ByteBuffer {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: "--\(boundary)\r\n".utf8)
        bytes.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav".utf8)
        bytes.append(contentsOf: [0x0D, 0x0A, 0x0D, 0x0A])
        bytes.append(contentsOf: fileBytes)
        bytes.append(contentsOf: [0x0D, 0x0A])
        bytes.append(contentsOf: "--\(boundary)--\r\n".utf8)
        return ByteBuffer(bytes: bytes)
    }

    private func contentType(_ boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    @Test func runsTranscriberAndReturnsOpenAIJSON() async throws {
        let boundary = "BNDRY1"
        let body = makeMultipartBody(boundary: boundary, fileBytes: Array(repeating: 0x01, count: 32))

        var handedURL: URL?
        let response = try await OnDeviceTranscriptionAdapter.run(
            body: body,
            contentType: contentType(boundary)
        ) { url in
            // The adapter must hand us a real, readable temp file.
            #expect(FileManager.default.fileExists(atPath: url.path))
            handedURL = url
            return "hello world"
        }

        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json")
        #expect(handedURL != nil)
    }

    @Test func missingFilePartThrowsBadRequest() async throws {
        let body = ByteBuffer(bytes: Array("not multipart".utf8))
        await #expect(throws: TranscriptionBackendError.self) {
            _ = try await OnDeviceTranscriptionAdapter.run(
                body: body,
                contentType: "text/plain"
            ) { _ in "unused" }
        }
    }

    @Test func mapsUnauthorizedServiceError() async throws {
        let boundary = "BNDRY2"
        let body = makeMultipartBody(boundary: boundary, fileBytes: Array(repeating: 0x02, count: 16))
        await #expect(throws: TranscriptionBackendError.self) {
            _ = try await OnDeviceTranscriptionAdapter.run(
                body: body,
                contentType: contentType(boundary)
            ) { _ in throw OnDeviceServiceError.unauthorized("denied") }
        }
    }

    @Test func errorMappingPreservesSemantics() {
        #expect(OnDeviceServiceError.badRequest("x").asTranscriptionBackendError.isBadRequest)
        #expect(OnDeviceServiceError.timeout("x").asTranscriptionBackendError.isTimeout)
        // "engine not available on this device" is a capability problem, not an
        // authorization one, so it renders as 503 rather than 403.
        #expect(OnDeviceServiceError.unavailable("x").asTranscriptionBackendError.isUnavailable)
        #expect(OnDeviceServiceError.unauthorized("x").asTranscriptionBackendError.isUnauthorized)
    }
}

private extension TranscriptionBackendError {
    var isBadRequest: Bool { if case .badRequest = self { return true }; return false }
    var isUnauthorized: Bool { if case .unauthorized = self { return true }; return false }
    var isUnavailable: Bool { if case .unavailable = self { return true }; return false }
    var isTimeout: Bool { if case .timeout = self { return true }; return false }
}

/// A backend that always fails, so the route's error mapping can be exercised
/// without an on-device engine (unavailable on CI and the simulator).
private struct ThrowingTranscriptionBackend: TranscriptionBackendImpl {
    let error: TranscriptionBackendError
    func handle(body: ByteBuffer, contentType: String) async throws -> Response { throw error }
}

@Suite("TranscriptionRoute error mapping")
struct TranscriptionRouteErrorTests {
    private func decode(_ response: TestResponse) -> [String: Any]? {
        let bytes = response.body.getBytes(at: response.body.readerIndex,
                                           length: response.body.readableBytes) ?? []
        return (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
    }

    private func send(
        _ error: TranscriptionBackendError,
        expect check: @escaping @Sendable (TestResponse, [String: Any]?) -> Void
    ) async throws {
        let route = TranscriptionRoute<BasicRequestContext>(
            backend: ThrowingTranscriptionBackend(error: error), maxRequestBytes: 1024)
        let router = Router(context: BasicRequestContext.self)
        router.post("/v1/audio/transcriptions", use: route.handle)
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.contentType] = "multipart/form-data; boundary=B"
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers,
                                     body: ByteBuffer(string: "--B--\r\n")) { response in
                check(response, decode(response))
            }
        }
    }

    /// An unavailable engine is a capability problem, not an authorization one:
    /// the caller is authenticated and should retry, so it matches the 503 the
    /// translation and moderation routes already return.
    @Test func unavailableEngineReturns503() async throws {
        try await send(.unavailable("Apple Intelligence is off")) { response, json in
            #expect(response.status == .serviceUnavailable)
            #expect((json?["error"] as? [String: Any])?["code"] as? String == "on_device_unavailable")
        }
    }

    @Test func deniedPermissionStillReturns403() async throws {
        try await send(.unauthorized("speech recognition denied")) { response, json in
            #expect(response.status == .forbidden)
            #expect((json?["error"] as? [String: Any])?["code"] as? String == "permission_denied")
        }
    }
}
