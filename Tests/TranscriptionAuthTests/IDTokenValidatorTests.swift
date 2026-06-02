//
//  IDTokenValidatorTests.swift
//  TranscriptionAuthTests
//

import Foundation
import Testing
@testable import TranscriptionAuth

@Suite("IDTokenValidator")
struct IDTokenValidatorTests {
    private static let issuer = "https://auth.example.com/application/o/app"
    private static let clientID = "test-client"

    /// Builds an unsigned JWT (header.payload.signature) with the given claims.
    private func makeJWT(_ claims: [String: Any]) -> String {
        func segment(_ object: [String: Any]) -> String {
            // swiftlint:disable:next force_try
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = segment(["alg": "none", "typ": "JWT"])
        let payload = segment(claims)
        return "\(header).\(payload).sig"
    }

    private func validClaims(nonce: String = "nonce-1") -> [String: Any] {
        [
            "iss": Self.issuer,
            "aud": Self.clientID,
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "nonce": nonce
        ]
    }

    @Test("accepts a well-formed token")
    func acceptsValidToken() throws {
        let jwt = makeJWT(validClaims())
        try IDTokenValidator.validate(
            idToken: jwt, expectedNonce: "nonce-1",
            issuer: Self.issuer, clientID: Self.clientID
        )
    }

    @Test("accepts issuer with a trailing slash mismatch")
    func normalizesTrailingSlash() throws {
        var claims = validClaims()
        claims["iss"] = Self.issuer + "/"
        let jwt = makeJWT(claims)
        try IDTokenValidator.validate(
            idToken: jwt, expectedNonce: "nonce-1",
            issuer: Self.issuer, clientID: Self.clientID
        )
    }

    @Test("accepts an audience array containing the client ID")
    func acceptsAudienceArray() throws {
        var claims = validClaims()
        claims["aud"] = ["other-client", Self.clientID]
        let jwt = makeJWT(claims)
        try IDTokenValidator.validate(
            idToken: jwt, expectedNonce: "nonce-1",
            issuer: Self.issuer, clientID: Self.clientID
        )
    }

    @Test("rejects an issuer mismatch")
    func rejectsIssuerMismatch() {
        var claims = validClaims()
        claims["iss"] = "https://evil.example.com"
        let jwt = makeJWT(claims)
        #expect(throws: AuthError.self) {
            try IDTokenValidator.validate(
                idToken: jwt, expectedNonce: "nonce-1",
                issuer: Self.issuer, clientID: Self.clientID
            )
        }
    }

    @Test("rejects an audience that lacks the client ID")
    func rejectsAudienceMismatch() {
        var claims = validClaims()
        claims["aud"] = "someone-else"
        let jwt = makeJWT(claims)
        #expect(throws: AuthError.self) {
            try IDTokenValidator.validate(
                idToken: jwt, expectedNonce: "nonce-1",
                issuer: Self.issuer, clientID: Self.clientID
            )
        }
    }

    @Test("rejects an expired token")
    func rejectsExpired() {
        var claims = validClaims()
        claims["exp"] = Date().addingTimeInterval(-3600).timeIntervalSince1970
        let jwt = makeJWT(claims)
        #expect(throws: AuthError.self) {
            try IDTokenValidator.validate(
                idToken: jwt, expectedNonce: "nonce-1",
                issuer: Self.issuer, clientID: Self.clientID
            )
        }
    }

    @Test("rejects a nonce mismatch")
    func rejectsNonceMismatch() {
        let jwt = makeJWT(validClaims(nonce: "wrong"))
        #expect(throws: AuthError.self) {
            try IDTokenValidator.validate(
                idToken: jwt, expectedNonce: "nonce-1",
                issuer: Self.issuer, clientID: Self.clientID
            )
        }
    }

    @Test("rejects a malformed JWT")
    func rejectsMalformed() {
        #expect(throws: AuthError.self) {
            try IDTokenValidator.validate(
                idToken: "not-a-jwt", expectedNonce: "nonce-1",
                issuer: Self.issuer, clientID: Self.clientID
            )
        }
    }
}
