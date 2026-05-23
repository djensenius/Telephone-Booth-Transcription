import Foundation
import Hummingbird
import NIOCore

public struct HealthRoute<Context: RequestContext>: Sendable {
    public init() {}

    public func handle(_ request: Request, context: Context) async throws -> Response {
        let payload: [String: Any] = [
            "status": "ok",
            "service": "telephone-booth-transcription"
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
