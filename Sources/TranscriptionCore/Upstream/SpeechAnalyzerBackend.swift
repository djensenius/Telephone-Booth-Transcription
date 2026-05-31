import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import TranscriptionOnDevice
import TranscriptionShared

/// HTTP adapter exposing the OS 26 `SpeechAnalyzer`-based on-device transcriber
/// (`SpeechAnalyzerTranscriber`) as a `TranscriptionBackendImpl`. All
/// recognition logic lives in `TranscriptionOnDevice`; this type only bridges
/// the multipart request / OpenAI-JSON response shape.
public struct SpeechAnalyzerBackend: TranscriptionBackendImpl {
    public let locale: Locale
    public let logger: Logger

    public init(locale: Locale = .init(identifier: "en-US"),
                logger: Logger = Logger(label: "speech-analyzer")) {
        self.locale = locale
        self.logger = logger
    }

    public func handle(body: ByteBuffer, contentType: String) async throws -> Response {
        #if canImport(Speech)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            let transcriber = SpeechAnalyzerTranscriber(locale: locale, logger: logger)
            return try await OnDeviceTranscriptionAdapter.run(body: body, contentType: contentType) { url in
                try await transcriber.transcribe(audioFileURL: url, language: nil)
            }
        }
        throw TranscriptionBackendError.badRequest(
            "SpeechAnalyzer backend requires macOS 26 / iOS 26 / visionOS 26 or newer"
        )
        #else
        throw TranscriptionBackendError.badRequest(
            "SpeechAnalyzer backend is only available on Apple platforms"
        )
        #endif
    }
}
