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
    ///
    /// Operates on raw bytes so binary audio payloads are never decoded as text.
    public static func injectModelPart(body: ByteBuffer, boundary: String, model: String) -> ByteBuffer? {
        let closeMarker = Array("--\(boundary)--".utf8)
        let bodyBytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        guard let closeIndex = findSubsequence(closeMarker, in: bodyBytes) else { return nil }

        let part = Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n".utf8)

        var result = ByteBuffer()
        result.reserveCapacity(bodyBytes.count + part.count)
        result.writeBytes(bodyBytes[..<closeIndex])
        result.writeBytes(part)
        result.writeBytes(bodyBytes[closeIndex...])
        return result
    }

    /// Finds the first occurrence of `needle` in `haystack`, returning the start index.
    private static func findSubsequence(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let end = haystack.count - needle.count
        for i in 0...end {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) {
                return i
            }
        }
        return nil
    }
}
