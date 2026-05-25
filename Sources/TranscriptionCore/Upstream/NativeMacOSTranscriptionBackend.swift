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
///
/// Cancellation & timeout: the recognition task is retained and canceled when
/// the calling Swift Task is canceled or the timeout elapses. A double-resume
/// guard prevents undefined behavior if the Speech callback fires multiple times.
public struct NativeMacOSTranscriptionBackend: TranscriptionBackendImpl {
    public let locale: Locale
    public let logger: Logger
    public let transcriptionTimeout: Duration

    public init(locale: Locale = .init(identifier: "en-US"),
                logger: Logger = Logger(label: "native-transcriber"),
                transcriptionTimeout: Duration = .seconds(120)) {
        self.locale = locale
        self.logger = logger
        self.transcriptionTimeout = transcriptionTimeout
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
        var buf = part.data
        guard let fileData = buf.readData(length: buf.readableBytes) else {
            throw TranscriptionBackendError.badRequest("failed to read audio data from multipart body")
        }
        try fileData.write(to: tmp)
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

        let text = try await recognizeWithTimeout(recognizer: recognizer, request: request)

        let payload = ["text": text]
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// Runs the speech recognition with cancellation propagation and a timeout.
    /// Uses `withTaskCancellationHandler` + a timer task to enforce the deadline
    /// while keeping non-Sendable types (`SFSpeechRecognizer`, request) on the
    /// calling task's execution context.
    private func recognizeWithTimeout(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> String {
        let state = RecognitionState()
        let timeout = transcriptionTimeout

        // Start a timeout watchdog that will cancel the recognition task.
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            state.cancelWithTimeout()
        }

        defer { timeoutTask.cancel() }

        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                    let task = recognizer.recognitionTask(with: request) { result, error in
                        if let error {
                            guard state.markResumed() else { return }
                            continuation.resume(throwing: error)
                        } else if let result, result.isFinal {
                            guard state.markResumed() else { return }
                            continuation.resume(returning: result.bestTranscription.formattedString)
                        }
                        // Silently ignore non-final, non-error callbacks (unexpected
                        // partial results) without consuming the one-shot resume flag.
                    }
                    state.setTask(task)

                    // If the parent task was already canceled before we started,
                    // cancel the recognition immediately.
                    if Task.isCancelled {
                        task.cancel()
                    }
                }
            } onCancel: {
                state.cancel()
            }

            // If the timeout fired and caused the cancellation, surface that.
            if state.didTimeout {
                throw TranscriptionBackendError.timeout("transcription timed out")
            }
            return result
        } catch {
            if state.didTimeout {
                throw TranscriptionBackendError.timeout("transcription timed out")
            }
            throw error
        }
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

/// Thread-safe state for a single recognition operation. Manages the
/// `SFSpeechRecognitionTask` reference and ensures the continuation is
/// resumed exactly once.
private final class RecognitionState: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _task: SFSpeechRecognitionTask?
    private nonisolated(unsafe) var _resumed = false
    private nonisolated(unsafe) var _didTimeout = false

    /// Whether the timeout watchdog fired before natural completion.
    var didTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _didTimeout
    }

    /// Store the recognition task so it can be canceled from another thread.
    func setTask(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        _task = task
        lock.unlock()
    }

    /// Cancel the recognition task (called from the cancellation handler).
    func cancel() {
        lock.lock()
        let task = _task
        lock.unlock()
        task?.cancel()
    }

    /// Cancel the recognition task due to timeout.
    func cancelWithTimeout() {
        lock.lock()
        _didTimeout = true
        let task = _task
        lock.unlock()
        task?.cancel()
    }

    /// Attempt to mark the continuation as resumed. Returns `true` if this is
    /// the first call (i.e. the caller should resume the continuation).
    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _resumed { return false }
        _resumed = true
        return true
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
    let data: ByteBuffer

    /// Delimiter-correct extraction of the `file` part from a `multipart/form-data`
    /// body. Works directly on `ByteBuffer` without copying the entire body into
    /// `Data` or `[UInt8]`.
    ///
    /// The parser only recognizes boundary delimiters that are preceded by CRLF
    /// (or appear at offset 0), preventing false matches against binary content
    /// that happens to contain boundary-like byte sequences.
    ///
    /// Returns nil if the body isn't multipart, the boundary can't be parsed,
    /// or no part with `name="file"` is present.
    static func extractFile(from buffer: ByteBuffer, contentType: String) -> MultipartFilePart? {
        guard let boundary = MultipartHelpers.parseBoundary(from: contentType),
              !boundary.isEmpty else { return nil }

        let view = buffer.readableBytesView
        guard !view.isEmpty else { return nil }

        let delimiter: [UInt8] = Array("--\(boundary)".utf8)
        let crlf: [UInt8] = [0x0D, 0x0A]
        let headerSep: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

        // Locate all boundary positions that are correctly framed:
        // either at the very start of the body or preceded by CRLF.
        let positions = Self.findDelimiters(in: view, delimiter: delimiter, crlf: crlf)
        guard positions.count >= 2 else { return nil }

        // Each part sits between consecutive delimiter positions.
        // The content starts after the delimiter line (delimiter + CRLF or delimiter + "--").
        for i in 0..<(positions.count - 1) {
            let delimStart = positions[i]
            let nextDelimStart = positions[i + 1]

            // Skip past delimiter bytes.
            var contentStart = delimStart + delimiter.count
            // Check for closing marker `--` — skip this "part".
            if contentStart + 1 < view.endIndex,
               view[contentStart] == 0x2D, view[contentStart + 1] == 0x2D {
                continue
            }
            // Skip the CRLF after the delimiter line.
            if contentStart + 1 < view.endIndex,
               view[contentStart] == 0x0D, view[contentStart + 1] == 0x0A {
                contentStart += 2
            }

            // The part content ends where the next delimiter's preceding CRLF begins.
            var contentEnd = nextDelimStart
            // Strip the CRLF that precedes the next boundary marker.
            if contentEnd >= 2,
               view[contentEnd - 2] == 0x0D, view[contentEnd - 1] == 0x0A {
                contentEnd -= 2
            }

            guard contentStart < contentEnd else { continue }

            // Find header/body separator (CRLFCRLF).
            guard let sepOffset = Self.findSequence(headerSep, in: view, from: contentStart, to: contentEnd) else {
                continue
            }
            let headersEnd = sepOffset
            let bodyStart = sepOffset + headerSep.count

            // Parse headers (they're always ASCII/UTF-8).
            let headersSlice = view[contentStart..<headersEnd]
            guard let headers = String(bytes: headersSlice, encoding: .utf8) else { continue }
            guard Self.hasExactNameParameter(headers, name: "file") else { continue }

            let filename = Self.matchHeader(headers, key: "filename")
            let mimeType = Self.matchHeader(headers, key: "Content-Type", isCT: true)

            // Return a zero-copy slice of the buffer for the body.
            let bodyLength = contentEnd - bodyStart
            let sliceStart = bodyStart - view.startIndex + buffer.readerIndex
            guard let bodyBuffer = buffer.getSlice(at: sliceStart, length: bodyLength) else {
                continue
            }
            return MultipartFilePart(filename: filename, mimeType: mimeType, data: bodyBuffer)
        }
        return nil
    }

    /// Find all positions in `view` where `delimiter` appears, only accepting
    /// matches that are at position 0 or preceded by `crlf`, AND followed by
    /// CRLF or `--` (per RFC 2046 boundary line framing).
    private static func findDelimiters(
        in view: ByteBufferView,
        delimiter: [UInt8],
        crlf: [UInt8]
    ) -> [ByteBufferView.Index] {
        var positions: [ByteBufferView.Index] = []
        var searchFrom = view.startIndex

        while searchFrom <= view.endIndex - delimiter.count {
            guard let pos = Self.findSequence(delimiter, in: view, from: searchFrom, to: view.endIndex) else {
                break
            }

            let isFramed: Bool
            if pos == view.startIndex {
                isFramed = true
            } else if pos >= view.startIndex + crlf.count {
                isFramed = view[pos - 2] == crlf[0] && view[pos - 1] == crlf[1]
            } else {
                isFramed = false
            }

            // Also verify post-boundary terminator: must be CRLF or "--".
            let afterDelim = pos + delimiter.count
            let hasValidSuffix: Bool
            if afterDelim + 1 < view.endIndex {
                let b0 = view[afterDelim]
                let b1 = view[afterDelim + 1]
                hasValidSuffix = (b0 == 0x0D && b1 == 0x0A) || (b0 == 0x2D && b1 == 0x2D)
            } else if afterDelim == view.endIndex {
                // Boundary at very end of body (no trailing bytes) — valid closing.
                hasValidSuffix = true
            } else {
                hasValidSuffix = false
            }

            if isFramed && hasValidSuffix {
                positions.append(pos)
            }
            searchFrom = pos + 1
        }
        return positions
    }

    /// Locate the first occurrence of `needle` in `view[from..<to]`.
    private static func findSequence(
        _ needle: [UInt8],
        in view: ByteBufferView,
        from start: ByteBufferView.Index,
        to end: ByteBufferView.Index
    ) -> ByteBufferView.Index? {
        guard needle.count > 0, end - start >= needle.count else { return nil }
        let limit = end - needle.count
        var i = start
        while i <= limit {
            var matched = true
            for j in 0..<needle.count {
                if view[i + j] != needle[j] {
                    matched = false
                    break
                }
            }
            if matched { return i }
            i += 1
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
        let needle = "\(key)=\""
        guard let r = headers.range(of: needle) else { return nil }
        let rest = headers[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Check if the Content-Disposition header contains an exact `name="<name>"` parameter.
    /// Prevents false positives like matching `name="file2"` when looking for `name="file"`.
    private static func hasExactNameParameter(_ headers: String, name: String) -> Bool {
        let needle = "name=\"\(name)\""
        var searchStart = headers.startIndex
        while let range = headers.range(of: needle, range: searchStart..<headers.endIndex) {
            // Verify the character after the closing quote isn't alphanumeric (no "file2" match).
            let afterEnd = range.upperBound
            if afterEnd == headers.endIndex || !headers[afterEnd].isLetter && !headers[afterEnd].isNumber {
                return true
            }
            searchStart = range.upperBound
        }
        return false
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
