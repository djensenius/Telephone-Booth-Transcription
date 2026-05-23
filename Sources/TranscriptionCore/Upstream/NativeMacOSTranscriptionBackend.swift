#if canImport(Speech) && os(macOS)
import AVFoundation
import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import Speech

/// Transcription backend that uses macOS's `Speech` framework for on-device
/// transcription. Requires `NSSpeechRecognitionUsageDescription` in Info.plist
/// and user approval at first use.
///
/// The implementation:
/// 1. Parses the multipart body to extract the `file` field's bytes + MIME type.
/// 2. Writes them to a temporary file with a sensible extension so AVFoundation
///    can open it.
/// 3. Asks `SFSpeechRecognizer` for an on-device, final transcription.
/// 4. Returns `{"text": "..."}` — the OpenAI default `response_format: json`
///    response shape.
public struct NativeMacOSTranscriptionBackend: TranscriptionBackendImpl {
    public let locale: Locale
    public let logger: Logger

    public init(locale: Locale = .init(identifier: "en-US"),
                logger: Logger = Logger(label: "native-transcriber")) {
        self.locale = locale
        self.logger = logger
    }

    public func handle(body: ByteBuffer, contentType: String) async throws -> Response {
        guard let part = MultipartFilePart.extractFile(from: body, contentType: contentType) else {
            throw TranscriptionBackendError.badRequest("multipart body did not include a `file` field")
        }

        // Wait for user authorization.
        let authStatus = await Self.requestAuthorization()
        switch authStatus {
        case .authorized:
            break
        case .denied:
            throw TranscriptionBackendError.unauthorized("speech recognition denied by user")
        case .restricted:
            throw TranscriptionBackendError.unauthorized("speech recognition restricted on this device")
        case .notDetermined:
            throw TranscriptionBackendError.unauthorized("speech recognition authorization not determined")
        @unknown default:
            throw TranscriptionBackendError.unauthorized("speech recognition not authorized")
        }

        // Persist to a temp file with the right extension so AVFoundation can decode.
        let ext = AudioExtension.from(mimeType: part.mimeType) ?? "wav"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-\(UUID().uuidString).\(ext)")
        try part.data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionBackendError.badRequest("unsupported locale: \(locale.identifier)")
        }
        guard recognizer.isAvailable else {
            throw TranscriptionBackendError.unauthorized("speech recognizer not currently available")
        }
        recognizer.defaultTaskHint = .dictation

        let request = SFSpeechURLRecognitionRequest(url: tmp)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }

        let payload = ["text": text]
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

enum AudioExtension {
    static func from(mimeType: String?) -> String? {
        guard let m = mimeType?.lowercased() else { return nil }
        switch m {
        case "audio/wav", "audio/wave", "audio/x-wav":           return "wav"
        case "audio/mpeg", "audio/mp3":                          return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a":            return "m4a"
        case "audio/aac":                                        return "aac"
        case "audio/ogg", "audio/opus":                          return "ogg"
        case "audio/flac", "audio/x-flac":                       return "flac"
        case "audio/webm":                                       return "webm"
        default:                                                 return nil
        }
    }
}

/// Result of extracting the `file` field from a multipart body.
struct MultipartFilePart {
    let filename: String?
    let mimeType: String?
    let data: Data

    /// Best-effort extraction of the `file` part from a `multipart/form-data`
    /// body. Returns nil if the body isn't multipart, the boundary can't be
    /// parsed, or no part with `name="file"` is present.
    static func extractFile(from buffer: ByteBuffer, contentType: String) -> MultipartFilePart? {
        guard let boundary = MultipartHelpers.parseBoundary(from: contentType) else { return nil }
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        let data = Data(bytes)
        let boundaryBytes = "--\(boundary)".data(using: .ascii)!
        let crlf = Data([0x0D, 0x0A])

        // Split on the boundary. Each section starts with CRLF and is terminated
        // by CRLF before the next boundary marker.
        var parts: [Data] = []
        var searchStart = data.startIndex
        var sectionStart: Data.Index?
        while let range = data.range(of: boundaryBytes, in: searchStart..<data.endIndex) {
            if let start = sectionStart {
                parts.append(data.subdata(in: start..<range.lowerBound))
            }
            sectionStart = range.upperBound
            searchStart = range.upperBound
        }

        for raw in parts {
            // Strip leading CRLF after the boundary marker.
            var part = raw
            if part.starts(with: crlf) {
                part = part.subdata(in: part.index(part.startIndex, offsetBy: 2)..<part.endIndex)
            }
            // Header/body split on CRLFCRLF.
            let headerSep = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let sep = part.range(of: headerSep) else { continue }
            let headersData = part.subdata(in: part.startIndex..<sep.lowerBound)
            var bodyData = part.subdata(in: sep.upperBound..<part.endIndex)
            // Strip trailing CRLF that precedes the next boundary.
            if bodyData.count >= 2,
               bodyData[bodyData.endIndex - 2] == 0x0D,
               bodyData[bodyData.endIndex - 1] == 0x0A {
                bodyData = bodyData.subdata(in: bodyData.startIndex..<(bodyData.endIndex - 2))
            }
            guard let headers = String(data: headersData, encoding: .utf8) else { continue }
            if !headers.contains("name=\"file\"") { continue }
            let filename = Self.matchHeader(headers, key: "filename")
            let mimeType = Self.matchHeader(headers, key: "Content-Type", isCT: true)
            return MultipartFilePart(filename: filename, mimeType: mimeType, data: bodyData)
        }
        return nil
    }

    private static func matchHeader(_ headers: String, key: String, isCT: Bool = false) -> String? {
        if isCT {
            for line in headers.split(separator: "\r\n") {
                let l = String(line).trimmingCharacters(in: .whitespaces)
                if l.lowercased().hasPrefix("content-type:") {
                    return l.dropFirst("Content-Type:".count).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        // Find `key="value"` in the headers blob.
        let needle = "\(key)=\""
        guard let r = headers.range(of: needle) else { return nil }
        let rest = headers[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

#else
// Non-macOS stub: native transcription is unavailable.
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

public struct NativeMacOSTranscriptionBackend: TranscriptionBackendImpl {
    public init() {}
    public func handle(body: ByteBuffer, contentType: String) async throws -> Response {
        throw TranscriptionBackendError.badRequest("native macOS transcription is only available on macOS")
    }
}
#endif
