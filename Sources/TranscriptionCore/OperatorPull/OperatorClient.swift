import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

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
    private let token: String
    private let logger: Logger
    private let timeout: TimeAmount

    public init(
        httpClient: HTTPClient,
        config: OperatorPollingConfig,
        token: String,
        timeout: TimeAmount = .seconds(30),
        logger: Logger = Logger(label: "operator-client")
    ) {
        self.httpClient = httpClient
        self.config = config
        self.token = token
        self.timeout = timeout
        self.logger = logger
    }

    public func leaseNextJob() async throws -> OperatorJob? {
        let kinds = config.requestedKinds
        var path = "/v1/jobs/next?leaseSeconds=\(config.leaseSeconds)"
        if !kinds.isEmpty {
            path += "&kinds=\(kinds)"
        }
        var request = try makeRequest(method: .GET, path: path)
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
        var request = try makeRequest(method: .POST, path: path)
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

    private func makeRequest(method: HTTPMethod, path: String) throws -> HTTPClientRequest {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard !base.isEmpty else { throw OperatorClientError.notConfigured }
        var request = HTTPClientRequest(url: base + path)
        request.method = method
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "User-Agent", value: config.userAgent)
        return request
    }

    private func execute(_ request: HTTPClientRequest) async throws -> HTTPClientResponse {
        let deadline = NIODeadline.now() + .nanoseconds(timeout.asNanoseconds)
        return try await httpClient.execute(request, deadline: deadline)
    }

    private func collect(_ body: HTTPClientResponse.Body) async throws -> ByteBuffer {
        // Bound at 8 MiB; the Operator should never return larger job payloads.
        try await body.collect(upTo: 8 * 1024 * 1024)
    }
}
