import Foundation

/// A job leased from the Operator's `/v1/jobs/next` endpoint.
///
/// The Operator owns job identity; this app treats `id` and `leaseToken`
/// as opaque tokens to be echoed back on `succeed`/`fail`/`heartbeat`.
public struct OperatorJob: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case transcription
        case translation
        case moderation
    }

    public enum Payload: Sendable, Equatable {
        case transcription(TranscriptionPayload)
        case translation(TranslationPayload)
        case moderation(ModerationPayload)
    }

    public var id: String
    public var leaseToken: String
    public var kind: Kind
    public var payload: Payload

    public init(id: String, leaseToken: String, kind: Kind, payload: Payload) {
        self.id = id
        self.leaseToken = leaseToken
        self.kind = kind
        self.payload = payload
    }

    public struct TranscriptionPayload: Sendable, Equatable {
        public var audioURL: String
        public var sha256: String
        public var durationMs: Int?
        public var model: String?
        public var language: String?
        public init(audioURL: String, sha256: String, durationMs: Int? = nil,
                    model: String? = nil, language: String? = nil) {
            self.audioURL = audioURL
            self.sha256 = sha256
            self.durationMs = durationMs
            self.model = model
            self.language = language
        }
    }

    public struct TranslationPayload: Sendable, Equatable {
        public var input: String
        public var sourceLanguage: String?
        public init(input: String, sourceLanguage: String? = nil) {
            self.input = input
            self.sourceLanguage = sourceLanguage
        }
    }

    public struct ModerationPayload: Sendable, Equatable {
        public var input: String
        public init(input: String) {
            self.input = input
        }
    }
}

/// Results submitted back to the Operator via `POST /v1/jobs/{id}/succeed`.
public enum OperatorJobResult: Sendable, Equatable {
    case transcription(text: String, language: String?, model: String?)
    case translation(translatedText: String, sourceLanguage: String?, targetLanguage: String, model: String?)
    case moderation(flagged: Bool, recommendation: String, maxScore: Double, model: String?)
}

/// Error reported to the Operator via `POST /v1/jobs/{id}/fail`.
///
/// `code` is a short machine-readable token (e.g. `audio_fetch_failed`).
/// `message` is sanitized human-readable detail; it MUST NOT contain audio
/// bytes, transcribed/translated text, or any other request body content.
public struct OperatorJobError: Sendable, Equatable, Error {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Wire-format decoding

extension OperatorJob {
    /// Decodes the JSON body returned by `GET /v1/jobs/next`.
    ///
    /// Expected shape (kept loose so future Operator-side additions don't
    /// immediately break this app):
    /// ```json
    /// {
    ///   "id": "<opaque>",
    ///   "kind": "transcription"|"translation"|"moderation",
    ///   "leaseToken": "<opaque>",
    ///   "transcription": { "audioUrl": "...", "sha256": "...", "durationMs": 123, "model": "...", "language": "..." }
    ///   // or "translation": { "input": "...", "sourceLanguage": "..." }
    ///   // or "moderation": { "input": "..." }
    /// }
    /// ```
    public static func decode(from data: Data) throws -> OperatorJob {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty,
              let leaseToken = obj["leaseToken"] as? String, !leaseToken.isEmpty,
              let kindString = obj["kind"] as? String,
              let kind = Kind(rawValue: kindString) else {
            throw DecodeError.malformed("missing id/leaseToken/kind")
        }
        switch kind {
        case .transcription:
            guard let payload = obj["transcription"] as? [String: Any],
                  let audioURL = payload["audioUrl"] as? String, !audioURL.isEmpty,
                  let sha256 = payload["sha256"] as? String, !sha256.isEmpty else {
                throw DecodeError.malformed("transcription payload missing audioUrl/sha256")
            }
            return OperatorJob(
                id: id, leaseToken: leaseToken, kind: kind,
                payload: .transcription(.init(
                    audioURL: audioURL,
                    sha256: sha256,
                    durationMs: payload["durationMs"] as? Int,
                    model: payload["model"] as? String,
                    language: payload["language"] as? String
                ))
            )
        case .translation:
            guard let payload = obj["translation"] as? [String: Any],
                  let input = payload["input"] as? String, !input.isEmpty else {
                throw DecodeError.malformed("translation payload missing input")
            }
            return OperatorJob(
                id: id, leaseToken: leaseToken, kind: kind,
                payload: .translation(.init(
                    input: input,
                    sourceLanguage: payload["sourceLanguage"] as? String
                ))
            )
        case .moderation:
            guard let payload = obj["moderation"] as? [String: Any],
                  let input = payload["input"] as? String, !input.isEmpty else {
                throw DecodeError.malformed("moderation payload missing input")
            }
            return OperatorJob(
                id: id, leaseToken: leaseToken, kind: kind,
                payload: .moderation(.init(input: input))
            )
        }
    }

    public enum DecodeError: Error, Sendable, Equatable {
        case malformed(String)
    }
}

extension OperatorJobResult {
    /// Renders this result as the JSON body for `POST /v1/jobs/{id}/succeed`,
    /// including the `leaseToken` so the Operator can verify the caller
    /// still owns the lease.
    public func encode(leaseToken: String) throws -> Data {
        var payload: [String: Any] = ["leaseToken": leaseToken]
        switch self {
        case .transcription(let text, let language, let model):
            payload["text"] = text
            if let language { payload["language"] = language }
            if let model { payload["model"] = model }
        case .translation(let translated, let source, let target, let model):
            payload["translatedText"] = translated
            payload["targetLanguage"] = target
            if let source { payload["sourceLanguage"] = source }
            if let model { payload["model"] = model }
        case .moderation(let flagged, let recommendation, let maxScore, let model):
            payload["flagged"] = flagged
            payload["recommendation"] = recommendation
            payload["maxScore"] = maxScore
            if let model { payload["model"] = model }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

extension OperatorJobError {
    /// Renders this error as the JSON body for `POST /v1/jobs/{id}/fail`.
    public func encode(leaseToken: String) throws -> Data {
        let payload: [String: Any] = [
            "leaseToken": leaseToken,
            "errorCode": code,
            "errorMessage": message
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
