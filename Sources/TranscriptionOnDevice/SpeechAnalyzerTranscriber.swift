#if canImport(Speech)
import AVFoundation
import Foundation
import Logging
import Speech
import TranscriptionShared

/// On-device `AudioTranscriber` backed by the OS 26 `SpeechAnalyzer` +
/// `SpeechTranscriber` engine (the same one behind Apple Intelligence
/// transcription in Notes / Voice Memos). Higher accuracy than the legacy
/// `SFSpeechRecognizer`, handles long-form audio, fully on-device.
///
/// The first request for a given locale may trigger a model download via
/// `AssetInventory`; the call blocks until installation completes.
///
/// Transport-agnostic: takes a file URL and returns plain text, so it links no
/// HTTP server stack and runs identically on macOS, iOS, iPadOS, and visionOS.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public struct SpeechAnalyzerTranscriber: AudioTranscriber {
    public let locale: Locale
    public let logger: Logger

    public init(locale: Locale = .init(identifier: "en-US"),
                logger: Logger = Logger(label: "speech-analyzer")) {
        self.locale = locale
        self.logger = logger
    }

    public func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        guard SpeechTranscriber.isAvailable else {
            throw OnDeviceServiceError.unavailable(
                "SpeechTranscriber is not available on this device"
            )
        }

        let requestedLocale = language.map(Locale.init(identifier:)) ?? locale

        // Resolve a supported locale equivalent (e.g. `en-CA` -> `en-US` if
        // the device only has en-US installed/downloadable).
        guard let effectiveLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw OnDeviceServiceError.badRequest(
                "locale \(requestedLocale.identifier) is not supported by SpeechTranscriber"
            )
        }

        let transcriber = SpeechTranscriber(locale: effectiveLocale, preset: .transcription)

        // Ensure the on-device assets for this locale are installed. The
        // first request for a new locale can trigger a one-time download.
        try await ensureAssetsInstalled(for: transcriber)

        // Collect every result phrase as it arrives, joining into a single
        // transcript. We materialise the AttributedString into a plain
        // String for the OpenAI-compatible response.
        let streamLogger = logger
        let resultsTask = Task { () -> String in
            var combined = AttributedString()
            do {
                for try await result in transcriber.results {
                    combined.append(result.text)
                }
            } catch {
                // Surface partial transcripts even if the stream errors, but
                // log the error so production failures are diagnosable.
                streamLogger.error(
                    "SpeechTranscriber result stream errored; returning partial transcript",
                    metadata: ["error": .string(String(describing: error))]
                )
            }
            return String(combined.characters)
        }

        // Ensure resultsTask is always canceled on error paths so it cannot
        // leak or hang waiting on a stream that will never finish.
        defer { resultsTask.cancel() }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: audioFileURL)
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } catch {
            // Cancel explicitly before awaiting so the stream unblocks
            // immediately. The defer is a safety net for other exit paths.
            resultsTask.cancel()
            _ = await resultsTask.value
            throw error
        }

        return await resultsTask.value
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
            throw OnDeviceServiceError.unavailable(
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
#endif
