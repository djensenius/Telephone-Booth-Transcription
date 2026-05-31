import Foundation

/// Platform-neutral, transport-agnostic service protocols and DTOs shared by
/// the macOS HTTP server (which adapts them into Hummingbird responses) and the
/// pull/sync clients (which call them directly, in-process).
///
/// None of these types depend on Hummingbird, GRDB, or NIO, so non-macOS
/// targets can implement and consume them without linking the HTTP server
/// stack.

/// Converts an audio file into a plain-text transcript, fully on-device where
/// the implementation supports it.
public protocol AudioTranscriber: Sendable {
    /// Transcribes the audio at `audioFileURL`.
    ///
    /// - Parameter language: BCP-47 hint (e.g. `"en-US"`). When `nil`, the
    ///   implementation uses its configured default locale.
    /// - Returns: the recognized transcript text.
    func transcribe(audioFileURL: URL, language: String?) async throws -> String
}

/// Result of translating text into a target language.
public struct TranslationResult: Sendable, Equatable {
    public var translatedText: String
    public var sourceLanguage: String?
    public var targetLanguage: String
    public var model: String?

    public init(
        translatedText: String,
        sourceLanguage: String? = nil,
        targetLanguage: String = "en",
        model: String? = nil
    ) {
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.model = model
    }
}

/// Translates text into a target language (English by default).
public protocol TextTranslationService: Sendable {
    func translate(_ input: String, sourceLanguage: String?) async throws -> TranslationResult
}

/// Result of moderating a piece of text. Mirrors the fields the Operator's
/// `/v1/jobs/{id}/succeed` moderation body expects.
public struct ModerationVerdict: Sendable, Equatable {
    public var flagged: Bool
    public var recommendation: String
    public var maxScore: Double
    public var model: String?

    public init(
        flagged: Bool,
        recommendation: String,
        maxScore: Double,
        model: String? = nil
    ) {
        self.flagged = flagged
        self.recommendation = recommendation
        self.maxScore = maxScore
        self.model = model
    }
}

/// Classifies text for policy violations.
public protocol TextModerationService: Sendable {
    func moderate(_ input: String) async throws -> ModerationVerdict
}

/// Transport-agnostic error raised by on-device services. The HTTP server maps
/// these onto its JSON error envelope; in-process callers handle them directly.
public enum OnDeviceServiceError: Error, Sendable, Equatable {
    /// The input was malformed or unusable (maps to HTTP 400).
    case badRequest(String)
    /// The user denied or has not granted a required permission (maps to 403).
    case unauthorized(String)
    /// The operation exceeded its deadline (maps to 504).
    case timeout(String)
    /// The capability is not available on this device/OS (maps to 400/503).
    case unavailable(String)
}
