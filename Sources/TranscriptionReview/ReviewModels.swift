//
//  ReviewModels.swift
//  TranscriptionReview
//
//  Codable models mirroring the Operator API's message-review payloads
//  (`GET /v1/messages`, `/v1/messages/{id}/transcriptions`). Unknown enum
//  values decode to `.unknown(_)` so a server-side addition never breaks the
//  client. Includes the transcription translation fields the review flow
//  needs to tell translated messages from untranslated ones.
//

import Foundation

public enum MessageStatus: Codable, Sendable, Hashable {
    case uploading, received, pending, approved, rejected
    case unknown(String)

    public static let knownCases: [MessageStatus] = [
        .uploading, .received, .pending, .approved, .rejected
    ]

    public var rawValue: String {
        switch self {
        case .uploading: return "uploading"
        case .received: return "received"
        case .pending: return "pending"
        case .approved: return "approved"
        case .rejected: return "rejected"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "uploading": self = .uploading
        case "received": self = .received
        case "pending": self = .pending
        case "approved": self = .approved
        case "rejected": self = .rejected
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayName: String { rawValue.capitalized }
}

public enum AiProvider: Codable, Sendable, Hashable {
    case openai, macApp, disabled
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .openai: return "openai"
        case .macApp: return "mac_app"
        case .disabled: return "disabled"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "openai": self = .openai
        case "mac_app": self = .macApp
        case "disabled": self = .disabled
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .macApp: return "Mac app"
        case .disabled: return "Disabled"
        // A provider this build doesn't know about still reaches the operator
        // as a label next to a verdict, so present it as prose rather than as
        // a raw wire value: "on_device" reads as "On device".
        case .unknown(let value):
            let spaced = value.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = spaced.first else { return value }
            return first.uppercased() + spaced.dropFirst()
        }
    }
}

public enum TranscriptionStatus: Codable, Sendable, Hashable {
    case pending, succeeded, failed
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .pending: return "pending"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayName: String { rawValue.capitalized }
}

public enum ModerationRecommendation: Codable, Sendable, Hashable {
    case approve, review, reject
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .approve: return "approve"
        case .review: return "review"
        case .reject: return "reject"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "approve": self = .approve
        case "review": self = .review
        case "reject": self = .reject
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayName: String { rawValue.capitalized }
}

public struct AudioRef: Codable, Sendable, Equatable {
    public let url: URL
    public let sha256: String
    public let durationMs: Int?
}

public struct Transcription: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let messageId: String
    public let provider: AiProvider
    public let model: String?
    public let status: TranscriptionStatus
    public let text: String?
    public let language: String?
    public let durationMs: Int?
    public let latencyMs: Int?
    public let error: String?
    public let requestedById: String?
    public let createdAt: Date
    public let completedAt: Date?
    public let translationStatus: TranscriptionStatus?
    public let translatedText: String?
    public let translatedLanguage: String?
    public let translationProvider: AiProvider?
    public let translationModel: String?
    public let translationError: String?
    public let translationLatencyMs: Int?
    public let translationCompletedAt: Date?

    /// True when there is usable source text but no completed translation yet.
    public var needsTranslation: Bool {
        guard status == .succeeded,
              let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        if translationStatus == .succeeded,
           let translatedText,
           !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    /// True when a translation was attempted and failed outright. Distinct from
    /// "never translated": there is an error to show and a retry to offer, and
    /// the operator shouldn't have to guess which of the two they're looking at.
    public var translationFailed: Bool {
        translationStatus == .failed
    }

    /// True when a translation attempt is still running.
    public var translationIsPending: Bool {
        translationStatus == .pending
    }

    /// The best English text available for this transcription, if any.
    public var completedTranslation: String? {
        guard translationStatus == .succeeded,
              let translatedText,
              !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return translatedText
    }
}

public struct TranscriptionList: Codable, Sendable, Equatable {
    public let items: [Transcription]

    public init(items: [Transcription]) { self.items = items }
}

public struct Moderation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let messageId: String
    public let transcriptionId: String?
    public let provider: AiProvider
    public let model: String?
    public let status: TranscriptionStatus
    public let flagged: Bool?
    public let recommendation: ModerationRecommendation?
    public let maxScore: Double?
    public let categories: [String: Double]?
    public let reasonSummary: String?
    public let latencyMs: Int?
    public let error: String?
    public let createdAt: Date
    public let completedAt: Date?

    /// True while the automated moderation run is still in progress. Distinct
    /// from "never asked": the AI is thinking and a verdict is coming.
    public var isPending: Bool { status == .pending }

    /// True when the automated moderation run finished in failure. Distinct
    /// from "never asked": there is an `error` to show and a re-run to offer,
    /// and the operator shouldn't have to guess which of the two they see.
    public var didFail: Bool { status == .failed }

    /// Which engine produced the verdict, for display next to the
    /// recommendation. An on-device Apple Intelligence verdict and a
    /// server-side one are calibrated differently, so the operator being asked
    /// to weigh the recommendation needs to know which one they're weighing.
    public var sourceLabel: String {
        guard let model,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return provider.displayName
        }
        return "\(provider.displayName) · \(model)"
    }

    /// The highest category score, formatted for display, but only when the
    /// message was flagged — that's where the gap between "barely over the
    /// line" and "obviously over it" actually matters. Nil otherwise.
    public var flaggedScoreLabel: String? {
        guard flagged == true, let maxScore else { return nil }
        return maxScore.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The single next thing an operator has to do for a message.
///
/// Review is a chain — transcribe, then translate, then decide — so a message
/// has exactly one next step rather than a set of independent chores. This is
/// what lets the queue be one list of messages instead of one list per stage,
/// where the same message showed up three times.
public enum ReviewStep: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case transcription
    case translation
    case decision

    public var id: Self { self }

    /// Short label for the chip on a queue row.
    public var displayName: String {
        switch self {
        case .transcription: return "Needs transcript"
        case .translation: return "Needs translation"
        case .decision: return "Needs decision"
        }
    }
}

public struct Message: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let status: MessageStatus
    public let questionId: String?
    public let notes: String?
    public let createdAt: Date
    public let receivedAt: Date?
    public let audio: AudioRef
    public let latestTranscription: Transcription?
    public let latestModeration: Moderation?

    /// True when the latest transcription has source text awaiting translation.
    public var needsTranslation: Bool {
        latestTranscription?.needsTranslation ?? false
    }

    /// True when the message is still awaiting a human moderation decision.
    public var awaitingModerationDecision: Bool { isReviewable }

    /// True when the message sits in the review queue. A freshly landed upload
    /// reports `pending`; `received` still exists for historical rows, so both
    /// count — and this is the single source of truth for that status set.
    public var isReviewable: Bool {
        switch status {
        case .received, .pending: return true
        default: return false
        }
    }

    /// True when the newest transcription row succeeded. The review payload
    /// only carries the newest row, so a re-run that is still pending (or that
    /// failed) masks an older successful transcript — which is why a message
    /// with any transcription row stays in the re-run bucket rather than the
    /// "needs transcription" one.
    public var hasSucceededTranscription: Bool {
        latestTranscription?.status == .succeeded
    }

    /// True when a transcription row exists but hasn't succeeded: still running
    /// on some worker, or failed outright.
    public var transcriptionIsUnfinished: Bool {
        guard let latest = latestTranscription else { return false }
        return latest.status != .succeeded
    }

    /// True when the newest transcription attempt failed. Distinct from a run
    /// still in progress: this one is finished and can be retried now.
    public var transcriptionFailed: Bool {
        latestTranscription?.status == .failed
    }

    /// True when transcription succeeded but produced no text — a silent
    /// recording, which is meaningfully different from "not transcribed yet".
    public var transcriptionIsSilent: Bool {
        guard hasSucceededTranscription else { return false }
        let text = latestTranscription?.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the message is reviewable and the Operator holds no
    /// transcription row at all. Transcription is optional enrichment on the
    /// Operator side, so these messages are visible to operators but not yet
    /// enriched. A message whose newest row is pending or failed is deliberately
    /// excluded from this bucket — it already has transcription history, which
    /// the newest row can mask — and is offered for a manual re-run instead.
    /// This describes Review bucketing only; the worker's discovery pass has its
    /// own rules and may still retry such a message.
    public var needsTranscription: Bool {
        isReviewable && latestTranscription == nil
    }

    /// True when the message is reviewable and has no usable transcript yet —
    /// never transcribed, still running, or failed. Broader than
    /// `needsTranscription`, which is only the "no row at all" case; this is the
    /// question the queue actually asks ("can I read this yet?").
    public var needsTranscriptionWork: Bool {
        isReviewable && !hasSucceededTranscription
    }

    /// True when a translation was attempted for the latest transcript and
    /// failed. Surfaced separately so a failed translation reads differently
    /// from one that was never attempted, and so the error can be shown.
    public var translationFailed: Bool {
        latestTranscription?.translationFailed ?? false
    }

    /// True when a translation attempt for the latest transcript is running.
    public var translationIsPending: Bool {
        latestTranscription?.translationIsPending ?? false
    }

    /// The completed English translation of the latest transcript, if any.
    public var translationText: String? {
        latestTranscription?.completedTranslation
    }

    /// The single next action an operator has to take, or `nil` when the
    /// message is already decided and needs nothing.
    ///
    /// A silent recording skips straight to `.decision`: there is nothing to
    /// transcribe or translate, but it still needs approving or rejecting.
    public var nextStep: ReviewStep? {
        guard isReviewable else { return nil }
        if transcriptionIsSilent { return .decision }
        if needsTranscriptionWork { return .transcription }
        if needsTranslation { return .translation }
        return .decision
    }

    /// True when the message is waiting on the operator for anything at all.
    public var needsAttention: Bool { nextStep != nil }

    /// The best text to show as a one-glance preview: the English translation
    /// when there is one, otherwise the source transcript.
    public var previewText: String? {
        if let translationText { return translationText }
        if let text = latestTranscription?.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }
}

extension Message {
    /// Returns a copy with `latestTranscription` replaced. Used to fold an
    /// operator-submitted transcript or translation back into local state
    /// without waiting for the next poll.
    ///
    /// The existing moderation is carried over only when it belongs to the new
    /// row (or to no row at all). A submitted transcript creates a *new*
    /// transcription, and its moderation is re-run server-side; keeping the old
    /// verdict would show the new transcript under a recommendation and reason
    /// that were computed for different text.
    public func replacingLatestTranscription(_ transcription: Transcription) -> Message {
        let moderation = latestModeration.flatMap { existing -> Moderation? in
            guard let owner = existing.transcriptionId else { return existing }
            return owner == transcription.id ? existing : nil
        }
        return Message(
            id: id,
            status: status,
            questionId: questionId,
            notes: notes,
            createdAt: createdAt,
            receivedAt: receivedAt,
            audio: audio,
            latestTranscription: transcription,
            latestModeration: moderation
        )
    }

    /// Returns a copy with `latestModeration` replaced. Used to fold an
    /// operator-submitted verdict back into local state so it becomes the
    /// recommendation of record immediately, without waiting for the next poll.
    public func replacingLatestModeration(_ moderation: Moderation) -> Message {
        Message(
            id: id,
            status: status,
            questionId: questionId,
            notes: notes,
            createdAt: createdAt,
            receivedAt: receivedAt,
            audio: audio,
            latestTranscription: latestTranscription,
            latestModeration: moderation
        )
    }
}

public struct MessageList: Codable, Sendable, Equatable {
    public let items: [Message]

    public init(items: [Message]) { self.items = items }
}

/// A human moderation decision an operator can take on a message.
public enum ReviewDecision: String, Codable, Sendable, Hashable {
    case approve
    case reject
}
