import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import TranscriptionOnDevice
import TranscriptionShared

/// HTTP adapter exposing the legacy `SFSpeechRecognizer`-based on-device
/// transcriber (`NativeSpeechTranscriber`) as a `TranscriptionBackendImpl`.
/// All recognition logic lives in `TranscriptionOnDevice`; this type only
/// bridges the multipart request / OpenAI-JSON response shape.
public struct NativeMacOSTranscriptionBackend: TranscriptionBackendImpl {
    public let locale: Locale
    public let logger: Logger
    public let transcriptionTimeout: Duration

    public init(locale: Locale = .init(identifier: "en-US"),
                logger: Logger = Logger(label: "native-transcriber"),
                transcriptionTimeout: Duration = .seconds(120)) {
        self.locale = locale
        self.logger = logger
        self.transcriptionTimeout = transcriptionTimeout
    }

    public func handle(body: ByteBuffer, contentType: String) async throws -> Response {
        #if canImport(Speech)
        let transcriber = NativeSpeechTranscriber(
            locale: locale,
            logger: logger,
            transcriptionTimeout: transcriptionTimeout
        )
        return try await OnDeviceTranscriptionAdapter.run(body: body, contentType: contentType) { url in
            try await transcriber.transcribe(audioFileURL: url, language: nil)
        }
        #else
        throw TranscriptionBackendError.badRequest("native transcription is only available on Apple platforms")
        #endif
    }
}
