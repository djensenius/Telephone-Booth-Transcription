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
}
