import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Handler for `POST /v1/audio/translations`. OpenAI-compatible multipart
/// upload that translates audio in any supported language into English text.
///
/// Wire format and error envelope match `TranscriptionRoute`; the realm is
/// served by a separate `TranslationBackendImpl` so the upstream URL, API key,
/// and default model can be configured independently of the transcription
/// upstream (e.g. a different LM serving Whisper-large on a different host).
public struct TranslationRoute<Context: RequestContext>: Sendable {
    public let backend: any TranslationBackendImpl
    public let maxRequestBytes: Int

    public init(backend: any TranslationBackendImpl, maxRequestBytes: Int) {
        self.backend = backend
        self.maxRequestBytes = maxRequestBytes
    }

    public func handle(_ request: Request, context: Context) async throws -> Response {
        guard let contentType = request.headers[.contentType] else {
            return Self.errorResponse(status: .badRequest, code: "missing_content_type",
                                      message: "Content-Type header required (expected multipart/form-data)")
        }
        guard contentType.lowercased().contains("multipart/form-data") else {
            return Self.errorResponse(status: .badRequest, code: "unsupported_content_type",
                                      message: "expected multipart/form-data")
        }

        let collected: ByteBuffer
        do {
            collected = try await request.body.collect(upTo: maxRequestBytes)
        } catch {
            return Self.errorResponse(status: .contentTooLarge, code: "request_too_large",
                                      message: "request body exceeded \(maxRequestBytes) bytes")
        }

        do {
            return try await backend.handle(body: collected, contentType: contentType)
        } catch let TranslationBackendError.badRequest(message) {
            return Self.errorResponse(status: .badRequest, code: "bad_request", message: message)
        } catch let TranslationBackendError.unauthorized(message) {
            return Self.errorResponse(status: .forbidden, code: "permission_denied", message: message)
        } catch let TranslationBackendError.timeout(message) {
            return Self.errorResponse(status: .gatewayTimeout, code: "timeout", message: message)
        } catch let TranslationBackendError.upstream(status, body) {
            return Self.passthroughError(status: status, body: body)
        } catch {
            return Self.errorResponse(status: .internalServerError, code: "internal_error",
                                      message: "translation backend error: \(error)")
        }
    }

    static func errorResponse(status: HTTPResponse.Status, code: String, message: String) -> Response {
        let body: [String: Any] = [
            "error": [
                "type": "invalid_request_error",
                "code": code,
                "message": message
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func passthroughError(status: Int, body: ByteBuffer) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .init(code: status), headers: headers, body: .init(byteBuffer: body))
    }
}

public enum TranslationBackendError: Error, Sendable {
    case badRequest(String)
    case unauthorized(String)
    case timeout(String)
    case upstream(status: Int, body: ByteBuffer)
}

/// Abstract handler for audio→English translation. The only concrete
/// implementation today is `ProxyTranslationBackend`; native macOS engines
/// don't translate, so picking a native transcription backend leaves the
/// translation realm proxy-only.
public protocol TranslationBackendImpl: Sendable {
    func handle(body: ByteBuffer, contentType: String) async throws -> Response
}
