import Foundation
import Logging
import TranscriptionShared

/// Subscribes to Operator status events and yields only `work` envelopes.
public protocol OperatorWorkChannel: Sendable {
    func connect() async throws -> AsyncStream<OperatorWorkEnvelope>
    func disconnect() async
}

public enum OperatorWorkChannelError: Error, Sendable, Equatable {
    case notConfigured
    case unauthorized
    case invalidBaseURL
}

/// `URLSessionWebSocketTask` backed status subscription.
public actor URLSessionOperatorWorkChannel: OperatorWorkChannel {
    private let config: OperatorPollingConfig
    private let authHeaderProvider: @Sendable () async -> String?
    private let logger: Logger
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<OperatorWorkEnvelope>.Continuation?

    public init(
        config: OperatorPollingConfig,
        authHeaderProvider: @escaping @Sendable () async -> String?,
        logger: Logger = Logger(label: "operator-work-channel")
    ) {
        self.config = config
        self.authHeaderProvider = authHeaderProvider
        self.logger = logger
    }

    public func connect() async throws -> AsyncStream<OperatorWorkEnvelope> {
        await disconnect()
        guard !config.baseURL.isEmpty else { throw OperatorWorkChannelError.notConfigured }
        guard config.usesSecureTokenTransport else { throw OperatorWorkChannelError.invalidBaseURL }
        guard let header = OperatorPollingConfig.bearerAuthorizationHeader(for: await authHeaderProvider()) else {
            throw OperatorWorkChannelError.unauthorized
        }
        guard let url = Self.statusWebSocketURL(from: config.baseURL) else {
            throw OperatorWorkChannelError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        let wsTask = URLSession.shared.webSocketTask(with: request)
        let pair = AsyncStream<OperatorWorkEnvelope>.makeStream(of: OperatorWorkEnvelope.self)
        pair.continuation.onTermination = { [weak wsTask] _ in wsTask?.cancel(with: .goingAway, reason: nil) }
        continuation = pair.continuation
        task = wsTask
        wsTask.resume()
        receiveLoop(task: wsTask)
        return pair.stream
    }

    public func disconnect() async {
        continuation?.finish()
        continuation = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private nonisolated static func statusWebSocketURL(from baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: return nil
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/v1/ws/status" : "/\(basePath)/v1/ws/status"
        components.query = nil
        return components.url
    }

    private func receiveLoop(task wsTask: URLSessionWebSocketTask) {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await wsTask.receive()
                    await self.handle(message)
                } catch {
                    await self.finishCurrentTask(wsTask, error: error)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let bytes): data = bytes
        @unknown default: data = nil
        }
        guard let data else { return }
        do {
            if let envelope = try OperatorWorkEnvelope.decodeWork(from: data) {
                continuation?.yield(envelope)
            }
        } catch {
            logger.debug("ignored malformed operator websocket envelope: \(type(of: error))")
        }
    }

    private func finishCurrentTask(_ wsTask: URLSessionWebSocketTask, error: any Error) {
        guard task === wsTask else { return }
        logger.debug("operator websocket disconnected: \(type(of: error))")
        continuation?.finish()
        continuation = nil
        task = nil
    }
}
