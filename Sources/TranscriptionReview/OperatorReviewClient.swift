//
//  OperatorReviewClient.swift
//  TranscriptionReview
//

import Foundation

/// Supplies a ready-to-use `Authorization` header value (e.g.
/// `"Bearer <token>"`). Implemented by the app over its OIDC `AuthManager`,
/// keeping this module free of any authentication-stack dependency.
public protocol BearerTokenProviding: Sendable {
    /// Returns the current `Authorization` header value, refreshing the token
    /// first if needed, or `nil` when no valid session exists.
    func authorizationHeader() async -> String?
}

public enum OperatorReviewError: Error, Sendable, Equatable {
    case unauthenticated
    case unauthorized
    case http(Int)
    /// A structured failure the Operator reported via its `{ "error": "<code>" }`
    /// envelope (e.g. `message_not_decidable`, `no_succeeded_transcription`).
    case api(status: Int, code: String)
    case invalidResponse
}

/// Client for the Operator message-review API. Every request carries the
/// operator's OIDC bearer token. Covers the read path (queue + transcriptions)
/// and the human write actions: recording a moderation decision, submitting a
/// transcript produced on this device, and submitting a translation for a
/// message's latest transcription.
public protocol OperatorReviewClient: Sendable {
    func fetchMessages(status: MessageStatus?, since: Date?, limit: Int) async throws -> MessageList
    func fetchTranscriptions(messageID: String) async throws -> TranscriptionList
    func submitDecision(
        messageID: String,
        decision: ReviewDecision,
        notes: String?
    ) async throws -> Message
    func submitTranscription(
        messageID: String,
        text: String,
        language: String?,
        model: String?
    ) async throws -> Transcription
    func submitTranslation(
        messageID: String,
        translatedText: String,
        translatedLanguage: String?
    ) async throws -> Transcription
    /// Records a moderation verdict computed on this device for `messageID`.
    /// The Operator finalizes any pending moderation row or appends a new
    /// succeeded one attributed to the submitting operator, so a verdict a phone
    /// produced locally becomes the message's verdict of record — visible to
    /// every other operator rather than stranded in this device's memory.
    func submitModeration(
        messageID: String,
        transcriptionId: String?,
        flagged: Bool,
        recommendation: String,
        maxScore: Double,
        reasonSummary: String?,
        model: String?
    ) async throws -> Moderation
}

public actor HTTPOperatorReviewClient: OperatorReviewClient {
    private let config: OperatorAPIConfig
    private let tokenProvider: any BearerTokenProviding
    private let urlSession: URLSession

    public init(
        config: OperatorAPIConfig = .shared,
        tokenProvider: any BearerTokenProviding,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
    }

    public func fetchMessages(
        status: MessageStatus? = nil,
        since: Date? = nil,
        limit: Int = 50
    ) async throws -> MessageList {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
        if let since {
            query.append(URLQueryItem(name: "since", value: OperatorJSON.iso8601String(from: since)))
        }
        return try await get("/v1/messages", query: query)
    }

    public func fetchTranscriptions(messageID: String) async throws -> TranscriptionList {
        try await get("/v1/messages/\(messageID)/transcriptions")
    }

    public func submitDecision(
        messageID: String,
        decision: ReviewDecision,
        notes: String?
    ) async throws -> Message {
        struct Body: Encodable {
            let decision: ReviewDecision
            let notes: String?
        }
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Body(decision: decision, notes: (trimmedNotes?.isEmpty == false) ? trimmedNotes : nil)
        return try await post("/v1/messages/\(messageID)/decision", body: body)
    }

    /// Submits a transcript this device produced (Apple Intelligence) for
    /// `messageID`. The Operator finalizes any pending row or appends a new
    /// succeeded one, attributes it to the submitting operator, and runs
    /// translation + moderation over it server-side.
    ///
    /// An empty `text` is a legitimate submission — it records a silent
    /// recording — so it is sent rather than rejected here.
    public func submitTranscription(
        messageID: String,
        text: String,
        language: String?,
        model: String?
    ) async throws -> Transcription {
        struct Body: Encodable {
            let text: String
            let language: String?
            let model: String?
        }
        let body = Body(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: Self.normalized(language),
            model: Self.normalized(model)
        )
        return try await post("/v1/messages/\(messageID)/transcription", body: body)
    }

    public func submitTranslation(
        messageID: String,
        translatedText: String,
        translatedLanguage: String?
    ) async throws -> Transcription {
        struct Body: Encodable {
            let translatedText: String
            let translatedLanguage: String?
        }
        let trimmedLanguage = translatedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Body(
            translatedText: translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            translatedLanguage: (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
        )
        return try await post("/v1/messages/\(messageID)/translation", body: body)
    }

    public func submitModeration(
        messageID: String,
        transcriptionId: String?,
        flagged: Bool,
        recommendation: String,
        maxScore: Double,
        reasonSummary: String?,
        model: String?
    ) async throws -> Moderation {
        struct Body: Encodable {
            let transcriptionId: String?
            let flagged: Bool
            let recommendation: String
            let maxScore: Double
            let reasonSummary: String?
            let model: String?
        }
        let body = Body(
            transcriptionId: Self.normalized(transcriptionId),
            flagged: flagged,
            recommendation: Self.normalizedRecommendation(recommendation),
            // The Operator rejects a score outside `0...1`; clamp rather than
            // let a stray value fail the whole submission.
            maxScore: min(1, max(0, maxScore)),
            reasonSummary: Self.normalized(reasonSummary),
            model: Self.normalized(model)
        )
        return try await post("/v1/messages/\(messageID)/moderation", body: body)
    }

    /// Folds a verdict onto the three values the Operator accepts. A local
    /// model can phrase the same call as `block` or `allow`, and posting that
    /// verbatim would fail the whole submission over vocabulary; anything
    /// unrecognized becomes `review`, which is the safe answer to "a human
    /// should look at this". Mirrors the worker path in
    /// `TranscriptionOperator.OperatorClient`.
    private static func normalizedRecommendation(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approve", "allow", "allowed": return "approve"
        case "reject", "block", "blocked": return "reject"
        default: return "review"
        }
    }

    /// Trims a metadata field and folds an empty result to `nil`, so a blank
    /// hint is sent as JSON `null` rather than an empty string.
    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    // MARK: - Request plumbing

    private func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        let base = config.url(forPath: path)
        let url: URL
        if query.isEmpty {
            url = base
        } else {
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw OperatorReviewError.invalidResponse
            }
            components.queryItems = (components.queryItems ?? []) + query
            guard let composed = components.url else { throw OperatorReviewError.invalidResponse }
            url = composed
        }

        guard let header = await tokenProvider.authorizationHeader() else {
            throw OperatorReviewError.unauthenticated
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(header, forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        let url = config.url(forPath: path)
        guard let header = await tokenProvider.authorizationHeader() else {
            throw OperatorReviewError.unauthenticated
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.httpBody = try OperatorJSON.encoder.encode(body)

        return try await send(request)
    }

    /// Performs the request and maps the response, translating the Operator's
    /// `{ "error": "<code>" }` envelope into a structured ``OperatorReviewError``.
    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OperatorReviewError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw OperatorReviewError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            if let code = Self.decodeErrorCode(from: data) {
                throw OperatorReviewError.api(status: http.statusCode, code: code)
            }
            throw OperatorReviewError.http(http.statusCode)
        }
        return try OperatorJSON.decoder.decode(Response.self, from: data)
    }

    private static func decodeErrorCode(from data: Data) -> String? {
        struct Envelope: Decodable { let error: String }
        return try? JSONDecoder().decode(Envelope.self, from: data).error
    }
}
