import Foundation
import TranscriptionShared

/// Streams a URL's response body to an async consumer as `Data` chunks.
///
/// Exists because `URLSession.AsyncBytes` yields a single `UInt8` per awaited
/// `next()`: at the 100 MB audio cap that is on the order of 100M async
/// iterator calls for one download. `URLSession`'s delegate callbacks deliver
/// OS-sized `Data` chunks instead, so the cost scales with chunks rather than
/// bytes.
///
/// It keeps the two properties the byte-at-a-time path had:
///
/// - **Back-pressure.** Chunks are handed over one at a time and the transfer
///   is `suspend()`ed once more than `highWaterMark` bytes are waiting, so a
///   fast connection can't race ahead of the consumer's disk writes and balloon
///   in memory.
/// - **A hard byte cap.** The delegate counts bytes as they arrive and cancels
///   the transfer the moment it passes `maxBytes`, so a response with a missing
///   or understated `Content-Length` can't download far past the cap before
///   staging notices.
///
/// **Privacy:** nothing here logs, and the only error it produces is the
/// content-free `AudioFetchError`.
final class StreamingAudioDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Bytes allowed to sit unread before the transfer is suspended. Large
    /// enough that a healthy transfer never stalls, small enough to bound the
    /// memory a stalled consumer can cause.
    static let defaultHighWaterMark = 1 << 20

    private let maxBytes: Int
    private let highWaterMark: Int

    private let lock = NSLock()
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var receivedBytes = 0
    private var isFinished = false
    private var failure: (any Error)?
    private var isSuspended = false
    private var task: URLSessionTask?
    private var chunkWaiter: CheckedContinuation<Data?, any Error>?
    private var responseWaiter: CheckedContinuation<URLResponse, any Error>?
    private var response: URLResponse?

    init(maxBytes: Int, highWaterMark: Int = StreamingAudioDownload.defaultHighWaterMark) {
        self.maxBytes = maxBytes
        self.highWaterMark = highWaterMark
    }

    // MARK: - Driving the transfer

    /// Starts `request` on `session` with this object as the task's delegate.
    /// The caller must `cancel()` when it stops consuming, so an abandoned
    /// transfer doesn't keep downloading.
    func start(_ request: URLRequest, on session: URLSession) {
        let dataTask = session.dataTask(with: request)
        dataTask.delegate = self
        lock.lock()
        task = dataTask
        lock.unlock()
        dataTask.resume()
    }

    /// Stops the transfer and fails any parked waiter. Safe to call more than
    /// once, and after the transfer has already finished.
    func cancel() {
        fail(with: CancellationError(), cancelTask: true)
    }

    /// Awaits the response head. Throws once the transfer fails before any
    /// response arrives.
    ///
    /// Cancelling the calling task cancels the transfer, so an abandoned
    /// download doesn't keep the caller parked for the request timeout.
    func awaitResponse() async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let response {
                    lock.unlock()
                    continuation.resume(returning: response)
                    return
                }
                if let failure {
                    lock.unlock()
                    continuation.resume(throwing: failure)
                    return
                }
                if isFinished {
                    lock.unlock()
                    continuation.resume(throwing: AudioFetchError.fetchFailed)
                    return
                }
                responseWaiter = continuation
                lock.unlock()
            }
        } onCancel: {
            cancel()
        }
    }

    /// The body, as a pull-based sequence of chunks.
    var chunks: Chunks { Chunks(download: self) }

    // MARK: - Consumer side

    fileprivate func nextChunk() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !pending.isEmpty {
                    let chunk = pending.removeFirst()
                    pendingBytes -= chunk.count
                    // Resumed under the lock so the flag and the task's actual
                    // state can never disagree.
                    if isSuspended, pendingBytes < highWaterMark {
                        isSuspended = false
                        task?.resume()
                    }
                    lock.unlock()
                    continuation.resume(returning: chunk)
                    return
                }
                if let failure {
                    lock.unlock()
                    continuation.resume(throwing: failure)
                    return
                }
                if isFinished {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                chunkWaiter = continuation
                lock.unlock()
            }
        } onCancel: {
            cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response
        let waiter = responseWaiter
        responseWaiter = nil
        lock.unlock()
        waiter?.resume(returning: response)

        // An advertised body larger than the cap is refused before a single
        // byte of it is delivered; the caller still sees the response head and
        // reports the same `tooLarge` failure staging would.
        let advertised = response.expectedContentLength
        guard advertised == NSURLSessionTransferSizeUnknown || advertised <= Int64(maxBytes) else {
            completionHandler(.cancel)
            fail(with: AudioFetchError.tooLarge, cancelTask: false)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !isFinished, failure == nil else {
            lock.unlock()
            return
        }
        receivedBytes += data.count
        // Enforced here as well as in staging so an understated Content-Length
        // can't stream far past the cap before the consumer notices.
        guard receivedBytes <= maxBytes else {
            lock.unlock()
            fail(with: AudioFetchError.tooLarge, cancelTask: true)
            return
        }
        if let waiter = chunkWaiter {
            chunkWaiter = nil
            lock.unlock()
            waiter.resume(returning: data)
            return
        }
        pending.append(data)
        pendingBytes += data.count
        // Suspended under the lock so a consumer draining concurrently can't
        // observe `isSuspended` before the task has actually been suspended.
        if !isSuspended, pendingBytes >= highWaterMark {
            isSuspended = true
            dataTask.suspend()
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        guard !isFinished, failure == nil else {
            lock.unlock()
            return
        }
        let waiters: (CheckedContinuation<Data?, any Error>?, CheckedContinuation<URLResponse, any Error>?)
        if let error {
            waiters = takeWaitersAndFail(Self.map(error))
        } else {
            isFinished = true
            waiters = (chunkWaiter, responseWaiter)
            chunkWaiter = nil
            responseWaiter = nil
        }
        let hasPending = !pending.isEmpty
        lock.unlock()

        if let error {
            waiters.0?.resume(throwing: Self.map(error))
            waiters.1?.resume(throwing: Self.map(error))
        } else {
            // A waiter only exists when nothing was buffered, so completing
            // cleanly ends the sequence.
            if !hasPending { waiters.0?.resume(returning: nil) }
            waiters.1?.resume(throwing: AudioFetchError.fetchFailed)
        }
    }

    /// Records `error` once, discards buffered chunks so a partial body can't
    /// be consumed, optionally cancels the transfer, and resumes any parked
    /// waiter. A no-op once the transfer has already failed or finished, so
    /// every waiter is resumed exactly once.
    private func fail(with error: any Error, cancelTask: Bool) {
        lock.lock()
        guard !isFinished, failure == nil else {
            let dataTask = task
            lock.unlock()
            if cancelTask { dataTask?.cancel() }
            return
        }
        let waiters = takeWaitersAndFail(error)
        let dataTask = task
        lock.unlock()
        if cancelTask { dataTask?.cancel() }
        waiters.0?.resume(throwing: error)
        waiters.1?.resume(throwing: error)
    }

    /// Records `error`, discards buffered chunks so a partial body can't be
    /// consumed, and returns the waiters to resume **after** the lock is
    /// released. Must be called with the lock held.
    private func takeWaitersAndFail(
        _ error: any Error
    ) -> (CheckedContinuation<Data?, any Error>?, CheckedContinuation<URLResponse, any Error>?) {
        failure = error
        pending.removeAll()
        pendingBytes = 0
        let waiters = (chunkWaiter, responseWaiter)
        chunkWaiter = nil
        responseWaiter = nil
        return waiters
    }

    /// URLSession errors are mapped to the content-free fetch error; a
    /// cancellation triggered by the cap keeps its own meaning via `failure`.
    private static func map(_ error: any Error) -> AudioFetchError {
        AudioFetchError.fetchFailed
    }

    /// Pull-based view of the body. Nothing is read from the network buffer
    /// until the consumer asks for the next chunk.
    struct Chunks: AsyncSequence, Sendable {
        typealias Element = Data

        let download: StreamingAudioDownload

        struct AsyncIterator: AsyncIteratorProtocol {
            let download: StreamingAudioDownload

            mutating func next() async throws -> Data? {
                try await download.nextChunk()
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(download: download)
        }
    }
}
