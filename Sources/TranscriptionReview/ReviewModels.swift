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
        case .unknown(let value): return value
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
    /// excluded: it already has transcription history, and re-running it is a
    /// human decision rather than something discovery should chase.
    public var needsTranscription: Bool {
        isReviewable && latestTranscription == nil
    }
}

extension Message {
    /// Returns a copy with `latestTranscription` replaced. Used to fold an
    /// operator-submitted translation back into local state without waiting for
    /// the next poll.
    public func replacingLatestTranscription(_ transcription: Transcription) -> Message {
        Message(
            id: id,
            status: status,
            questionId: questionId,
            notes: notes,
            createdAt: createdAt,
            receivedAt: receivedAt,
            audio: audio,
            latestTranscription: transcription,
            latestModeration: latestModeration
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
