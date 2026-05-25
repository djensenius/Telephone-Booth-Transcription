import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// Thin wrapper around `AsyncHTTPClient` that proxies OpenAI-compatible requests
/// (multipart for `/v1/audio/transcriptions`, JSON for `/v1/moderations` and
/// `/v1/chat/completions`) to a user-configured upstream base URL.
///
/// The proxy is intentionally schema-blind for the request body — we forward the
/// raw bytes and content-type unchanged so newly-added OpenAI parameters keep
/// working without code changes. Only `model` is extracted (from query/multipart/
/// JSON) for logging, and that extraction is best-effort.
public final class OpenAIUpstream: Sendable {
    public struct ProxyResult: Sendable {
        public let status: Int
        public let headers: [(String, String)]
        public let body: ByteBuffer
    }

    public let httpClient: HTTPClient
    public let logger: Logger
    public let timeout: TimeAmount

    public init(
        httpClient: HTTPClient,
        timeout: TimeAmount = .seconds(300),
        logger: Logger = Logger(label: "openai-upstream")
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
        self.logger = logger
    }

    // MARK: - Endpoint-specific body caps

    /// Default cap for transcription responses (SRT/VTT/JSON — typically small).
    public static let transcriptionMaxResponseBytes = 10 * 1024 * 1024  // 10 MB
    /// Default cap for moderation/chat JSON responses.
    public static let moderationMaxResponseBytes = 1 * 1024 * 1024      // 1 MB
    /// Default cap for model-listing responses.
    public static let modelsMaxResponseBytes = 256 * 1024               // 256 KB

    /// Proxies a request to `<upstream.baseURL>/<pathSuffix>`.
    /// - Parameters:
    ///   - upstream: target upstream config.
    ///   - method: HTTP method.
    ///   - pathSuffix: path appended to `baseURL`, leading slash optional.
    ///   - contentType: forwarded `Content-Type` header (preserves multipart boundary).
    ///   - body: raw request body to forward verbatim.
    ///   - extraHeaders: additional headers to attach (e.g. `Accept`).
    ///   - maxResponseBytes: maximum response body size to collect before
    ///     throwing `UpstreamError.responseTooLarge`. Defaults to 10 MB.
    public func proxy(
        upstream: UpstreamConfig,
        method: HTTPMethod,
        pathSuffix: String,
        contentType: String?,
        body: ByteBuffer?,
        extraHeaders: [(String, String)] = [],
        maxResponseBytes: Int = transcriptionMaxResponseBytes
    ) async throws -> ProxyResult {
        let url = joinURL(base: upstream.baseURL, path: pathSuffix)
        var request = HTTPClientRequest(url: url)
        request.method = method
        if let ct = contentType {
            request.headers.add(name: "Content-Type", value: ct)
        }
        if let apiKey = upstream.apiKey, !apiKey.isEmpty {
            request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        }
        for (k, v) in extraHeaders {
            request.headers.add(name: k, value: v)
        }
        if let body {
            request.body = .bytes(body)
        }

        let deadline = NIODeadline.now() + .nanoseconds(timeout.asNanoseconds)
        let response = try await httpClient.execute(request, deadline: deadline)

        let buffer: ByteBuffer
        do {
            buffer = try await response.body.collect(upTo: maxResponseBytes)
        } catch is NIOTooManyBytesError {
            throw UpstreamError.responseTooLarge(maxBytes: maxResponseBytes)
        }
        let headers: [(String, String)] = response.headers.map { ($0.name, $0.value) }
        return ProxyResult(
            status: Int(response.status.code),
            headers: headers,
            body: buffer
        )
    }

    /// Joins a base URL and a path, handling slash duplication.
    private func joinURL(base: String, path: String) -> String {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        return trimmedBase + suffix
    }
}

/// Extracted `model` field for logging, best-effort.
public enum ModelExtractor {
    /// Returns the value of the `model` field from a multipart/form-data body,
    /// or nil if absent. We do a very small parser since the request body has
    /// already been validated as multipart by the time we get here.
    public static func extractModelFromMultipart(_ body: ByteBuffer, contentType: String) -> String? {
        guard let boundary = parseBoundary(from: contentType) else { return nil }
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        guard let text = String(data: Data(bytes), encoding: .utf8) else { return nil }
        let delimiter = "--\(boundary)"
        let parts = text.components(separatedBy: delimiter)
        for part in parts {
            // Headers and body are separated by CRLF CRLF
            guard let headerEnd = part.range(of: "\r\n\r\n") else { continue }
            let headers = part[..<headerEnd.lowerBound]
            let body = part[headerEnd.upperBound...]
            if headers.contains("name=\"model\"") {
                let trimmed = body.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n-"))
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    public static func extractModelFromJSON(_ body: ByteBuffer) -> String? {
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return nil
        }
        return obj["model"] as? String
    }

    private static func parseBoundary(from contentType: String) -> String? {
        // Content-Type: multipart/form-data; boundary=----WebKitFormBoundary…
        let parts = contentType.split(separator: ";")
        for raw in parts {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.lowercased().hasPrefix("boundary=") {
                let value = String(p.dropFirst("boundary=".count))
                // Strip optional surrounding quotes.
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    return String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        return nil
    }
}
