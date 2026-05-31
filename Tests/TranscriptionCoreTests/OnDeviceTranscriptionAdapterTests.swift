import Foundation
import HTTPTypes
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
        // `.unavailable` deliberately maps to `.unauthorized` (HTTP 403).
        #expect(OnDeviceServiceError.unavailable("x").asTranscriptionBackendError.isUnauthorized)
        #expect(OnDeviceServiceError.unauthorized("x").asTranscriptionBackendError.isUnauthorized)
    }
}

private extension TranscriptionBackendError {
    var isBadRequest: Bool { if case .badRequest = self { return true }; return false }
    var isUnauthorized: Bool { if case .unauthorized = self { return true }; return false }
    var isTimeout: Bool { if case .timeout = self { return true }; return false }
}
