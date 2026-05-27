import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Forwards the multipart translation request verbatim to an OpenAI-compatible
/// upstream's `/audio/translations` endpoint (audio → English text).
///
/// Mirrors `ProxyTranscriptionBackend` deliberately — the only differences are
/// the upstream path (`/audio/translations` instead of `/audio/transcriptions`)
/// and that the configured upstream is the dedicated **translation** upstream,
/// independent from the transcription one.
public struct ProxyTranslationBackend: TranslationBackendImpl {
    public let upstream: OpenAIUpstream
    public let upstreamConfig: UpstreamConfig
    public let defaultModel: String

    public init(upstream: OpenAIUpstream, upstreamConfig: UpstreamConfig, defaultModel: String = "") {
        self.upstream = upstream
        self.upstreamConfig = upstreamConfig
        self.defaultModel = defaultModel
    }

    public func handle(body: ByteBuffer, contentType: String) async throws -> Response {
        var bodyToSend = body
        if !defaultModel.isEmpty,
           ModelExtractor.extractModelFromMultipart(body, contentType: contentType) == nil,
           let boundary = MultipartHelpers.parseBoundary(from: contentType),
           let injected = MultipartHelpers.injectModelPart(body: body, boundary: boundary, model: defaultModel) {
            bodyToSend = injected
        }

        let result = try await upstream.proxy(
            upstream: upstreamConfig,
            method: .POST,
            pathSuffix: "/audio/translations",
            contentType: contentType,
            body: bodyToSend
        )

        var headers = HTTPFields()
        for (k, v) in result.headers where shouldForwardResponseHeader(k) {
            if let field = HTTPField.Name(k) {
                headers.append(HTTPField(name: field, value: v))
            }
        }
        return Response(
            status: .init(code: result.status),
            headers: headers,
            body: .init(byteBuffer: result.body)
        )
    }

    private func shouldForwardResponseHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "transfer-encoding", "connection", "keep-alive", "content-length":
            return false
        default:
            return true
        }
    }
}
