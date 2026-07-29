import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import TranscriptionShared

/// `TranslationBackendImpl` that serves `POST /v1/audio/translations` without
/// contacting any network upstream.
///
/// Apple ships no direct speech→English-text model, so this composes the two
/// on-device engines that do exist:
///
/// 1. `AudioTranscriber` (`SpeechAnalyzer` or the legacy `SFSpeechRecognizer`)
///    turns the uploaded audio into text in its source language.
/// 2. `TextTranslationService` (Foundation Models) translates that *text* into
///    English.
///
/// The response shape is identical to the proxy backend's (`{"text": …}`), so
/// OpenAI-compatible clients can't tell the difference.
public struct OnDeviceTranslationBackend: TranslationBackendImpl {
    public let transcriber: any AudioTranscriber
    public let translator: any TextTranslationService
    public let logger: Logger

    public init(
        transcriber: any AudioTranscriber,
        translator: any TextTranslationService,
        logger: Logger = Logger(label: "on-device-audio-translation")
    ) {
        self.transcriber = transcriber
        self.translator = translator
        self.logger = logger
    }

    public func handle(body: ByteBuffer, contentType: String) async throws -> Response {
        let transcript: String
        do {
            transcript = try await OnDeviceAudioFile.withTemporaryFile(
                body: body,
                contentType: contentType
            ) { url in
                try await transcriber.transcribe(audioFileURL: url, language: nil)
            }
        } catch let error as OnDeviceServiceError {
            throw error.asTranslationBackendError
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.textResponse("")
        }

        do {
            let result = try await translator.translate(trimmed, sourceLanguage: nil)
            return Self.textResponse(result.translatedText)
        } catch let error as OnDeviceServiceError {
            throw error.asTranslationBackendError
        }
    }

    private static func textResponse(_ text: String) -> Response {
        let data = (try? JSONEncoder().encode(["text": text])) ?? Data(#"{"text":""}"#.utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

extension OnDeviceServiceError {
    /// Maps the transport-agnostic on-device error onto the translation route's
    /// error type, mirroring `asTranscriptionBackendError`.
    var asTranslationBackendError: TranslationBackendError {
        switch self {
        case .badRequest(let message): return .badRequest(message)
        case .unauthorized(let message): return .unauthorized(message)
        case .timeout(let message): return .timeout(message)
        case .unavailable(let message): return .unauthorized(message)
        }
    }
}
