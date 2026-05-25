import Foundation
import Testing
@testable import TranscriptionCore

@Suite("RequestLogWriter")
struct RequestLogWriterTests {

    private func makeEntry(path: String = "/test", index: Int = 0) -> RequestLogEntry {
        RequestLogEntry(
            receivedAt: Date().addingTimeInterval(Double(index)),
            method: "GET",
            path: path,
            status: 200,
            durationMs: index
        )
    }

    @Test func preservesInsertionOrder() async throws {
        let store = InMemoryRequestLogStore()
        let writer = RequestLogWriter(store: store, bufferCapacity: 64)

        for i in 0..<10 {
            await writer.enqueue(makeEntry(path: "/req-\(i)", index: i))
        }
        await writer.shutdown()
        await writer.run()

        let entries = try await store.recent(limit: 100)
        #expect(entries.count == 10)
        // recent() returns descending by receivedAt; first inserted has lowest time
        let paths = entries.reversed().map(\.path)
        for i in 0..<10 {
            #expect(paths[i] == "/req-\(i)")
        }
    }

    @Test func dropsEntriesWhenBufferFull() async throws {
        let store = InMemoryRequestLogStore()
        let writer = RequestLogWriter(store: store, bufferCapacity: 4)

        for i in 0..<10 {
            await writer.enqueue(makeEntry(index: i))
        }
        await writer.shutdown()
        await writer.run()

        let count = try await store.count()
        #expect(count == 4)
        let dropped = await writer.droppedCount
        #expect(dropped == 6)
    }

    @Test func shutdownDrainsRemainingEntries() async throws {
        let store = InMemoryRequestLogStore()
        let writer = RequestLogWriter(store: store, bufferCapacity: 64)

        for i in 0..<5 {
            await writer.enqueue(makeEntry(index: i))
        }

        // Shutdown before run — run should still drain buffered entries
        await writer.shutdown()
        await writer.run()

        let count = try await store.count()
        #expect(count == 5)
    }

    @Test func countsFailedWrites() async throws {
        let store = ThrowingRequestLogStore()
        let writer = RequestLogWriter(store: store, bufferCapacity: 64)

        for i in 0..<3 {
            await writer.enqueue(makeEntry(index: i))
        }
        await writer.shutdown()
        await writer.run()

        let failed = await writer.failedCount
        #expect(failed == 3)
    }

    @Test func rejectsEntriesAfterShutdown() async throws {
        let store = InMemoryRequestLogStore()
        let writer = RequestLogWriter(store: store, bufferCapacity: 64)

        await writer.shutdown()
        await writer.enqueue(makeEntry())
        await writer.run()

        let count = try await store.count()
        #expect(count == 0)
        let dropped = await writer.droppedCount
        #expect(dropped == 1)
    }
}

/// A store that always throws, for testing failure counting.
private actor ThrowingRequestLogStore: RequestLogStoring {
    struct FakeError: Error {}

    func record(_ entry: RequestLogEntry) async throws {
        throw FakeError()
    }

    func recent(limit: Int) async throws -> [RequestLogEntry] { [] }
    func count() async throws -> Int { 0 }
    func purge() async throws {}
}
