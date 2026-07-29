import Foundation
import TranscriptionOnDevice
import TranscriptionOperator
import TranscriptionReview
import TranscriptionShared

extension OnDeviceReviewPipeline {
    /// Builds a pipeline backed by Apple Intelligence, or returns `nil` when
    /// this device can't run the on-device engines — callers hide the entry
    /// point entirely rather than offering a button that always fails.
    ///
    /// The capability probe matters beyond the `@available` checks below: a
    /// device can be on a new enough OS and still have Apple Intelligence
    /// disabled, be ineligible, or not have finished downloading the model. The
    /// engines re-check at use time too, since availability can change after
    /// this returns.
    static func makeAppleIntelligence(locale: Locale = .current) -> OnDeviceReviewPipeline? {
        guard OnDeviceCapability.isFullPipelineAvailable else { return nil }
        guard let transcriber = makeTranscriber(locale: locale),
              let translator = makeTranslator(),
              let moderator = makeModerator() else {
            return nil
        }
        let dispatcher = InProcessOperatorJobDispatcher(
            transcriber: transcriber,
            translator: translator,
            moderator: moderator,
            audioFetcher: URLSessionAudioFetcher()
        )
        return OnDeviceReviewPipeline(dispatcher: dispatcher)
    }

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
