import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// `GET /v1/models` — composite model list across the configured upstreams.
///
/// Result shape matches OpenAI's `/v1/models`:
///
/// ```json
/// { "object": "list", "data": [ { "id": "whisper-1", "object": "model", "owned_by": "transcription" }, ... ] }
/// ```
///
/// `owned_by` is overloaded to indicate which of the local app's three
/// upstreams reported the model: `transcription`, `translation`, or
/// `moderation`. Native macOS transcription is reported as `"id":
/// "macos-speech", "owned_by": "transcription"` so the picker UI can include
/// it in the same list.
public struct ModelsRoute<Context: RequestContext>: Sendable {
    public let upstream: OpenAIUpstream
    public let transcriptionUpstream: UpstreamConfig?
    public let translationUpstream: UpstreamConfig
    public let moderationUpstream: UpstreamConfig
    public let includeNativeMacOS: Bool

    public init(
        upstream: OpenAIUpstream,
        transcriptionUpstream: UpstreamConfig?,
        translationUpstream: UpstreamConfig,
        moderationUpstream: UpstreamConfig,
        includeNativeMacOS: Bool
    ) {
        self.upstream = upstream
        self.transcriptionUpstream = transcriptionUpstream
        self.translationUpstream = translationUpstream
        self.moderationUpstream = moderationUpstream
        self.includeNativeMacOS = includeNativeMacOS
    }

    public func handle(_ request: Request, context: Context) async throws -> Response {
        async let transcription: [[String: Any]] = fetchModels(from: transcriptionUpstream, owner: "transcription")
        async let translation:   [[String: Any]] = fetchModels(from: translationUpstream, owner: "translation")
        async let moderation:    [[String: Any]] = fetchModels(from: moderationUpstream, owner: "moderation")
        var combined = await transcription + (await translation) + (await moderation)
        if includeNativeMacOS {
            combined.insert([
                "id": "macos-speech-analyzer",
                "object": "model",
                "owned_by": "transcription",
                "created": 0
            ], at: 0)
            combined.insert([
                "id": "macos-speech",
                "object": "model",
                "owned_by": "transcription",
                "created": 0
            ], at: 1)
        }
        let payload: [String: Any] = ["object": "list", "data": combined]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func fetchModels(from upstreamConfig: UpstreamConfig?, owner: String) async -> [[String: Any]] {
        guard let upstreamConfig else { return [] }
        do {
            let res = try await upstream.proxy(
                upstream: upstreamConfig,
                method: .GET,
                pathSuffix: "/models",
                contentType: nil,
                body: nil,
                maxResponseBytes: OpenAIUpstream.modelsMaxResponseBytes
            )
            guard (200..<300).contains(res.status) else { return [] }
            let bytes = res.body.getBytes(at: res.body.readerIndex, length: res.body.readableBytes) ?? []
            guard let obj = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  let data = obj["data"] as? [[String: Any]] else {
                return []
            }
            return data.map { entry in
                var copy = entry
                copy["owned_by"] = owner
                return copy
            }
        } catch {
            return []
        }
    }
}
