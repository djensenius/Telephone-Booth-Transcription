import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Forwards the multipart transcription request verbatim to an OpenAI-compatible
/// upstream (faster-whisper-server, OpenAI, etc.). Optionally injects a default
/// `model` field into the multipart body if the caller didn't specify one.
public struct ProxyTranscriptionBackend: TranscriptionBackendImpl {
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
            pathSuffix: "/audio/transcriptions",
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

/// Lightweight multipart helpers used by the proxy backend.
///
/// We intentionally do *not* parse the entire multipart envelope; we only need
/// to locate the boundary, sniff whether a `model` part is present, and
/// optionally append one. Everything else is forwarded verbatim.
public enum MultipartHelpers {
    public static func parseBoundary(from contentType: String) -> String? {
        let parts = contentType.split(separator: ";")
        for raw in parts {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.lowercased().hasPrefix("boundary=") {
                let value = String(p.dropFirst("boundary=".count))
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    return String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        return nil
    }

    /// Returns a new buffer with a `model` part inserted just before the
    /// closing `--boundary--` delimiter. Returns nil if the closing delimiter
    /// can't be located (in which case the caller forwards the body unchanged).
    public static func injectModelPart(body: ByteBuffer, boundary: String, model: String) -> ByteBuffer? {
        let close = "--\(boundary)--"
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        guard let bodyStr = String(data: Data(bytes), encoding: .utf8) else { return nil }
        guard let closeRange = bodyStr.range(of: close) else { return nil }
        let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n"
        let new = bodyStr.replacingCharacters(in: closeRange.lowerBound..<closeRange.lowerBound, with: part)
        guard let data = new.data(using: .utf8) else { return nil }
        return ByteBuffer(bytes: Array(data))
    }
}
