import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import TranscriptionPipeline
import TranscriptionShared

/// Minimal HTTP client for the Operator push worker API. The worker receives
/// message IDs from the status WebSocket, fetches per-message work input, then
/// posts one local result per requested need.
public protocol OperatorClient: Sendable {
    /// Lists reviewable messages the worker may act on. Used by the discovery
    /// pass, which no longer depends on `work` envelopes for transcription.
    func listWork(needs: OperatorWorkNeeds, limit: Int, cursor: String?) async throws -> OperatorWorkListPage
    func fetchWorkInput(messageID: String) async throws -> OperatorWorkInput
    func pushResult(
        messageID: String,
        transcriptionId: String?,
        expectedLatestTranscriptionId: String?,
        inputSha256: String?,
        result: OperatorJobResult
    ) async throws
}

public enum OperatorClientError: Error, Sendable, Equatable {
    case notConfigured
    case unauthorized
    case http(Int)
    case malformedResponse(String)
    case missingTranscriptionId
}

/// Default `AsyncHTTPClient`-backed implementation.
public final class HTTPOperatorClient: OperatorClient {
    private let httpClient: HTTPClient
    private let config: OperatorPollingConfig
    /// Resolves the current `Authorization` header value per request. Returns
    /// `nil` when no valid Operator token exists.
    private let authHeaderProvider: @Sendable () async -> String?
    private let logger: Logger
    private let timeout: TimeAmount

    public init(
        httpClient: HTTPClient,
        config: OperatorPollingConfig,
        authHeaderProvider: @escaping @Sendable () async -> String?,
        timeout: TimeAmount = .seconds(30),
        logger: Logger = Logger(label: "operator-client")
    ) {
        self.httpClient = httpClient
        self.config = config
        self.authHeaderProvider = authHeaderProvider
        self.timeout = timeout
        self.logger = logger
    }

    /// Convenience initializer for a static Operator API token.
    public convenience init(
        httpClient: HTTPClient,
        config: OperatorPollingConfig,
        token: String,
        timeout: TimeAmount = .seconds(30),
        logger: Logger = Logger(label: "operator-client")
    ) {
        self.init(
            httpClient: httpClient,
            config: config,
            authHeaderProvider: { OperatorPollingConfig.bearerAuthorizationHeader(for: token) },
            timeout: timeout,
            logger: logger
        )
    }

    public func listWork(
        needs: OperatorWorkNeeds,
        limit: Int,
        cursor: String?
    ) async throws -> OperatorWorkListPage {
        var path = "/v1/worker/messages?needs=\(needs.rawValue)&limit=\(max(1, min(200, limit)))"
        if let cursor, !cursor.isEmpty {
            path += "&cursor=\(escapeQuery(cursor))"
        }
        return try await getJSON(path: path, label: "work list")
    }

    public func fetchWorkInput(messageID: String) async throws -> OperatorWorkInput {
        try await getJSON(
            path: "/v1/worker/messages/\(escape(messageID))/work",
            label: "work input"
        )
    }

    private func getJSON<Response: Decodable>(path: String, label: String) async throws -> Response {
        var request = try await makeRequest(method: .GET, path: path)
        request.headers.add(name: "Accept", value: "application/json")
        let response = try await execute(request)
        switch response.status.code {
        case 200:
            let buffer = try await collect(response.body)
            let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
            do {
                return try JSONDecoder().decode(Response.self, from: Data(bytes))
            } catch {
                throw OperatorClientError.malformedResponse("\(label): \(type(of: error))")
            }
        case 401, 403:
            _ = try? await collect(response.body)
            throw OperatorClientError.unauthorized
        default:
            _ = try? await collect(response.body)
            throw OperatorClientError.http(Int(response.status.code))
        }
    }

    public func pushResult(
        messageID: String,
        transcriptionId: String?,
        expectedLatestTranscriptionId: String?,
        inputSha256: String?,
        result: OperatorJobResult
    ) async throws {
        switch result {
        case .transcription(let text, let language, let model):
            var body: [String: Any] = [
                "text": text,
                "language": language ?? NSNull(),
                "model": model ?? NSNull(),
                "expectedLatestTranscriptionId": expectedLatestTranscriptionId ?? NSNull()
            ]
            // Only sent when the Operator pre-created a pending row for this job.
            if let transcriptionId, !transcriptionId.isEmpty {
                body["transcriptionId"] = transcriptionId
            }
            try await postJSON(path: "/v1/worker/messages/\(escape(messageID))/transcription", body: body)
        case .translation(let translatedText, let sourceLanguage, let targetLanguage, let model):
            guard let transcriptionId, !transcriptionId.isEmpty else {
                throw OperatorClientError.missingTranscriptionId
            }
            guard let inputSha256, !inputSha256.isEmpty else {
                throw OperatorClientError.malformedResponse("missing translation input hash")
            }
            let body: [String: Any] = [
                "transcriptionId": transcriptionId,
                "inputSha256": inputSha256,
                "translatedText": translatedText,
                "sourceLanguage": sourceLanguage ?? NSNull(),
                "targetLanguage": targetLanguage,
                "model": model ?? NSNull()
            ]
            try await postJSON(path: "/v1/worker/messages/\(escape(messageID))/translation", body: body)
        case .moderation(let flagged, let recommendation, let maxScore, let model):
            guard let transcriptionId, !transcriptionId.isEmpty else {
                throw OperatorClientError.missingTranscriptionId
            }
            guard let inputSha256, !inputSha256.isEmpty else {
                throw OperatorClientError.malformedResponse("missing moderation input hash")
            }
            let body: [String: Any] = [
                "transcriptionId": transcriptionId,
                "inputSha256": inputSha256,
                "flagged": flagged,
                "recommendation": normalizedRecommendation(recommendation),
                "maxScore": max(0, min(1, maxScore)),
                "categories": [String: Any](),
                "model": model ?? NSNull()
            ]
            try await postJSON(path: "/v1/worker/messages/\(escape(messageID))/moderation", body: body)
        }
    }

    private func postJSON(path: String, body: [String: Any]) async throws {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = try await makeRequest(method: .POST, path: path)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Accept", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: bodyData))
        let response = try await execute(request)
        _ = try? await collect(response.body)
        guard (200..<300).contains(Int(response.status.code)) else {
            if response.status.code == 401 || response.status.code == 403 {
                throw OperatorClientError.unauthorized
            }
            throw OperatorClientError.http(Int(response.status.code))
        }
    }

    private func makeRequest(method: HTTPMethod, path: String) async throws -> HTTPClientRequest {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard !base.isEmpty else { throw OperatorClientError.notConfigured }
        guard config.usesSecureTokenTransport else { throw OperatorClientError.notConfigured }
        guard let header = OperatorPollingConfig.bearerAuthorizationHeader(for: await authHeaderProvider()) else {
            throw OperatorClientError.unauthorized
        }
        var request = HTTPClientRequest(url: base + path)
        request.method = method
        request.headers.add(name: "Authorization", value: header)
        request.headers.add(name: "User-Agent", value: config.userAgent)
        return request
    }

    private func execute(_ request: HTTPClientRequest) async throws -> HTTPClientResponse {
        let deadline = NIODeadline.now() + timeout
        return try await httpClient.execute(request, deadline: deadline)
    }

    private func collect(_ body: HTTPClientResponse.Body) async throws -> ByteBuffer {
        try await body.collect(upTo: 8 * 1024 * 1024)
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func escapeQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private func normalizedRecommendation(_ value: String) -> String {
        switch value.lowercased() {
        case "approve", "allow", "allowed": return "approve"
        case "reject", "block", "blocked": return "reject"
        default: return "review"
        }
    }
}
