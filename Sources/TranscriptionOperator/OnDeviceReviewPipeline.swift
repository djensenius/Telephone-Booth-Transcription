import Foundation
import Logging
import Observation
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
    /// The subset of a review message this pipeline needs. Kept separate from
    /// the operator's `Message` model so the orchestration stays independent of
    /// the review client (and testable without it).
    public struct Input: Sendable, Equatable {
        public var id: String
        public var audioURL: URL
        public var audioSHA256: String
        public var audioDurationMs: Int?
        /// BCP-47 hint for the transcriber, when the operator already knows it.
        public var language: String?

        public init(
            id: String,
            audioURL: URL,
            audioSHA256: String,
            audioDurationMs: Int? = nil,
            language: String? = nil
        ) {
            self.id = id
            self.audioURL = audioURL
            self.audioSHA256 = audioSHA256
            self.audioDurationMs = audioDurationMs
            self.language = language
        }
    }

    public struct Output: Sendable, Equatable {
        /// Transcript produced locally from the audio.
        public var transcript: String
        /// BCP-47 language of `transcript`, when known. Nil when the operator
        /// had no language hint for the message.
        public var language: String?
        /// Identifier of the local engine that produced `transcript`, so a
        /// submitted transcript can be attributed on the Operator.
        public var model: String?
        /// English translation of `transcript`. Nil when only transcription was
        /// requested (the "needs transcription" buckets).
        public var translation: String?
        /// Local moderation verdict, when moderation ran.
        public var recommendation: String?
        public var flagged: Bool?
        /// Highest category score behind the verdict, in `0...1`. Carried so a
        /// submitted verdict can populate the Operator's `maxScore`.
        public var maxScore: Double?
        /// Identifier of the local model that produced the verdict, so a
        /// submitted verdict is attributed to it on the Operator. Distinct from
        /// `model`, which names the engine that produced `transcript`.
        public var moderationModel: String?

        public init(
            transcript: String,
            language: String? = nil,
            model: String? = nil,
            translation: String? = nil,
            recommendation: String? = nil,
            flagged: Bool? = nil,
            maxScore: Double? = nil,
            moderationModel: String? = nil
        ) {
            self.transcript = transcript
            self.language = language
            self.model = model
            self.translation = translation
            self.recommendation = recommendation
            self.flagged = flagged
            self.maxScore = maxScore
            self.moderationModel = moderationModel
        }
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
    /// Identifier recorded against transcripts this pipeline produces, so the
    /// Operator can attribute a submitted transcript to the local engine.
    @ObservationIgnored
    private let transcriptionModel: String?

    /// Per-message progress, keyed by message id, so several rows can run
    /// independently without sharing a single spinner.
    public private(set) var stages: [String: Stage] = [:]
    public private(set) var outputs: [String: Output] = [:]

    /// Which entry point owns a message's current stage.
    ///
    /// A message has one stage, but the UI can offer two independent actions on
    /// it at once — draft a translation, or just classify the text already
    /// there. Without this, starting either one puts the *other* button into a
    /// spinner and shows it the resulting error.
    public enum Operation: Sendable, Equatable {
        case transcribe
        case translate
        case moderate
    }

    public private(set) var operations: [String: Operation] = [:]

    /// The operation that produced a message's current stage, or `nil` when it
    /// is idle.
    public func operation(for messageID: String) -> Operation? {
        operations[messageID]
    }

    public init(
        dispatcher: InProcessOperatorJobDispatcher,
        transcriptionModel: String? = nil,
        logger: Logger = Logger(label: "on-device-review")
    ) {
        self.dispatcher = dispatcher
        self.transcriptionModel = transcriptionModel
        self.logger = logger
    }

    // MARK: - Running

    /// False when no local transcriber was injected — the device has no usable
    /// on-device speech engine for the current locale, so the transcribe
    /// affordances are hidden. A pipeline can still be worth having in that
    /// state: Foundation Models can classify text the Operator already holds.
    public var supportsTranscription: Bool {
        dispatcher.supportedKinds.contains(.transcription)
    }

    /// False when the device can transcribe but has no language model (Apple
    /// Intelligence disabled or still downloading). `run` would fail; only
    /// `transcribeOnly` is usable, so the UI hides the translate affordance.
    public var supportsTranslation: Bool {
        dispatcher.supportedKinds.contains(.translation)
    }

    /// False when no local moderation service was injected — the "get a
    /// recommendation" affordance is then hidden rather than offered and always
    /// failing. Separate from ``supportsTranslation``: a device can be able to
    /// classify text without being able to translate it.
    public var supportsModeration: Bool {
        dispatcher.supportedKinds.contains(.moderation)
    }

    public func stage(for messageID: String) -> Stage {
        stages[messageID] ?? .idle
    }

    public func isRunning(_ messageID: String) -> Bool {
        switch stage(for: messageID) {
        case .fetchingAndTranscribing, .translating, .moderating: return true
        default: return false
        }
    }

    /// Bumped whenever a message's run is superseded — by `reset`, or by a new
    /// run starting. A run captures the value at entry and abandons its results
    /// if it no longer matches, so a task still in flight when the row was reset
    /// can't repopulate the operator's draft with a stale transcript. Swift
    /// concurrency gives us no way to cancel the caller's task from here, and
    /// `isRunning` goes false on reset, so without this a second run could start
    /// and race the first.
    @ObservationIgnored
    private var generations: [String: Int] = [:]

    /// Starts a new generation for `messageID` and returns it.
    private func beginGeneration(_ messageID: String) -> Int {
        let next = (generations[messageID] ?? 0) + 1
        generations[messageID] = next
        return next
    }

    private func isCurrent(_ messageID: String, _ generation: Int) -> Bool {
        generations[messageID] == generation
    }

    /// Drops all state for messages that are no longer in the review queue.
    ///
    /// `stages` and `outputs` hold complete transcripts and translations, and
    /// `reset` only fires when a row's transcription id changes — so without
    /// this, deciding on a message leaves its text resident for as long as the
    /// app runs, and a long session accumulates every message it ever touched.
    /// In-flight runs for pruned ids are superseded, not left to repopulate.
    public func prune(keeping activeIDs: Set<String>) {
        for id in stages.keys where !activeIDs.contains(id) {
            reset(id)
        }
        for id in outputs.keys where !activeIDs.contains(id) {
            reset(id)
        }
    }

    /// Drops only the local verdict for a message, keeping any transcript or
    /// translation it was computed alongside.
    ///
    /// Asking for a recommendation classifies the operator's current draft, so
    /// editing that draft afterwards leaves a prominent verdict describing text
    /// that no longer exists. `reset` is too blunt here — it would also discard
    /// the generated transcript and translation the draft came from.
    public func clearModeration(_ messageID: String) {
        guard let existing = outputs[messageID], existing.recommendation != nil else { return }
        outputs[messageID] = Output(
            transcript: existing.transcript,
            language: existing.language,
            model: existing.model,
            translation: existing.translation
        )
    }

    /// Clears any surfaced result/error for a message, and supersedes any run
    /// still in flight for it.
    public func reset(_ messageID: String) {
        _ = beginGeneration(messageID)
        stages[messageID] = nil
        outputs[messageID] = nil
        operations[messageID] = nil
    }

    /// Runs only the transcription stage for `message`, for the "needs
    /// transcription" queues. Returns the local transcript, or `nil` on
    /// failure. An empty string means the engine heard no speech, which is a
    /// result the operator can still submit — unlike ``run(for:)``, which has
    /// nothing to translate or moderate and rejects it.
    ///
    /// The transcript is stored, not submitted: the operator reviews it and
    /// taps Submit, which posts it through
    /// `ReviewStore.submitTranscription(_:text:language:model:)`.
    @discardableResult
    public func transcribeOnly(for message: Input) async -> String? {
        guard !isRunning(message.id) else { return nil }
        let generation = beginGeneration(message.id)
        outputs[message.id] = nil
        operations[message.id] = .transcribe
        stages[message.id] = .fetchingAndTranscribing

        let result: (text: String, language: String?, model: String?)
        do {
            result = try await transcribe(message)
        } catch {
            guard isCurrent(message.id, generation) else { return nil }
            fail(message.id, error, verb: "transcribe that audio")
            return nil
        }
        guard isCurrent(message.id, generation) else { return nil }

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unlike the full pipeline, an empty transcript is a legitimate result
        // here: a genuinely silent recording. The Operator accepts empty text,
        // so surface it and let the operator decide whether to submit it —
        // that's the only way the queue ever clears a silent message.
        outputs[message.id] = Output(
            transcript: trimmed,
            language: result.language,
            model: result.model,
            translation: nil
        )
        stages[message.id] = .finished
        return trimmed
    }

    /// Classifies text the Operator already holds, without touching the audio.
    ///
    /// `run(for:)` is the wrong tool for a message that is already transcribed
    /// and translated but carries no verdict: it would re-fetch the audio and
    /// redo the transcription to answer a question about text that is already
    /// on screen. It is also unreachable in that state, because the UI only
    /// offers it where a translation is still outstanding.
    ///
    /// - Parameters:
    ///   - english: the text to classify — the English translation when there
    ///     is one, otherwise the transcript.
    ///   - transcript: the Operator's transcript, recorded on the output so the
    ///     UI can still tell this apart from a locally produced transcript.
    /// - Returns: the recommendation, or `nil` if moderation failed.
    @discardableResult
    public func moderateOnly(
        _ english: String,
        transcript: String,
        language: String?,
        for messageID: String
    ) async -> String? {
        guard !isRunning(messageID) else { return nil }
        let generation = beginGeneration(messageID)
        operations[messageID] = .moderate
        stages[messageID] = .moderating

        let verdict: ModerationVerdict
        do {
            verdict = try await moderate(english)
        } catch {
            guard isCurrent(messageID, generation) else { return nil }
            fail(messageID, error, verb: "moderate that text")
            return nil
        }
        guard isCurrent(messageID, generation) else { return nil }

        // Merged into any existing output rather than replacing it: a local
        // transcript or translation the operator hasn't submitted yet must
        // survive asking for a second opinion on it.
        let existing = outputs[messageID]
        outputs[messageID] = Output(
            transcript: existing?.transcript ?? transcript,
            language: existing?.language ?? language,
            model: existing?.model,
            translation: existing?.translation,
            recommendation: verdict.recommendation,
            flagged: verdict.flagged,
            maxScore: verdict.maxScore,
            moderationModel: verdict.model
        )
        stages[messageID] = .finished
        return verdict.recommendation
    }

    /// Runs transcribe → translate → moderate for `message` and stores the
    /// result. Returns the English translation so the caller can pre-fill the
    /// operator's draft, or `nil` if any stage failed.
    @discardableResult
    public func run(for message: Input) async -> String? {
        guard !isRunning(message.id) else { return nil }
        let generation = beginGeneration(message.id)
        outputs[message.id] = nil
        operations[message.id] = .translate
        stages[message.id] = .fetchingAndTranscribing

        let transcriptResult: (text: String, language: String?, model: String?)
        do {
            transcriptResult = try await transcribe(message)
        } catch {
            guard isCurrent(message.id, generation) else { return nil }
            fail(message.id, error, verb: "transcribe that audio")
            return nil
        }
        guard isCurrent(message.id, generation) else { return nil }

        let trimmed = transcriptResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            stages[message.id] = .failed("On-device transcription produced no speech.")
            return nil
        }

        stages[message.id] = .translating
        let translation: String
        do {
            translation = try await translate(trimmed, sourceLanguage: message.language)
        } catch {
            guard isCurrent(message.id, generation) else { return nil }
            fail(message.id, error, verb: "translate that transcript")
            return nil
        }
        guard isCurrent(message.id, generation) else { return nil }

        // Moderation is advisory, so a failure here must not discard the
        // translation the operator is waiting on.
        //
        // The translation is what gets classified, not the transcript: it's the
        // text the operator reviews and decides on, and for a non-English
        // message it's the only one the moderator can read. `moderateOnly`
        // makes the same choice.
        stages[message.id] = .moderating
        var recommendation: String?
        var flagged: Bool?
        var maxScore: Double?
        var moderationModel: String?
        if let verdict = try? await moderate(translation) {
            recommendation = verdict.recommendation
            flagged = verdict.flagged
            maxScore = verdict.maxScore
            moderationModel = verdict.model
        }
        guard isCurrent(message.id, generation) else { return nil }

        outputs[message.id] = Output(
            transcript: trimmed,
            language: transcriptResult.language,
            model: transcriptResult.model,
            translation: translation,
            recommendation: recommendation,
            flagged: flagged,
            maxScore: maxScore,
            moderationModel: moderationModel
        )
        stages[message.id] = .finished
        return translation
    }

    // MARK: - Stages

    private func transcribe(_ message: Input) async throws -> (text: String, language: String?, model: String?) {
        let job = OperatorJob(
            id: message.id,
            leaseToken: "",
            kind: .transcription,
            payload: .transcription(.init(
                audioURL: message.audioURL.absoluteString,
                sha256: message.audioSHA256,
                durationMs: message.audioDurationMs,
                model: transcriptionModel,
                language: message.language
            ))
        )
        guard case .transcription(let text, let language, let model) = try await dispatcher.execute(job: job) else {
            throw OperatorJobError(code: "transcription_failed", message: "local transcription failed")
        }
        return (text, language, model ?? transcriptionModel)
    }

    /// `sourceLanguage` is the hint the Operator already recorded for the
    /// message. The networked worker path sends it, so omitting it here would
    /// make the in-process path force a re-detection and translate less
    /// accurately for the same input.
    private func translate(_ input: String, sourceLanguage: String?) async throws -> String {
        let job = OperatorJob(
            id: UUID().uuidString,
            leaseToken: "",
            kind: .translation,
            payload: .translation(.init(input: input, sourceLanguage: sourceLanguage))
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
