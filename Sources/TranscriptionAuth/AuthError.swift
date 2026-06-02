//
//  AuthError.swift
//  TranscriptionAuth
//

import Foundation

/// Errors surfaced by `AuthManager`.
public enum AuthError: Error, LocalizedError {
    case noCode
    case stateMismatch
    case tokenExchangeFailed(String)
    case cancelled
    case unknown
    /// Server explicitly rejected the refresh token (4xx). Session is dead;
    /// caller must surface a fresh sign-in flow to the user.
    case refreshTokenInvalid(String)
    /// Refresh failed for a transient reason (offline, DNS, 5xx). Caller
    /// should keep the cached tokens and retry later.
    case transientRefreshFailure(any Error)
    /// ASWebAuthenticationSession failed to present (start() returned false).
    case presentationFailed
    /// Keychain write failed — tokens could not be persisted.
    case keychainWriteFailed
    /// The ID token returned by the provider failed local claim validation
    /// (issuer, audience, expiration, or nonce mismatch).
    case idTokenValidationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noCode:
            return "No authorization code received."
        case .stateMismatch:
            return "Authentication response did not match the request."
        case .tokenExchangeFailed(let msg):
            return "Token exchange failed: \(msg)"
        case .cancelled:
            return "Sign-in was cancelled."
        case .unknown:
            return "An unknown error occurred."
        case .refreshTokenInvalid(let msg):
            return "Session expired: \(msg)"
        case .transientRefreshFailure(let err):
            return "Temporary refresh failure: \(err.localizedDescription)"
        case .presentationFailed:
            return "Unable to present the sign-in window. Please try again."
        case .keychainWriteFailed:
            return "Failed to save credentials securely. Please try again."
        case .idTokenValidationFailed(let reason):
            return "ID token validation failed: \(reason)"
        }
    }
}
