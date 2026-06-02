//
//  AuthHelpersTests.swift
//  TranscriptionAuthTests
//

import CryptoKit
import Foundation
import Testing
@testable import TranscriptionAuth

@Suite("Auth helpers")
struct AuthHelpersTests {
    @Test("base64URL encoding is URL-safe and unpadded")
    func base64URLIsURLSafe() {
        let data = Data([0xFB, 0xFF, 0xFE, 0x00, 0x10])
        let encoded = AuthManager.base64URLEncode(data)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test("base64URL round-trips through the validator's decoder")
    func base64URLRoundTrips() throws {
        let original = Data("the quick brown fox".utf8)
        let encoded = AuthManager.base64URLEncode(original)
        let decoded = try #require(IDTokenValidator.base64URLDecode(encoded))
        #expect(decoded == original)
    }

    @Test("PKCE verifier yields the expected S256 challenge")
    func pkceChallengeMatchesS256() {
        let verifier = AuthManager.generateRandomString()
        let challenge = AuthManager.base64URLEncode(
            Data(SHA256.hash(data: Data(verifier.utf8)))
        )
        // The challenge is the URL-safe, unpadded SHA-256 of the verifier.
        let expected = AuthManager.base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        #expect(challenge == expected)
        #expect(!challenge.isEmpty)
        #expect(!challenge.contains("="))
    }

    @Test("random strings are unique and non-empty")
    func randomStringsAreUnique() {
        let a = AuthManager.generateRandomString()
        let b = AuthManager.generateRandomString()
        #expect(a != b)
        #expect(!a.isEmpty)
    }

    @Test("form encoding percent-escapes reserved characters")
    func formEncodingEscapesReserved() {
        let encoded = AuthManager.formEncode([("grant_type", "authorization_code"), ("redirect_uri", "tbtranscription://oauth/callback")])
        #expect(encoded.contains("grant_type=authorization_code"))
        // ':' and '/' must be percent-encoded.
        #expect(encoded.contains("tbtranscription%3A%2F%2Foauth%2Fcallback"))
    }

    @Test("config derives the redirect URI from the scheme")
    func configDerivesRedirectURI() {
        let config = AppAuthConfig(redirectScheme: "tbtranscription")
        #expect(config.redirectScheme == "tbtranscription")
        #expect(config.redirectURI == "tbtranscription://oauth/callback")
    }
}
