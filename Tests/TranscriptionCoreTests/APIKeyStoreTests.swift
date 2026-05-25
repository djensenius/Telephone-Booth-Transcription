import Foundation
import Testing
@testable import TranscriptionCore

@Suite("APIKeyStore")
struct APIKeyStoreTests {
    @Test func readReturnsNilForMissingKey() throws {
        let store = InMemoryAPIKeyStore()
        let result = try store.read(account: "nonexistent")
        #expect(result == nil)
    }

    @Test func writeAndReadRoundTrips() throws {
        let store = InMemoryAPIKeyStore()
        try store.write(account: APIKeyAccount.transcription, value: "sk-test-123")
        let result = try store.read(account: APIKeyAccount.transcription)
        #expect(result == "sk-test-123")
    }

    @Test func writeOverwritesPreviousValue() throws {
        let store = InMemoryAPIKeyStore()
        try store.write(account: APIKeyAccount.moderation, value: "first")
        try store.write(account: APIKeyAccount.moderation, value: "second")
        let result = try store.read(account: APIKeyAccount.moderation)
        #expect(result == "second")
    }

    @Test func deleteRemovesKey() throws {
        let store = InMemoryAPIKeyStore()
        try store.write(account: APIKeyAccount.transcription, value: "to-delete")
        try store.delete(account: APIKeyAccount.transcription)
        let result = try store.read(account: APIKeyAccount.transcription)
        #expect(result == nil)
    }

    @Test func deleteNonexistentIsNoOp() throws {
        let store = InMemoryAPIKeyStore()
        try store.delete(account: "nonexistent")
    }

    @Test func distinctAccountsAreIsolated() throws {
        let store = InMemoryAPIKeyStore()
        try store.write(account: APIKeyAccount.transcription, value: "t-key")
        try store.write(account: APIKeyAccount.moderation, value: "m-key")
        #expect(try store.read(account: APIKeyAccount.transcription) == "t-key")
        #expect(try store.read(account: APIKeyAccount.moderation) == "m-key")
    }

    @Test func concurrentAccessDoesNotCrash() async throws {
        let store = InMemoryAPIKeyStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    try store.write(account: APIKeyAccount.transcription, value: "val-\(i)")
                }
                group.addTask {
                    _ = try store.read(account: APIKeyAccount.transcription)
                }
            }
            try await group.waitForAll()
        }
        // After all writes, reading should return a valid value
        let final_ = try store.read(account: APIKeyAccount.transcription)
        #expect(final_ != nil)
    }
}
