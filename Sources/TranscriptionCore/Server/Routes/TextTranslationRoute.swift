import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import TranscriptionShared

/// `POST /v1/translations` — JSON in / JSON out convenience endpoint that
/// translates already-transcribed text to English. Backed by a
/// `TextTranslator` which calls the translation upstream's `/chat/completions`.
///
/// Wire format:
///
/// ```json
/// // request
/// { "input": "…", "source_language": "fr" }
/// // response
/// { "translated_text": "…", "source_language": "fr", "target_language": "en", "model": "…" }
/// ```
///
/// This is **not** an OpenAI-standard endpoint. The OpenAI-compatible audio
/// translation lives at `POST /v1/audio/translations`. The text endpoint
/// exists for callers (e.g. the operator push worker) that already
/// have a transcript and want English text without re-uploading audio.
public struct TextTranslationRoute<Context: RequestContext>: Sendable {
    public let translator: TextTranslator
    public let backend: TextServiceBackend
    public let onDeviceTranslator: (any TextTranslationService)?
    public let maxRequestBytes: Int

    public init(
        translator: TextTranslator,
        backend: TextServiceBackend = .proxy,
        onDeviceTranslator: (any TextTranslationService)? = nil,
        maxRequestBytes: Int
    ) {
        self.translator = translator
        self.backend = backend
        self.onDeviceTranslator = onDeviceTranslator
        self.maxRequestBytes = maxRequestBytes
    }

    public func handle(_ request: Request, context: Context) async throws -> Response {
        let body: ByteBuffer
        do {
            body = try await request.body.collect(upTo: maxRequestBytes)
        } catch {
            return Self.errorResponse(status: .contentTooLarge, code: "request_too_large",
                                      message: "request body exceeded \(maxRequestBytes) bytes")
        }
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return Self.errorResponse(status: .badRequest, code: "invalid_json",
                                      message: "request body must be a JSON object")
        }
        guard let input = obj["input"] as? String, !input.isEmpty else {
            return Self.errorResponse(status: .badRequest, code: "missing_input",
                                      message: "`input` must be a non-empty string")
        }
        let sourceLanguage = obj["source_language"] as? String

        if backend == .onDevice {
            return await handleOnDevice(input: input, sourceLanguage: sourceLanguage)
        }

        // Reject early when the translation model is not configured. Without it,
        // we'd send `"model": ""` to the upstream and surface a confusing
        // 400 as `translation_upstream_http_400`.
        if translator.model.trimmingCharacters(in: .whitespaces).isEmpty {
            return Self.errorResponse(
                status: .badRequest,
                code: "missing_translation_model",
                message: "translation model is not configured; set `defaultTranslationModel`"
            )
        }

        do {
            let translation = try await translator.translateToEnglish(
                input: input,
                sourceLanguage: sourceLanguage
            )
            let payload: [String: Any] = [
                "translated_text": translation.translatedText,
                "source_language": translation.sourceLanguage ?? NSNull(),
                "target_language": translation.targetLanguage,
                "model": translator.model
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch TextTranslator.TranslatorError.chatCompletionsUnsupported {
            return Self.errorResponse(
                status: .badGateway,
                code: "translation_upstream_no_chat",
                message: "translation upstream does not implement /chat/completions; "
                + "POST /v1/audio/translations (audio→English) still works"
            )
        } catch TextTranslator.TranslatorError.upstreamHTTP(let code) {
            return Self.errorResponse(status: .badGateway, code: "translation_upstream_http_\(code)",
                                      message: "translation upstream returned HTTP \(code)")
        } catch TextTranslator.TranslatorError.malformedResponse(let why) {
            return Self.errorResponse(status: .badGateway, code: "translation_malformed",
                                      message: "translation upstream returned malformed response: \(why)")
        } catch UpstreamError.responseTooLarge(let maxBytes) {
            return Self.errorResponse(status: .badGateway, code: "upstream_response_too_large",
                                      message: "upstream response exceeded \(maxBytes) byte limit")
        } catch UpstreamError.deadlineExceeded {
            return Self.errorResponse(status: .gatewayTimeout, code: "upstream_timeout",
                                      message: "translation upstream timed out")
        } catch UpstreamError.insecureUpstream(let url) {
            return Self.errorResponse(status: .badGateway, code: "insecure_upstream",
                                      message: "refusing to send API key to insecure upstream: \(url)")
        } catch {
            return Self.errorResponse(status: .badGateway, code: "translation_error",
                                      message: "translation error: \(error)")
        }
    }

    /// On-device translation path: translate with Apple's Foundation Models, no
    /// network upstream. Returns an explicit 503 when the capability is
    /// unavailable rather than silently proxying.
    private func handleOnDevice(input: String, sourceLanguage: String?) async -> Response {
        guard let onDeviceTranslator else {
            return Self.errorResponse(
                status: .serviceUnavailable, code: "on_device_unavailable",
                message: "on-device translation requires Apple Intelligence (macOS 26 / iOS 26) "
                + "and is not available on this device")
        }
        do {
            let translation = try await onDeviceTranslator.translate(input, sourceLanguage: sourceLanguage)
            let payload: [String: Any] = [
                "translated_text": translation.translatedText,
                "source_language": translation.sourceLanguage ?? NSNull(),
                "target_language": translation.targetLanguage,
                "model": translation.model ?? "apple-foundation-models"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch let error as OnDeviceServiceError {
            switch error {
            case .badRequest(let why):
                return Self.errorResponse(status: .badRequest, code: "invalid_input", message: why)
            case .unauthorized(let why):
                return Self.errorResponse(status: .forbidden, code: "on_device_unauthorized", message: why)
            case .timeout(let why):
                return Self.errorResponse(status: .gatewayTimeout, code: "on_device_timeout", message: why)
            case .unavailable(let why):
                return Self.errorResponse(status: .serviceUnavailable, code: "on_device_unavailable", message: why)
            }
        } catch {
            return Self.errorResponse(status: .badGateway, code: "on_device_error",
                                      message: "on-device translation error: \(error)")
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
}
