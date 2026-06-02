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
    case invalidResponse
}

/// Read-only client for the Operator message-review API. Every request carries
/// the operator's OIDC bearer token. This deliberately covers only the read
/// path today; write actions (approve/reject, submit translation) land once the
/// backend exposes the corresponding endpoints.
public protocol OperatorReviewClient: Sendable {
    func fetchMessages(status: MessageStatus?, since: Date?, limit: Int) async throws -> MessageList
    func fetchTranscriptions(messageID: String) async throws -> TranscriptionList
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

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OperatorReviewError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw OperatorReviewError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OperatorReviewError.http(http.statusCode)
        }
        return try OperatorJSON.decoder.decode(Response.self, from: data)
    }
}
