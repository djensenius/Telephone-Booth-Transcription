import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import TranscriptionShared

/// `POST /v1/moderations` — see `docs/moderation.md` for the dual-path
/// strategy (native upstream, then chat-completion fallback).
public struct ModerationRoute<Context: RequestContext>: Sendable {
    public let upstream: OpenAIUpstream
    public let upstreamConfig: UpstreamConfig
    public let classifier: ModerationClassifier
    public let backend: TextServiceBackend
    public let onDeviceModerator: (any TextModerationService)?
    public let maxRequestBytes: Int
    public let fallbackEnabled: Bool

    public init(
        upstream: OpenAIUpstream,
        upstreamConfig: UpstreamConfig,
        classifier: ModerationClassifier,
        backend: TextServiceBackend = .proxy,
        onDeviceModerator: (any TextModerationService)? = nil,
        maxRequestBytes: Int,
        fallbackEnabled: Bool
    ) {
        self.upstream = upstream
        self.upstreamConfig = upstreamConfig
        self.classifier = classifier
        self.backend = backend
        self.onDeviceModerator = onDeviceModerator
        self.maxRequestBytes = maxRequestBytes
        self.fallbackEnabled = fallbackEnabled
    }

    public func handle(_ request: Request, context: Context) async throws -> Response {
        let body: ByteBuffer
        do {
            body = try await request.body.collect(upTo: maxRequestBytes)
        } catch {
            return Self.errorResponse(status: .contentTooLarge, code: "request_too_large",
                                      message: "request body exceeded \(maxRequestBytes) bytes")
        }

        if backend == .onDevice {
            return await handleOnDevice(body: body)
        }

        // Try native upstream first.
        let proxyAttempt: OpenAIUpstream.ProxyResult?
        do {
            proxyAttempt = try await upstream.proxy(
                upstream: upstreamConfig,
                method: .POST,
                pathSuffix: "/moderations",
                contentType: request.headers[.contentType] ?? "application/json",
                body: body,
                maxResponseBytes: OpenAIUpstream.moderationMaxResponseBytes
            )
        } catch {
            proxyAttempt = nil
        }

        if let attempt = proxyAttempt, (200..<300).contains(attempt.status) {
            var headers = HTTPFields()
            for (k, v) in attempt.headers {
                if ["transfer-encoding", "connection", "keep-alive", "content-length"]
                    .contains(k.lowercased()) { continue }
                if let field = HTTPField.Name(k) {
                    headers.append(HTTPField(name: field, value: v))
                }
            }
            return Response(
                status: .init(code: attempt.status),
                headers: headers,
                body: .init(byteBuffer: attempt.body)
            )
        }

        // Fallback path: classify locally.
        guard fallbackEnabled else {
            let status = proxyAttempt?.status ?? 502
            return Self.errorResponse(status: .init(code: status), code: "upstream_unavailable",
                                      message: "moderation upstream did not return a 2xx; fallback disabled")
        }

        let inputs = Self.parseInputs(body: body)
        guard !inputs.isEmpty else {
            return Self.errorResponse(status: .badRequest, code: "missing_input",
                                      message: "request must contain `input` (string or array of strings)")
        }
        do {
            let response = try await classifier.classify(inputs: inputs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(response)
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch ModerationClassifier.ClassifierError.upstreamHTTP(let code) {
            return Self.errorResponse(status: .badGateway, code: "classifier_upstream_http_\(code)",
                                      message: "local classifier upstream returned HTTP \(code)")
        } catch ModerationClassifier.ClassifierError.malformedResponse(let why) {
            return Self.errorResponse(status: .badGateway, code: "classifier_malformed",
                                      message: "local classifier returned malformed response: \(why)")
        } catch ModerationClassifier.ClassifierError.extractedJSONInvalid(let why) {
            return Self.errorResponse(status: .badGateway, code: "classifier_invalid_json",
                                      message: "local classifier JSON invalid: \(why)")
        } catch UpstreamError.responseTooLarge(let maxBytes) {
            return Self.errorResponse(status: .badGateway, code: "upstream_response_too_large",
                                      message: "upstream response exceeded \(maxBytes) byte limit")
        } catch UpstreamError.deadlineExceeded {
            return Self.errorResponse(status: .gatewayTimeout, code: "upstream_timeout",
                                      message: "upstream response timed out")
        } catch {
            return Self.errorResponse(status: .badGateway, code: "classifier_error",
                                      message: "local classifier error: \(error)")
        }
    }

    /// On-device moderation path: classify each input with Apple's Foundation
    /// Models, no network upstream. When the on-device capability is
    /// unavailable (older OS / Apple Intelligence off) we return an explicit
    /// 503 rather than silently proxying — `.onDevice` is a privacy contract.
    ///
    /// NOTE: the on-device verdict is coarse (a single `flagged` + severity
    /// score), so the OpenAI-shaped `categories` / `category_scores` are
    /// reported all-false / all-zero. See `docs/moderation.md`.
    private func handleOnDevice(body: ByteBuffer) async -> Response {
        guard let moderator = onDeviceModerator else {
            return Self.errorResponse(
                status: .serviceUnavailable, code: "on_device_unavailable",
                message: "on-device moderation requires Apple Intelligence (macOS 26 / iOS 26) "
                + "and is not available on this device")
        }
        let inputs = Self.parseInputs(body: body)
        guard !inputs.isEmpty else {
            return Self.errorResponse(status: .badRequest, code: "missing_input",
                                      message: "request must contain `input` (string or array of strings)")
        }
        var results: [ModerationResult] = []
        results.reserveCapacity(inputs.count)
        var model = "apple-foundation-models"
        do {
            for input in inputs {
                let verdict = try await moderator.moderate(input)
                if let verdictModel = verdict.model, !verdictModel.isEmpty {
                    model = verdictModel
                }
                results.append(ModerationResult(
                    flagged: verdict.flagged,
                    categories: ModerationCategories(),
                    categoryScores: ModerationCategoryScores()
                ))
            }
        } catch let error as OnDeviceServiceError {
            return Self.errorResponse(for: error)
        } catch {
            return Self.errorResponse(status: .badGateway, code: "on_device_error",
                                      message: "on-device moderation error: \(error)")
        }
        let response = ModerationResponse(id: "modr-ondevice", model: model, results: results)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(response)
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch {
            return Self.errorResponse(status: .internalServerError, code: "encode_error",
                                      message: "failed to encode moderation response")
        }
    }

    static func errorResponse(for error: OnDeviceServiceError) -> Response {
        switch error {
        case .badRequest(let why):
            return errorResponse(status: .badRequest, code: "invalid_input", message: why)
        case .unauthorized(let why):
            return errorResponse(status: .forbidden, code: "on_device_unauthorized", message: why)
        case .timeout(let why):
            return errorResponse(status: .gatewayTimeout, code: "on_device_timeout", message: why)
        case .unavailable(let why):
            return errorResponse(status: .serviceUnavailable, code: "on_device_unavailable", message: why)
        }
    }

    /// Best-effort extraction of the OpenAI `input` field, which may be a
    /// string or an array of strings.
    public static func parseInputs(body: ByteBuffer) -> [String] {
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return []
        }
        if let single = obj["input"] as? String { return [single] }
        if let array = obj["input"] as? [String] { return array }
        return []
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
