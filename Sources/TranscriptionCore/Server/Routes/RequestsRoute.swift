import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// `GET /v1/requests` — returns the most recent request log entries.
public struct RequestsRoute<Context: RequestContext>: Sendable {
    public let store: any RequestLogStoring
    public let defaultLimit: Int

    public init(store: any RequestLogStoring, defaultLimit: Int = 100) {
        self.store = store
        self.defaultLimit = defaultLimit
    }

    public func handle(_ request: Request, context: Context) async throws -> Response {
        var limit = defaultLimit
        if let raw = request.uri.queryParameters["limit"],
           let parsed = Int(raw), parsed > 0 {
            limit = min(parsed, 1000)
        }
        let entries = try await store.recent(limit: limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(["data": entries])
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
