import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import Testing
import TranscriptionShared
@testable import TranscriptionCore

/// Covers the fully-local (`all local`) path: `POST /v1/audio/translations`
/// served by transcribing on-device and then translating the resulting text,
/// plus the `ServerConfig` helpers that describe and enable that mode.
@Suite("On-device audio translation")
struct OnDeviceTranslationBackendTests {

    // MARK: - Doubles

    private struct StubTranscriber: AudioTranscriber {
        let text: String
        let error: OnDeviceServiceError?

        init(text: String = "", error: OnDeviceServiceError? = nil) {
            self.text = text
            self.error = error
        }

        func transcribe(audioFileURL: URL, language: String?) async throws -> String {
            if let error { throw error }
            return text
        }
    }

    private struct StubTranslator: TextTranslationService {
        let error: OnDeviceServiceError?

        init(error: OnDeviceServiceError? = nil) {
            self.error = error
        }

        func translate(_ input: String, sourceLanguage: String?) async throws -> TranslationResult {
            if let error { throw error }
            return TranslationResult(
                translatedText: "EN(\(input))",
                sourceLanguage: "fr",
                model: "apple-foundation-models"
            )
        }
    }

    // MARK: - Helpers

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

    private func bodyText(_ response: Response) async throws -> String {
        let collector = CollectingBodyWriter()
        try await response.body.write(collector)
        let obj = try JSONSerialization.jsonObject(with: collector.data()) as? [String: Any]
        return (obj?["text"] as? String) ?? ""
    }

    // MARK: - Tests

    @Test func transcribesThenTranslatesTheText() async throws {
        let boundary = "BNDRY-T1"
        let backend = OnDeviceTranslationBackend(
            transcriber: StubTranscriber(text: "bonjour le monde"),
            translator: StubTranslator()
        )

        let response = try await backend.handle(
            body: makeMultipartBody(boundary: boundary, fileBytes: Array(repeating: 0x01, count: 32)),
            contentType: contentType(boundary)
        )

        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json")
        // Wire shape matches the proxy backend so OpenAI clients see no difference.
        #expect(try await bodyText(response) == "EN(bonjour le monde)")
    }

    @Test func emptyTranscriptSkipsTranslation() async throws {
        let boundary = "BNDRY-T2"
        let backend = OnDeviceTranslationBackend(
            transcriber: StubTranscriber(text: "   \n "),
            // Would throw if it were ever called.
            translator: StubTranslator(error: .badRequest("should not be called"))
        )

        let response = try await backend.handle(
            body: makeMultipartBody(boundary: boundary, fileBytes: Array(repeating: 0x02, count: 8)),
            contentType: contentType(boundary)
        )

        #expect(response.status == .ok)
        #expect(try await bodyText(response) == "")
    }

    @Test func mapsTranscriberErrorOntoTranslationBackendError() async throws {
        let boundary = "BNDRY-T3"
        let backend = OnDeviceTranslationBackend(
            transcriber: StubTranscriber(error: .unauthorized("denied")),
            translator: StubTranslator()
        )
        await #expect(throws: TranslationBackendError.self) {
            _ = try await backend.handle(
                body: makeMultipartBody(boundary: boundary, fileBytes: [0x03]),
                contentType: contentType(boundary)
            )
        }
    }

    @Test func mapsTranslatorErrorOntoTranslationBackendError() async throws {
        let boundary = "BNDRY-T4"
        let backend = OnDeviceTranslationBackend(
            transcriber: StubTranscriber(text: "hola"),
            translator: StubTranslator(error: .timeout("slow"))
        )
        await #expect(throws: TranslationBackendError.self) {
            _ = try await backend.handle(
                body: makeMultipartBody(boundary: boundary, fileBytes: [0x04]),
                contentType: contentType(boundary)
            )
        }
    }

    @Test func malformedBodyThrowsBadRequest() async throws {
        let backend = OnDeviceTranslationBackend(
            transcriber: StubTranscriber(text: "unused"),
            translator: StubTranslator()
        )
        await #expect(throws: TranslationBackendError.self) {
            _ = try await backend.handle(
                body: ByteBuffer(bytes: Array("not multipart".utf8)),
                contentType: "text/plain"
            )
        }
    }

    @Test func errorMappingPreservesSemantics() {
        #expect(OnDeviceServiceError.badRequest("x").asTranslationBackendError.isBadRequest)
        #expect(OnDeviceServiceError.timeout("x").asTranslationBackendError.isTimeout)
        // `.unavailable` maps to `.unauthorized` (HTTP 403), matching the
        // transcription route's behavior.
        #expect(OnDeviceServiceError.unavailable("x").asTranslationBackendError.isUnauthorized)
        #expect(OnDeviceServiceError.unauthorized("x").asTranslationBackendError.isUnauthorized)
    }

    // MARK: - All-local config

    @Test func isFullyLocalRequiresEveryRouteOnDevice() {
        var config = ServerConfig(
            transcriptionBackend: .appleSpeechAnalyzer,
            moderationBackend: .onDevice,
            textTranslationBackend: .onDevice,
            audioTranslationBackend: .onDevice
        )
        #expect(config.isFullyLocal)

        config.audioTranslationBackend = .proxy
        #expect(!config.isFullyLocal)

        config.audioTranslationBackend = .onDevice
        config.transcriptionBackend = .proxy(.defaultTranscription)
        #expect(!config.isFullyLocal)

        config.transcriptionBackend = .nativeMacOS
        #expect(config.isFullyLocal)
    }

    @Test func withAllLocalBackendsFlipsEveryRouteAndKeepsUpstreams() {
        let config = ServerConfig(
            transcriptionBackend: .proxy(.init(baseURL: "http://127.0.0.1:9000/v1")),
            moderationBackend: .proxy,
            textTranslationBackend: .proxy,
            audioTranslationBackend: .proxy,
            moderationUpstream: .init(baseURL: "http://127.0.0.1:1234/v1"),
            translationUpstream: .init(baseURL: "http://127.0.0.1:8000/v1")
        )

        let local = config.withAllLocalBackends()

        #expect(local.isFullyLocal)
        #expect(local.transcriptionBackend == .appleSpeechAnalyzer)
        #expect(local.moderationBackend == .onDevice)
        #expect(local.textTranslationBackend == .onDevice)
        #expect(local.audioTranslationBackend == .onDevice)
        // Upstreams survive so the user can switch back without retyping them.
        #expect(local.moderationUpstream.baseURL == "http://127.0.0.1:1234/v1")
        #expect(local.translationUpstream.baseURL == "http://127.0.0.1:8000/v1")
    }

    @Test func withAllLocalBackendsKeepsAnExistingOnDeviceTranscriber() {
        let config = ServerConfig(transcriptionBackend: .nativeMacOS).withAllLocalBackends()
        // Don't silently upgrade a user who deliberately chose the legacy engine.
        #expect(config.transcriptionBackend == .nativeMacOS)
    }
}

private extension TranslationBackendError {
    var isBadRequest: Bool { if case .badRequest = self { return true }; return false }
    var isUnauthorized: Bool { if case .unauthorized = self { return true }; return false }
    var isTimeout: Bool { if case .timeout = self { return true }; return false }
}

/// Drains a `ResponseBody` into memory so tests can assert on the JSON payload.
private final class CollectingBodyWriter: ResponseBodyWriter, @unchecked Sendable {
    private var buffer = ByteBuffer()

    func write(_ buffer: ByteBuffer) async throws {
        var buffer = buffer
        self.buffer.writeBuffer(&buffer)
    }

    func finish(_ trailingHeaders: HTTPFields?) async throws {}

    func data() -> Data {
        Data(buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? [])
    }
}
