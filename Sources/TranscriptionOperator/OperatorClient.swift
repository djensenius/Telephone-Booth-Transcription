import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import TranscriptionShared

/// Minimal HTTP client for the Operator's `/v1/jobs/*` API. Abstracted
/// behind a protocol so the worker can be unit-tested without a real
/// Operator instance.
public protocol OperatorClient: Sendable {
    /// Calls `GET /v1/jobs/next`. Returns nil on 204 (no work available).
    func leaseNextJob() async throws -> OperatorJob?

    /// Calls `POST /v1/jobs/{id}/succeed` with the encoded result.
    func submitSuccess(jobID: String, leaseToken: String, result: OperatorJobResult) async throws

    /// Calls `POST /v1/jobs/{id}/fail` with the sanitized error.
    func submitFailure(jobID: String, leaseToken: String, error: OperatorJobError) async throws

    /// Calls `POST /v1/jobs/{id}/heartbeat` to extend the lease. Reserved
    /// for long-running jobs; the default worker doesn't issue this.
    func heartbeat(jobID: String, leaseToken: String) async throws
}

public enum OperatorClientError: Error, Sendable, Equatable {
    case notConfigured
    case unauthorized
    case http(Int)
    case malformedResponse(String)
}

/// Default `AsyncHTTPClient`-backed implementation.
public final class HTTPOperatorClient: OperatorClient {
    private let httpClient: HTTPClient
    private let config: OperatorPollingConfig
    /// Resolves the current `Authorization` header value (e.g.
    /// `"Bearer <token>"`) per request, allowing the credential to refresh or
    /// expire between polls. Returns `nil` when no valid session exists.
    private let authHeaderProvider: @Sendable () async -> String?
    private let logger: Logger
    private let timeout: TimeAmount
    private let capabilities: Set<OperatorJob.Kind>?

    public init(
        httpClient: HTTPClient,
        config: OperatorPollingConfig,
        authHeaderProvider: @escaping @Sendable () async -> String?,
        timeout: TimeAmount = .seconds(30),
        capabilities: Set<OperatorJob.Kind>? = nil,
        logger: Logger = Logger(label: "operator-client")
    ) {
        self.httpClient = httpClient
        self.config = config
        self.authHeaderProvider = authHeaderProvider
        self.timeout = timeout
        self.capabilities = capabilities
        self.logger = logger
    }

    /// Convenience initializer for a static bearer token. Wraps the token in a
    /// provider that returns the same `Authorization` header every call.
    public convenience init(
        httpClient: HTTPClient,
        config: OperatorPollingConfig,
        token: String,
        timeout: TimeAmount = .seconds(30),
        capabilities: Set<OperatorJob.Kind>? = nil,
        logger: Logger = Logger(label: "operator-client")
    ) {
        self.init(
            httpClient: httpClient,
            config: config,
            authHeaderProvider: { "Bearer \(token)" },
            timeout: timeout,
            capabilities: capabilities,
            logger: logger
        )
    }

    /// The kinds we are willing to lease: the configured kinds, optionally
    /// intersected with what this device can actually run. Order is stable.
    private var effectiveKinds: [OperatorJob.Kind] {
        let requested = config.requestedKindList
        guard let capabilities else { return requested }
        return requested.filter(capabilities.contains)
    }

    public func leaseNextJob() async throws -> OperatorJob? {
        let kinds = effectiveKinds
        // No leasable kinds means there is nothing we could run; never call
        // `/jobs/next` with an empty `kinds` (the Operator treats that as
        // "all kinds" and we'd lease work we can't perform).
        guard !kinds.isEmpty else { return nil }
        let kindsValue = kinds.map(\.rawValue).joined(separator: ",")
        let path = "/v1/jobs/next?leaseSeconds=\(config.leaseSeconds)&kinds=\(kindsValue)"
        var request = try await makeRequest(method: .GET, path: path)
        request.headers.add(name: "Accept", value: "application/json")
        let response = try await execute(request)
        switch response.status.code {
        case 204:
            return nil
        case 200:
            let buffer = try await collect(response.body)
            let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
            do {
                return try OperatorJob.decode(from: Data(bytes))
            } catch let error as OperatorJob.DecodeError {
                if case .malformed(let why) = error {
                    throw OperatorClientError.malformedResponse(why)
                }
                throw OperatorClientError.malformedResponse("\(error)")
            }
        case 401, 403:
            throw OperatorClientError.unauthorized
        default:
            throw OperatorClientError.http(Int(response.status.code))
        }
    }

    public func submitSuccess(jobID: String, leaseToken: String, result: OperatorJobResult) async throws {
        let bodyData = try result.encode(leaseToken: leaseToken)
        try await postJSON(path: "/v1/jobs/\(jobID)/succeed", body: bodyData)
    }

    public func submitFailure(jobID: String, leaseToken: String, error: OperatorJobError) async throws {
        let bodyData = try error.encode(leaseToken: leaseToken)
        try await postJSON(path: "/v1/jobs/\(jobID)/fail", body: bodyData)
    }

    public func heartbeat(jobID: String, leaseToken: String) async throws {
        let payload: [String: Any] = ["leaseToken": leaseToken]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        try await postJSON(path: "/v1/jobs/\(jobID)/heartbeat", body: bodyData)
    }

    private func postJSON(path: String, body: Data) async throws {
        var request = try await makeRequest(method: .POST, path: path)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: body))
        let response = try await execute(request)
        guard (200..<300).contains(Int(response.status.code)) else {
            // Drain body so the connection can be reused.
            _ = try? await collect(response.body)
            if response.status.code == 401 || response.status.code == 403 {
                throw OperatorClientError.unauthorized
            }
            throw OperatorClientError.http(Int(response.status.code))
        }
        // Drain to free the connection.
        _ = try? await collect(response.body)
    }

    private func makeRequest(method: HTTPMethod, path: String) async throws -> HTTPClientRequest {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard !base.isEmpty else { throw OperatorClientError.notConfigured }
        guard let header = await authHeaderProvider() else {
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
        // Bound at 8 MiB; the Operator should never return larger job payloads.
        try await body.collect(upTo: 8 * 1024 * 1024)
    }
}
