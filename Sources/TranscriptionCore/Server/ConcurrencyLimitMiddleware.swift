import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore

/// Middleware that limits the number of concurrent in-flight requests.
/// When the limit is reached, new requests receive a 503 Service Unavailable.
/// A limit of 0 means unlimited (the middleware passes through immediately).
public struct ConcurrencyLimitMiddleware<Context: RequestContext>: RouterMiddleware, Sendable {
    private let semaphore: AsyncSemaphore
    private let limit: Int
    private let excludedPaths: Set<String>
    private let logger: Logger

    public init(
        maxConcurrent: Int,
        excludedPaths: Set<String> = [],
        logger: Logger = Logger(label: "concurrency-limit")
    ) {
        self.limit = maxConcurrent
        self.excludedPaths = excludedPaths
        self.semaphore = AsyncSemaphore(count: maxConcurrent)
        self.logger = logger
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard limit > 0 else {
            return try await next(request, context)
        }

        if excludedPaths.contains(request.uri.path) {
            return try await next(request, context)
        }

        guard await semaphore.tryWait() else {
            logger.warning("concurrency limit reached (\(limit)), rejecting request")
            return Self.overloadResponse()
        }

        do {
            let response = try await next(request, context)
            await semaphore.signal()
            return response
        } catch {
            await semaphore.signal()
            throw error
        }
    }

    private static func overloadResponse() -> Response {
        let body: [String: Any] = [
            "error": [
                "type": "server_error",
                "code": "overloaded",
                "message": "server is at maximum capacity, please retry later"
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: .serviceUnavailable,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}

/// A simple async semaphore using an actor to manage concurrency.
public actor AsyncSemaphore {
    private var count: Int
    private let maxCount: Int

    public init(count: Int) {
        self.count = count
        self.maxCount = count
    }

    /// Attempts to acquire a permit without blocking.
    /// Returns `true` if a permit was acquired, `false` otherwise.
    public func tryWait() -> Bool {
        if count > 0 {
            count -= 1
            return true
        }
        return false
    }

    /// Releases a permit back to the semaphore.
    public func signal() {
        count = min(count + 1, maxCount)
    }
}
