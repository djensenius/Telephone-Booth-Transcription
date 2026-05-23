import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Handler for `POST /v1/audio/transcriptions`. Dispatches to either the
/// configured proxy upstream or the macOS native transcriber based on
/// `Config.transcriptionBackend`.
public struct TranscriptionRoute<Context: RequestContext>: Sendable {
    public let backend: any TranscriptionBackendImpl
    public let maxRequestBytes: Int

    public init(backend: any TranscriptionBackendImpl, maxRequestBytes: Int) {
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
        } catch let TranscriptionBackendError.badRequest(message) {
            return Self.errorResponse(status: .badRequest, code: "bad_request", message: message)
        } catch let TranscriptionBackendError.unauthorized(message) {
            return Self.errorResponse(status: .forbidden, code: "permission_denied", message: message)
        } catch let TranscriptionBackendError.upstream(status, body) {
            return Self.passthroughError(status: status, body: body)
        } catch {
            return Self.errorResponse(status: .internalServerError, code: "internal_error",
                                      message: "transcription backend error: \(error)")
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

public enum TranscriptionBackendError: Error, Sendable {
    case badRequest(String)
    case unauthorized(String)
    case upstream(status: Int, body: ByteBuffer)
}

/// Abstract handler that takes the raw multipart request body and returns a
/// fully-formed OpenAI-shaped response. Concrete implementations:
///
/// - `ProxyTranscriptionBackend` — forwards to an OpenAI-compatible upstream.
/// - `NativeMacOSTranscriptionBackend` — runs `Speech.framework` on-device.
public protocol TranscriptionBackendImpl: Sendable {
    func handle(body: ByteBuffer, contentType: String) async throws -> Response
}
