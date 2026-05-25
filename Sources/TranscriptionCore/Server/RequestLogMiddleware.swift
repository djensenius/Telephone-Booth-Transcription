import Foundation
import Hummingbird
import Logging
import NIOCore

/// Middleware that records every request to a bounded `RequestLogWriter`.
///
/// We log metadata only — never bodies — unless `Config.logBodies` is set
/// (currently unused at this layer; body capture would happen at the route
/// handler since we proxy raw bytes through).
public struct RequestLogMiddleware<Context: RequestContext>: RouterMiddleware {
    public let writer: RequestLogWriter
    public let logger: Logger

    public init(writer: RequestLogWriter, logger: Logger = Logger(label: "request-log")) {
        self.writer = writer
        self.logger = logger
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let started = Date()
        let clock = ContinuousClock()
        let t0 = clock.now
        var status: Int = 500
        var responseBytes: Int = 0
        var failureMessage: String?
        var authOK = true
        do {
            let response = try await next(request, context)
            status = Int(response.status.code)
            responseBytes = response.body.contentLength ?? 0
            if status == 401 { authOK = false }
            scheduleRecord(
                started: started,
                duration: clock.now - t0,
                request: request,
                status: status,
                responseBytes: responseBytes,
                authOK: authOK,
                error: nil
            )
            return response
        } catch {
            failureMessage = String(describing: type(of: error))
            scheduleRecord(
                started: started,
                duration: clock.now - t0,
                request: request,
                status: 500,
                responseBytes: 0,
                authOK: authOK,
                error: failureMessage
            )
            throw error
        }
    }

    private func scheduleRecord(
        started: Date,
        duration: Duration,
        request: Request,
        status: Int,
        responseBytes: Int,
        authOK: Bool,
        error: String?
    ) {
        let ms = Int(Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15)
        let entry = RequestLogEntry(
            receivedAt: started,
            method: request.method.rawValue,
            path: request.uri.path,
            status: status,
            durationMs: ms,
            clientIP: nil,
            model: nil,
            requestBytes: 0,
            responseBytes: responseBytes,
            authOK: authOK,
            moderationFlagged: nil,
            error: error
        )
        let writer = self.writer
        Task { await writer.enqueue(entry) }
    }
}
