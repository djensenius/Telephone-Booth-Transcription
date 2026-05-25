import Foundation
import Testing
@testable import TranscriptionCore

@Suite("TokenStore")
struct TokenStoreTests {
    @Test func generateProducesURLSafeToken() {
        let t = InMemoryTokenStore.generateToken()
        #expect(!t.contains("+"))
        #expect(!t.contains("/"))
        #expect(!t.contains("="))
        #expect(t.count >= 32)
    }

    @Test func currentIsStable() throws {
        let store = InMemoryTokenStore()
        let a = try store.current()
        let b = try store.current()
        #expect(a == b)
    }

    @Test func rotateProducesNewToken() throws {
        let store = InMemoryTokenStore()
        let a = try store.current()
        let b = try store.rotate(to: nil)
        #expect(a != b)
        let c = try store.current()
        #expect(b == c)
    }

    @Test func rotateToSpecificValue() throws {
        let store = InMemoryTokenStore()
        let token = try store.rotate(to: "fixed-token-value-1234")
        #expect(token == "fixed-token-value-1234")
        #expect(try store.current() == "fixed-token-value-1234")
    }

    @Test func verifyAcceptsMatch() throws {
        let store = InMemoryTokenStore()
        let token = try store.current()
        #expect(try store.verify(token))
    }

    @Test func verifyRejectsMismatch() throws {
        let store = InMemoryTokenStore()
        _ = try store.current()
        #expect(try store.verify("not-the-token") == false)
    }

    @Test func constantTimeEqualsTrueWhenEqual() {
        #expect(constantTimeEquals("abc123", "abc123"))
    }

    @Test func constantTimeEqualsFalseWhenDifferent() {
        #expect(!constantTimeEquals("abc123", "abc124"))
    }

    @Test func constantTimeEqualsFalseWhenDifferentLength() {
        #expect(!constantTimeEquals("abc", "abcd"))
    }

    @Test func concurrentFirstAccessReturnsSameToken() async throws {
        let store = InMemoryTokenStore()
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask { try store.current() }
            }
            var tokens: [String] = []
            for try await token in group {
                tokens.append(token)
            }
            return tokens
        }
        let first = results[0]
        for token in results {
            #expect(token == first, "All concurrent callers must observe the same token")
        }
    }

    @Test func concurrentRotateAndCurrentDoNotCrash() async throws {
        let store = InMemoryTokenStore()
        _ = try store.current()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { _ = try store.current() }
                group.addTask { _ = try store.rotate(to: nil) }
            }
            try await group.waitForAll()
        }
        // After all rotations, current() must still return a valid token
        let final_ = try store.current()
        #expect(final_.count >= 32)
    }
}
