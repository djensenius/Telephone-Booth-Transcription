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

@Suite("Refresh failure classification")
struct RefreshFailureClassificationTests {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    @Test("an OAuth error proving the grant is dead ends the session", arguments: [
        "invalid_grant", "invalid_client", "unauthorized_client", "invalid_scope"
    ])
    func fatalOAuthErrors(code: String) {
        let payload = body(#"{"error":"\#(code)"}"#)
        #expect(AuthManager.refreshFailureIsFatal(status: 400, body: payload))
    }

    @Test("throttling keeps the session even though it is a 4xx")
    func throttlingIsTransient() {
        // Authentik/proxies answer 429 while rate limiting; the refresh token
        // is still perfectly good, so this must not sign the user out.
        let payload = body(#"{"error":"rate_limited"}"#)
        #expect(!AuthManager.refreshFailureIsFatal(status: 429, body: payload))
    }

    @Test("a 4xx from infrastructure rather than the provider is transient", arguments: [
        408, 429, 403, 404, 502
    ])
    func nonOAuthFailuresAreTransient(status: Int) {
        // A proxy in front of the provider returns HTML, not an OAuth body.
        let payload = body("<html><body>Gateway error</body></html>")
        #expect(!AuthManager.refreshFailureIsFatal(status: status, body: payload))
    }

    @Test("a bare 400/401 with no parseable body still ends the session", arguments: [400, 401])
    func unparseableRefusalIsFatal(status: Int) {
        // Otherwise the app would retry a dead token forever.
        #expect(AuthManager.refreshFailureIsFatal(status: status, body: Data()))
    }

    @Test("an unrecognised OAuth error code is treated as transient")
    func unknownOAuthErrorIsTransient() {
        let payload = body(#"{"error":"temporarily_unavailable"}"#)
        #expect(!AuthManager.refreshFailureIsFatal(status: 400, body: payload))
    }

    @Test("the OAuth error code is read out of the response body")
    func extractsErrorCode() {
        #expect(AuthManager.oauthErrorCode(from: body(#"{"error":"invalid_grant"}"#)) == "invalid_grant")
        #expect(AuthManager.oauthErrorCode(from: body("not json")) == nil)
        #expect(AuthManager.oauthErrorCode(from: body(#"{"detail":"nope"}"#)) == nil)
    }
}
