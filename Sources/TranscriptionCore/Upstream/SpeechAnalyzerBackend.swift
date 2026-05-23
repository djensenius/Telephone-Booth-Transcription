#if canImport(Speech) && os(macOS)
import AVFoundation
import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import Speech

/// Transcription backend that uses macOS 26's `SpeechAnalyzer` +
/// `SpeechTranscriber` — the same engine that powers Apple Intelligence
/// transcription in Notes and Voice Memos. Higher accuracy than the legacy
/// `SFSpeechRecognizer`, handles long-form audio, fully on-device.
///
/// The first request for a given locale may trigger a model download via
/// `AssetInventory`; the request will block until installation completes.
@available(macOS 26.0, *)
public struct SpeechAnalyzerBackend: TranscriptionBackendImpl {
    public let locale: Locale
    public let logger: Logger

    public init(locale: Locale = .init(identifier: "en-US"),
                logger: Logger = Logger(label: "speech-analyzer")) {
        self.locale = locale
        self.logger = logger
    }

    public func handle(body: ByteBuffer, contentType: String) async throws -> Response {
        guard let part = MultipartFilePart.extractFile(from: body, contentType: contentType) else {
            throw TranscriptionBackendError.badRequest("multipart body did not include a `file` field")
        }

        let ext = AudioExtension.from(mimeType: part.mimeType) ?? "wav"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-\(UUID().uuidString).\(ext)")
        try part.data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Resolve a supported locale equivalent (e.g. `en-CA` -> `en-US` if
        // the device only has en-US installed/downloadable).
        guard let effectiveLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionBackendError.badRequest(
                "locale \(locale.identifier) is not supported by SpeechTranscriber"
            )
        }

        let transcriber = SpeechTranscriber(locale: effectiveLocale, preset: .transcription)

        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionBackendError.unauthorized(
                "SpeechTranscriber is not available on this device"
            )
        }

        // Ensure the on-device assets for this locale are installed. The
        // first request for a new locale can trigger a one-time download.
        try await ensureAssetsInstalled(for: transcriber)

        // Collect every result phrase as it arrives, joining into a single
        // transcript. We materialise the AttributedString into a plain
        // String for the OpenAI-compatible response.
        let resultsTask = Task { () -> String in
            var combined = AttributedString()
            do {
                for try await result in transcriber.results {
                    combined.append(result.text)
                }
            } catch {
                // Surface partial transcripts even if the stream errors.
            }
            return String(combined.characters)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: tmp)
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        let text = await resultsTask.value

        let payload = ["text": text]
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func ensureAssetsInstalled(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return
        case .downloading, .supported:
            // For `.downloading` we still join the in-flight download below.
            // `.supported` means assets are available but not yet downloaded.
            break
        case .unsupported:
            throw TranscriptionBackendError.unauthorized(
                "SpeechTranscriber assets are not supported for this locale on this device"
            )
        @unknown default:
            break
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}

#else
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Non-macOS stub: the macOS 26 SpeechAnalyzer is unavailable.
public struct SpeechAnalyzerBackend: TranscriptionBackendImpl {
    public init(locale: Locale = .init(identifier: "en-US")) {}
    public func handle(body: ByteBuffer, contentType: String) async throws -> Response {
        throw TranscriptionBackendError.badRequest(
            "macOS 26 SpeechAnalyzer backend is only available on macOS 26+"
        )
    }
}
#endif
