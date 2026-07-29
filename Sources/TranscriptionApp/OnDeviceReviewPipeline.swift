import Foundation
import Logging
import Observation
import TranscriptionOnDevice
import TranscriptionOperator
import TranscriptionReview
import TranscriptionShared

/// Runs the whole review pipeline locally with Apple Intelligence: fetch the
/// message audio, re-transcribe it on-device, translate the transcript to
/// English, and produce a moderation verdict — without contacting any
/// transcription/translation/moderation upstream.
///
/// This is the in-process counterpart to the macOS HTTP server: it reuses
/// `InProcessOperatorJobDispatcher`, so audio integrity checks (sha256, size
/// cap, https-only) and error sanitization behave identically. Only the
/// Operator itself is contacted, and only to download the audio the operator is
/// already authorized to review.
///
/// Results are **never** submitted automatically — the caller pre-fills the
/// operator's draft so a human still reviews and submits.
@MainActor
@Observable
public final class OnDeviceReviewPipeline {
    public struct Output: Sendable, Equatable {
        /// Transcript produced locally from the audio.
        public var transcript: String
        /// English translation of `transcript`.
        public var translation: String
        /// Local moderation verdict, when moderation ran.
        public var recommendation: String?
        public var flagged: Bool?
    }

    public enum Stage: Sendable, Equatable {
        case idle
        case fetchingAndTranscribing
        case translating
        case moderating
        case finished
        case failed(String)
    }

    @ObservationIgnored
    private let dispatcher: InProcessOperatorJobDispatcher
    @ObservationIgnored
    private let logger: Logger

    /// Per-message progress, keyed by message id, so several rows can run
    /// independently without sharing a single spinner.
    public private(set) var stages: [String: Stage] = [:]
    public private(set) var outputs: [String: Output] = [:]

    public init(
        dispatcher: InProcessOperatorJobDispatcher,
        logger: Logger = Logger(label: "on-device-review")
    ) {
        self.dispatcher = dispatcher
        self.logger = logger
    }

    /// Builds a pipeline backed by Apple Intelligence, or returns `nil` when
    /// this OS/device can't run the on-device engines — callers hide the entry
    /// point entirely rather than offering a button that always fails.
    public static func makeAppleIntelligence(
        locale: Locale = .current,
        authorizationProvider: URLSessionAudioFetcher.AuthorizationProvider? = nil
    ) -> OnDeviceReviewPipeline? {
        guard let transcriber = Self.makeTranscriber(locale: locale),
              let translator = Self.makeTranslator(),
              let moderator = Self.makeModerator() else {
            return nil
        }
        let dispatcher = InProcessOperatorJobDispatcher(
            transcriber: transcriber,
            translator: translator,
            moderator: moderator,
            audioFetcher: URLSessionAudioFetcher(authorizationProvider: authorizationProvider)
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

    // MARK: - Running

    public func stage(for messageID: String) -> Stage {
        stages[messageID] ?? .idle
    }

    public func isRunning(_ messageID: String) -> Bool {
        switch stage(for: messageID) {
        case .fetchingAndTranscribing, .translating, .moderating: return true
        default: return false
        }
    }

    /// Clears any surfaced result/error for a message.
    public func reset(_ messageID: String) {
        stages[messageID] = nil
        outputs[messageID] = nil
    }

    /// Runs transcribe → translate → moderate for `message` and stores the
    /// result. Returns the English translation so the caller can pre-fill the
    /// operator's draft, or `nil` if any stage failed.
    @discardableResult
    public func run(for message: Message) async -> String? {
        guard !isRunning(message.id) else { return nil }
        outputs[message.id] = nil
        stages[message.id] = .fetchingAndTranscribing

        let transcript: String
        do {
            transcript = try await transcribe(message)
        } catch {
            fail(message.id, error, verb: "transcribe that audio")
            return nil
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            stages[message.id] = .failed("On-device transcription produced no speech.")
            return nil
        }

        stages[message.id] = .translating
        let translation: String
        do {
            translation = try await translate(trimmed)
        } catch {
            fail(message.id, error, verb: "translate that transcript")
            return nil
        }

        // Moderation is advisory, so a failure here must not discard the
        // translation the operator is waiting on.
        stages[message.id] = .moderating
        var recommendation: String?
        var flagged: Bool?
        if let verdict = try? await moderate(trimmed) {
            recommendation = verdict.recommendation
            flagged = verdict.flagged
        }

        outputs[message.id] = Output(
            transcript: trimmed,
            translation: translation,
            recommendation: recommendation,
            flagged: flagged
        )
        stages[message.id] = .finished
        return translation
    }

    // MARK: - Stages

    private func transcribe(_ message: Message) async throws -> String {
        let job = OperatorJob(
            id: message.id,
            leaseToken: "",
            kind: .transcription,
            payload: .transcription(.init(
                audioURL: message.audio.url.absoluteString,
                sha256: message.audio.sha256,
                durationMs: message.audio.durationMs,
                language: message.latestTranscription?.language
            ))
        )
        guard case .transcription(let text, _, _) = try await dispatcher.execute(job: job) else {
            throw OperatorJobError(code: "transcription_failed", message: "local transcription failed")
        }
        return text
    }

    private func translate(_ input: String) async throws -> String {
        let job = OperatorJob(
            id: UUID().uuidString,
            leaseToken: "",
            kind: .translation,
            payload: .translation(.init(input: input))
        )
        guard case .translation(let translated, _, _, _) = try await dispatcher.execute(job: job) else {
            throw OperatorJobError(code: "translation_failed", message: "local translation failed")
        }
        return translated
    }

    private func moderate(_ input: String) async throws -> ModerationVerdict {
        let job = OperatorJob(
            id: UUID().uuidString,
            leaseToken: "",
            kind: .moderation,
            payload: .moderation(.init(input: input))
        )
        guard case .moderation(let flagged, let recommendation, let maxScore, let model) =
                try await dispatcher.execute(job: job) else {
            throw OperatorJobError(code: "moderation_failed", message: "local moderation failed")
        }
        return ModerationVerdict(
            flagged: flagged,
            recommendation: recommendation,
            maxScore: maxScore,
            model: model
        )
    }

    // MARK: - Errors

    private func fail(_ messageID: String, _ error: any Error, verb: String) {
        stages[messageID] = .failed(Self.describe(error, verb: verb))
        // Only the sanitized code is logged — never audio, transcript, or URL.
        let code = (error as? OperatorJobError)?.code ?? "unknown"
        logger.error("on-device pipeline failed: \(code)")
    }

    /// Maps the dispatcher's sanitized codes onto operator-facing copy. The
    /// underlying messages are already content-free by design.
    static func describe(_ error: any Error, verb: String) -> String {
        guard let jobError = error as? OperatorJobError else {
            return "Couldn’t \(verb). Try again."
        }
        switch jobError.code {
        case "audio_fetch_failed":
            return "Couldn’t \(verb): the audio didn’t download. Check your connection."
        case "audio_sha256_mismatch", "audio_sha256_invalid":
            return "Couldn’t \(verb): the audio failed its integrity check."
        case "audio_too_large":
            return "Couldn’t \(verb): the audio is too large to process on this device."
        case "audio_insecure_url":
            return "Couldn’t \(verb): the audio URL wasn’t secure."
        case let code where code.hasSuffix("_unauthorized"):
            return "Couldn’t \(verb): grant speech recognition permission in Settings."
        case let code where code.hasSuffix("_unavailable"):
            return "Couldn’t \(verb): Apple Intelligence isn’t available on this device."
        case let code where code.hasSuffix("_timeout"):
            return "Couldn’t \(verb): the on-device model timed out."
        default:
            return "Couldn’t \(verb). Try again."
        }
    }
}
