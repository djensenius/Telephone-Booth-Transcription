import Foundation
import Testing
@testable import TranscriptionCore

@Suite("RequestLogStore (in-memory)")
struct RequestLogStoreTests {
    @Test func recordsAndReturnsEntries() async throws {
        let store = InMemoryRequestLogStore()
        let now = Date()
        try await store.record(.init(
            receivedAt: now,
            method: "POST",
            path: "/v1/audio/transcriptions",
            status: 200,
            durationMs: 120
        ))
        try await store.record(.init(
            receivedAt: now.addingTimeInterval(1),
            method: "POST",
            path: "/v1/moderations",
            status: 200,
            durationMs: 30,
            moderationFlagged: false
        ))
        let entries = try await store.recent(limit: 10)
        #expect(entries.count == 2)
        // Sorted desc by receivedAt
        #expect(entries[0].path == "/v1/moderations")
        #expect(entries[1].path == "/v1/audio/transcriptions")
    }

    @Test func countTracksInserts() async throws {
        let store = InMemoryRequestLogStore()
        #expect(try await store.count() == 0)
        try await store.record(.init(receivedAt: Date(), method: "GET", path: "/healthz", status: 200, durationMs: 1))
        #expect(try await store.count() == 1)
    }

    @Test func purgeEmptiesStore() async throws {
        let store = InMemoryRequestLogStore()
        try await store.record(.init(receivedAt: Date(), method: "GET", path: "/x", status: 200, durationMs: 1))
        try await store.purge()
        #expect(try await store.count() == 0)
    }
}

@Suite("Persistent RequestLogStore")
struct PersistentRequestLogStoreTests {
    @Test func roundTripsThroughSQLite() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try RequestLogStore(path: tmp.path)
        try await store.record(.init(
            receivedAt: Date(),
            method: "POST",
            path: "/v1/moderations",
            status: 200,
            durationMs: 42,
            clientIP: "127.0.0.1",
            model: "omni-moderation-latest",
            requestBytes: 128,
            responseBytes: 256,
            authOK: true,
            moderationFlagged: true
        ))
        let recent = try await store.recent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent[0].path == "/v1/moderations")
        #expect(recent[0].moderationFlagged == true)
        #expect(recent[0].model == "omni-moderation-latest")
    }
}
