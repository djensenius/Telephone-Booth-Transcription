import AsyncHTTPClient
import Foundation
import Logging
import NIOCore

/// Default `OperatorJobDispatcher` that executes jobs by hitting this
/// app's own HTTP server over loopback. Reuses all routing, middleware,
/// backend selection, and request logging — the worker just shapes the
/// request/response pair to/from the Operator's job protocol.
public final class LoopbackOperatorJobDispatcher: OperatorJobDispatcher {
    private let httpClient: HTTPClient
    private let bindHost: String
    private let bindPort: Int
    private let bearerToken: String
    private let timeout: TimeAmount
    private let logger: Logger
    private let maxAudioBytes: Int

    public init(
        httpClient: HTTPClient,
        bindHost: String,
        bindPort: Int,
        bearerToken: String,
        timeout: TimeAmount = .seconds(120),
        maxAudioBytes: Int = 100 * 1024 * 1024,
        logger: Logger = Logger(label: "operator-dispatcher")
    ) {
        self.httpClient = httpClient
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.bearerToken = bearerToken
        self.timeout = timeout
        self.maxAudioBytes = maxAudioBytes
        self.logger = logger
    }

    public func execute(job: OperatorJob) async throws -> OperatorJobResult {
        switch job.payload {
        case .transcription(let payload):
            return try await runAudio(payload: payload, isTranslation: false)
        case .translation(let payload):
            // The Operator already has the transcript when it enqueues a
            // translation job, so dispatch goes through the text route.
            return try await runTextTranslation(payload: payload)
        case .moderation(let payload):
            return try await runModeration(payload: payload)
        }
    }

    // MARK: - Audio (transcription)

    private func runAudio(payload: OperatorJob.TranscriptionPayload, isTranslation: Bool) async throws -> OperatorJobResult {
        let audio = try await downloadAudio(url: payload.audioURL)
        let boundary = "----TBT\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        let (filename, contentType) = audioFileMetadata(for: payload)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)
        if let model = payload.model, !model.isEmpty {
            body.append(multipartField(boundary: boundary, name: "model", value: model))
        }
        body.append(multipartField(boundary: boundary, name: "response_format", value: "verbose_json"))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let path = isTranslation ? "/v1/audio/translations" : "/v1/audio/transcriptions"
        let response = try await postLoopback(
            path: path,
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: body
        )
        guard (200..<300).contains(response.status) else {
            throw mapHTTPFailure(
                kind: isTranslation ? "translation" : "transcription",
                status: response.status,
                body: response.body
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw OperatorJobError(code: isTranslation ? "translation_malformed" : "transcription_malformed",
                                   message: "non-JSON response from local server")
        }
        let text = (json["text"] as? String) ?? ""
        let language = json["language"] as? String
        let model = json["model"] as? String
        return isTranslation
            ? .translation(translatedText: text, sourceLanguage: language, targetLanguage: "en", model: model)
            : .transcription(text: text, language: language, model: model)
    }

    // MARK: - Text translation

    private func runTextTranslation(payload: OperatorJob.TranslationPayload) async throws -> OperatorJobResult {
        var obj: [String: Any] = ["input": payload.input]
        if let src = payload.sourceLanguage { obj["source_language"] = src }
        let bodyData = try JSONSerialization.data(withJSONObject: obj)
        let response = try await postLoopback(
            path: "/v1/translations",
            contentType: "application/json",
            body: bodyData
        )
        guard (200..<300).contains(response.status) else {
            throw mapHTTPFailure(kind: "translation", status: response.status, body: response.body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let translated = json["translated_text"] as? String else {
            throw OperatorJobError(code: "translation_malformed",
                                   message: "missing translated_text in local response")
        }
        return .translation(
            translatedText: translated,
            sourceLanguage: (json["source_language"] as? String) ?? payload.sourceLanguage,
            targetLanguage: (json["target_language"] as? String) ?? "en",
            model: json["model"] as? String
        )
    }

    // MARK: - Moderation

    private func runModeration(payload: OperatorJob.ModerationPayload) async throws -> OperatorJobResult {
        let obj: [String: Any] = ["input": payload.input]
        let bodyData = try JSONSerialization.data(withJSONObject: obj)
        let response = try await postLoopback(
            path: "/v1/moderations",
            contentType: "application/json",
            body: bodyData
        )
        guard (200..<300).contains(response.status) else {
            throw mapHTTPFailure(kind: "moderation", status: response.status, body: response.body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let results = json["results"] as? [[String: Any]], let first = results.first else {
            throw OperatorJobError(code: "moderation_malformed",
                                   message: "missing results in local response")
        }
        let flagged = (first["flagged"] as? Bool) ?? false
        let scores = (first["category_scores"] as? [String: Any]) ?? [:]
        let maxScore = scores.values.compactMap { ($0 as? Double) ?? (($0 as? NSNumber)?.doubleValue) }.max() ?? 0
        let recommendation: String
        if flagged {
            recommendation = "reject"
        } else if maxScore > 0.5 {
            recommendation = "review"
        } else {
            recommendation = "approve"
        }
        return .moderation(flagged: flagged, recommendation: recommendation,
                           maxScore: maxScore, model: json["model"] as? String)
    }

    // MARK: - Helpers

    private struct LoopbackResponse: Sendable {
        let status: Int
        let body: Data
    }

    private func postLoopback(path: String, contentType: String, body: Data) async throws -> LoopbackResponse {
        // Loopback URL: use bindHost / bindPort, but fall back to 127.0.0.1
        // when host is `0.0.0.0`. Connecting to `0.0.0.0` is allowed on some
        // platforms but undefined on others.
        let host = (bindHost == "0.0.0.0" || bindHost == "::") ? "127.0.0.1" : bindHost
        let url = "http://\(host):\(bindPort)\(path)"
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: contentType)
        request.headers.add(name: "Authorization", value: "Bearer \(bearerToken)")
        request.body = .bytes(ByteBuffer(bytes: body))
        let deadline = NIODeadline.now() + .nanoseconds(timeout.asNanoseconds)
        let response = try await httpClient.execute(request, deadline: deadline)
        let buffer = try await response.body.collect(upTo: 32 * 1024 * 1024)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        return .init(status: Int(response.status.code), body: Data(bytes))
    }

    private func downloadAudio(url: String) async throws -> Data {
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        let deadline = NIODeadline.now() + .nanoseconds(timeout.asNanoseconds)
        let response: HTTPClientResponse
        do {
            response = try await httpClient.execute(request, deadline: deadline)
        } catch {
            throw OperatorJobError(code: "audio_fetch_failed",
                                   message: "transport error: \(type(of: error))")
        }
        guard (200..<300).contains(Int(response.status.code)) else {
            throw OperatorJobError(code: "audio_fetch_failed",
                                   message: "HTTP \(response.status.code) from audio URL")
        }
        let buffer: ByteBuffer
        do {
            buffer = try await response.body.collect(upTo: maxAudioBytes)
        } catch is NIOTooManyBytesError {
            throw OperatorJobError(code: "audio_too_large",
                                   message: "audio exceeded \(maxAudioBytes) bytes")
        }
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        return Data(bytes)
    }

    private func mapHTTPFailure(kind: String, status: Int, body: Data) -> OperatorJobError {
        // Try to extract a structured error code from our own server's
        // JSON envelope — but never include free-form upstream text.
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let code = err["code"] as? String {
            return OperatorJobError(code: code, message: "local \(kind) returned HTTP \(status)")
        }
        return OperatorJobError(code: "\(kind)_http_\(status)",
                                message: "local \(kind) returned HTTP \(status)")
    }

    /// Returns `(filename, contentType)` for the multipart audio part.
    /// Order of precedence:
    /// 1. Explicit `payload.filename` / `payload.contentType` from the
    ///    Operator (best signal — the Operator stored the file).
    /// 2. The file extension parsed from `payload.audioURL`, mapped to a
    ///    well-known MIME type.
    /// 3. Default: `<sha256>.flac` + `audio/flac`.
    private func audioFileMetadata(for payload: OperatorJob.TranscriptionPayload) -> (String, String) {
        let ext = (URL(string: payload.audioURL)?.pathExtension ?? "").lowercased()

        let derivedContentType: String? = {
            switch ext {
            case "flac": return "audio/flac"
            case "mp3":  return "audio/mpeg"
            case "wav":  return "audio/wav"
            case "m4a":  return "audio/mp4"
            case "mp4":  return "audio/mp4"
            case "ogg":  return "audio/ogg"
            case "opus": return "audio/opus"
            case "webm": return "audio/webm"
            case "aac":  return "audio/aac"
            default:     return nil
            }
        }()

        let contentType = payload.contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? derivedContentType ?? "audio/flac"
        let resolvedExt = ext.isEmpty ? "flac" : ext
        let filename = payload.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "\(payload.sha256).\(resolvedExt)"
        return (filename, contentType)
    }

    private func multipartField(boundary: String, name: String, value: String) -> Data {
        var part = Data()
        part.append("--\(boundary)\r\n".data(using: .utf8)!)
        part.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        part.append(value.data(using: .utf8)!)
        part.append("\r\n".data(using: .utf8)!)
        return part
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}