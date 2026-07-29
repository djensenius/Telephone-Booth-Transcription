#if canImport(Speech)
import AVFoundation
import Foundation
import Logging
import Speech
import TranscriptionShared

/// On-device `AudioTranscriber` backed by the legacy `SFSpeechRecognizer`.
/// Widely supported (50+ locales, no separate asset download) but lower
/// accuracy than `SpeechAnalyzerTranscriber`. Requires the speech-recognition
/// usage description in Info.plist and user approval at first use.
///
/// Cancellation & timeout: the recognition task is retained and canceled when
/// the calling Swift Task is canceled or the timeout elapses. A double-resume
/// guard prevents undefined behavior if the Speech callback fires multiple times.
public struct NativeSpeechTranscriber: AudioTranscriber {
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

    public func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        // Wait for user authorization.
        let authStatus = await Self.requestAuthorization()
        switch authStatus {
        case .authorized:
            break
        case .denied:
            throw OnDeviceServiceError.unauthorized("speech recognition denied by user")
        case .restricted:
            throw OnDeviceServiceError.unauthorized("speech recognition restricted on this device")
        case .notDetermined:
            throw OnDeviceServiceError.unauthorized("speech recognition authorization not determined")
        @unknown default:
            throw OnDeviceServiceError.unauthorized("speech recognition not authorized")
        }

        let effectiveLocale = language.map(Locale.init(identifier:)) ?? locale
        guard let recognizer = SFSpeechRecognizer(locale: effectiveLocale) else {
            throw OnDeviceServiceError.badRequest("unsupported locale: \(effectiveLocale.identifier)")
        }
        guard recognizer.isAvailable else {
            throw OnDeviceServiceError.unavailable("speech recognizer not currently available")
        }
        recognizer.defaultTaskHint = .dictation

        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.shouldReportPartialResults = false
        // Fail closed. `SFSpeechRecognizer` silently falls back to Apple's
        // servers when on-device recognition isn't supported for the locale or
        // device, which would send the audio off-machine — unacceptable for a
        // backend that reports `isOnDevice == true` and drives the "no request
        // leaves this machine" indicator. Refuse instead, so the operator can
        // pick Speech Analyzer or a locale with on-device assets.
        guard recognizer.supportsOnDeviceRecognition else {
            throw OnDeviceServiceError.unavailable(
                """
                on-device speech recognition is unavailable for \
                \(effectiveLocale.identifier); refusing to fall back to \
                Apple's servers
                """
            )
        }
        request.requiresOnDeviceRecognition = true

        return try await recognizeWithTimeout(recognizer: recognizer, request: request)
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
                throw OnDeviceServiceError.timeout("transcription timed out")
            }
            return result
        } catch {
            if state.didTimeout {
                throw OnDeviceServiceError.timeout("transcription timed out")
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
#endif
