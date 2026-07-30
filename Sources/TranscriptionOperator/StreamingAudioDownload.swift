import Foundation
import NIOCore
import TranscriptionShared

/// Streams a URL's response body to an async consumer as `ByteBuffer` chunks.
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

    func cancel() {
        lock.lock()
        let dataTask = task
        lock.unlock()
        dataTask?.cancel()
    }

    /// Awaits the response head. Throws once the transfer fails before any
    /// response arrives.
    func awaitResponse() async throws -> URLResponse {
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
    }

    /// The body, as a pull-based sequence of chunks.
    var chunks: Chunks { Chunks(download: self) }

    // MARK: - Consumer side

    fileprivate func nextChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !pending.isEmpty {
                let chunk = pending.removeFirst()
                pendingBytes -= chunk.count
                let shouldResume = isSuspended && pendingBytes < highWaterMark
                if shouldResume { isSuspended = false }
                let dataTask = task
                lock.unlock()
                if shouldResume { dataTask?.resume() }
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
            let waiter = takeWaitersAndFail(AudioFetchError.tooLarge)
            lock.unlock()
            dataTask.cancel()
            waiter.0?.resume(throwing: AudioFetchError.tooLarge)
            waiter.1?.resume(throwing: AudioFetchError.tooLarge)
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
        let shouldSuspend = !isSuspended && pendingBytes >= highWaterMark
        if shouldSuspend { isSuspended = true }
        lock.unlock()
        if shouldSuspend { dataTask.suspend() }
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
        typealias Element = ByteBuffer

        let download: StreamingAudioDownload

        struct AsyncIterator: AsyncIteratorProtocol {
            let download: StreamingAudioDownload

            mutating func next() async throws -> ByteBuffer? {
                guard let data = try await download.nextChunk() else { return nil }
                return ByteBuffer(bytes: data)
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(download: download)
        }
    }
}
