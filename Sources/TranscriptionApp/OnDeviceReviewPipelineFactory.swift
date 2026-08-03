import Foundation
import TranscriptionOnDevice
import TranscriptionPipeline
import TranscriptionReview
import TranscriptionShared

extension OnDeviceReviewPipeline {
    /// Builds a pipeline backed by Apple Intelligence, or returns `nil` when
    /// this device can do none of it — callers hide the entry points entirely
    /// rather than offering buttons that always fail.
    ///
    /// The capability probe matters beyond the `@available` checks below: a
    /// device can be on a new enough OS and still have Apple Intelligence
    /// disabled, be ineligible, or not have finished downloading the model. The
    /// engines re-check at use time too, since availability can change after
    /// this returns.
    ///
    /// Speech and Foundation Models are gated **separately**, in both
    /// directions: transcription needs only the former, so a device with Apple
    /// Intelligence turned off still gets the transcription queues; and
    /// classifying text the Operator already holds needs only the latter, so a
    /// device whose current locale has no speech model still gets "Get a
    /// recommendation". The pipeline reports each capability independently and
    /// the UI hides just the affordances that aren't backed.
    ///
    /// The speech probe is **locale-aware**, which is why this is `async`:
    /// `SpeechTranscriber.isAvailable` is device-wide, but the transcriber
    /// later rejects a locale with no `SpeechTranscriber` equivalent. Probing
    /// the device alone would build a pipeline — and show a transcribe button —
    /// that always fails for messages with no language hint.
    static func makeAppleIntelligence(locale: Locale = .current) async -> OnDeviceReviewPipeline? {
        let speech = await OnDeviceCapability.isSpeechTranscriptionAvailable(for: locale)
        let transcriber = speech ? makeTranscriber(locale: locale) : nil
        let foundationModels = OnDeviceCapability.isFoundationModelAvailable
        guard transcriber != nil || foundationModels else { return nil }

        let dispatcher = InProcessOperatorJobDispatcher(
            transcriber: transcriber,
            translator: foundationModels ? makeTranslator() : nil,
            moderator: foundationModels ? makeModerator() : nil,
            audioFetcher: URLSessionAudioFetcher()
        )
        return OnDeviceReviewPipeline(
            dispatcher: dispatcher,
            transcriptionModel: Self.appleSpeechAnalyzerModel
        )
    }

    /// Attribution recorded on the Operator for transcripts this device
    /// produces. Matches the identifier the Operator uses for Apple's
    /// `SpeechAnalyzer` engine.
    static let appleSpeechAnalyzerModel = "apple-speech-analyzer"

    private static func makeTranscriber(locale: Locale) -> (any AudioTranscriber)? {
        #if canImport(Speech)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return SpeechAnalyzerTranscriber(locale: locale)
        }
        #endif
        return nil
    }

    private static func makeTranslator() -> (any TextTranslationService)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return FoundationModelsTranslationService()
        }
        #endif
        return nil
    }

    private static func makeModerator() -> (any TextModerationService)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return FoundationModelsModerationService()
        }
        #endif
        return nil
    }
}

extension OnDeviceReviewPipeline.Input {
    /// Adapts an operator review message onto the pipeline's transport-agnostic
    /// input.
    init(_ message: Message) {
        self.init(
            id: message.id,
            audioURL: message.audio.url,
            audioSHA256: message.audio.sha256,
            audioDurationMs: message.audio.durationMs,
            language: message.latestTranscription?.language
        )
    }
}

@MainActor
extension OnDeviceReviewPipeline {
    @discardableResult
    func run(for message: Message) async -> String? {
        await run(for: Input(message))
    }

    @discardableResult
    func transcribeOnly(for message: Message) async -> String? {
        await transcribeOnly(for: Input(message))
    }
}
