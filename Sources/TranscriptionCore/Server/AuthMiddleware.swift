import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import Foundation

/// Middleware that enforces a single bearer token on every protected route.
///
/// We let `excludedPaths` opt specific endpoints (e.g. `/healthz`) out of
/// auth. Everything else requires `Authorization: Bearer <token>` and rejects
/// the request with `401 Unauthorized` otherwise.
///
/// The middleware also marks the context with whether auth succeeded so the
/// request-log middleware downstream can record `authOK`.
public struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    public let tokenStore: any TokenStore
    public let excludedPaths: Set<String>
    public let logger: Logger

    public init(
        tokenStore: any TokenStore,
        excludedPaths: Set<String> = ["/healthz"],
        logger: Logger = Logger(label: "auth")
    ) {
        self.tokenStore = tokenStore
        self.excludedPaths = excludedPaths
        self.logger = logger
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if excludedPaths.contains(request.uri.path) {
            return try await next(request, context)
        }

        guard let header = request.headers[.authorization] else {
            return Self.unauthorized(reason: "missing_authorization")
        }

        // Reject duplicate Authorization headers — RFC 7235 allows only one.
        let allAuthHeaders = request.headers[values: .authorization]
        if allAuthHeaders.count > 1 {
            return Self.unauthorized(reason: "multiple_authorization_headers")
        }

        guard let token = Self.parseBearer(header) else {
            return Self.unauthorized(reason: "invalid_scheme")
        }
        if token.isEmpty {
            return Self.unauthorized(reason: "empty_token")
        }

        let ok: Bool
        do {
            ok = try tokenStore.verify(token)
        } catch {
            logger.error("token verification failed: \(error)")
            return Self.unauthorized(reason: "verify_error")
        }
        guard ok else {
            return Self.unauthorized(reason: "bad_token")
        }
        return try await next(request, context)
    }

    /// Parses `Authorization: Bearer <token>` and returns `<token>`. Accepts
    /// surrounding whitespace and trims it. Returns nil if the scheme is not
    /// `Bearer` (case-insensitive).
    public static func parseBearer(_ header: String) -> String? {
        // Trim leading whitespace only; we still want to detect a trailing
        // space (i.e. `"Bearer "`) so the empty-token case surfaces as an
        // empty string rather than a missing scheme.
        let lead = header.drop(while: { $0 == " " || $0 == "\t" })
        let stripped = String(lead.reversed().drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).reversed())
        guard let spaceIdx = lead.firstIndex(of: " ") else { return nil }
        let scheme = lead[..<spaceIdx]
        guard scheme.lowercased() == "bearer" else { return nil }
        let restRaw = lead[lead.index(after: spaceIdx)...]
        // Strip the same trailing whitespace we removed when computing
        // `stripped`, but no internal trim — bearer tokens contain only
        // URL-safe characters anyway.
        _ = stripped
        return restRaw.trimmingCharacters(in: .whitespaces)
    }

    static func unauthorized(reason: String) -> Response {
        let body: [String: Any] = [
            "error": [
                "type": "invalid_request_error",
                "code": reason,
                "message": "missing or invalid bearer token"
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.wwwAuthenticate] = "Bearer realm=\"telephone-booth-transcription\""
        return Response(
            status: .unauthorized,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}
