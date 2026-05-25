import Foundation
import Logging

/// A bounded, ordered logging pipeline that replaces unbounded detached tasks.
///
/// Entries are enqueued without blocking the caller. A single `run()` loop
/// writes them sequentially to the underlying store, preserving insertion order
/// and bounding concurrent DB access to one write at a time. On shutdown the
/// remaining buffer is drained before `run()` returns.
public actor RequestLogWriter {
    private let store: any RequestLogStoring
    private let logger: Logger
    private let bufferCapacity: Int

    private var buffer: [RequestLogEntry] = []
    private var continuation: AsyncStream<Void>.Continuation?
    private var stream: AsyncStream<Void>?
    private var finished = false

    public private(set) var droppedCount: Int = 0
    public private(set) var failedCount: Int = 0

    public init(
        store: any RequestLogStoring,
        bufferCapacity: Int = 256,
        logger: Logger = Logger(label: "request-log-writer")
    ) {
        self.store = store
        self.bufferCapacity = bufferCapacity
        self.logger = logger

        var cont: AsyncStream<Void>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// Enqueue a log entry. Non-blocking; drops the entry if the buffer is full.
    public func enqueue(_ entry: RequestLogEntry) {
        guard !finished else {
            droppedCount += 1
            return
        }
        if buffer.count >= bufferCapacity {
            droppedCount += 1
            logger.warning("request log buffer full, dropping entry")
            return
        }
        buffer.append(entry)
        continuation?.yield()
    }

    /// Run the write loop. Call this in a task group or background task.
    /// Returns after `shutdown()` is called and all buffered entries are drained.
    public func run() async {
        guard let stream = self.stream else { return }
        for await _ in stream {
            await drainBuffer()
        }
        // Final drain after stream finishes
        await drainBuffer()
    }

    /// Signal the writer to stop accepting new entries and drain remaining buffer.
    public func shutdown() {
        finished = true
        continuation?.finish()
        continuation = nil
    }

    private func drainBuffer() async {
        while !buffer.isEmpty {
            let entry = buffer.removeFirst()
            do {
                try await store.record(entry)
            } catch {
                failedCount += 1
                logger.error("failed to record request log: \(error)")
            }
        }
    }
}
