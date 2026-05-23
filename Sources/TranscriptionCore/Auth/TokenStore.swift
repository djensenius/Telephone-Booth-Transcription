import Crypto
import Foundation

/// Persistent storage for the single bearer token that protects the server.
///
/// We intentionally keep the surface minimal: rotate, fetch, verify. Verification
/// uses a constant-time comparison to avoid leaking the token via timing.
public protocol TokenStore: Sendable {
    /// Returns the current token, creating one on first access if necessary.
    func current() throws -> String
    /// Replaces the stored token with `newToken` and returns it.
    @discardableResult
    func rotate(to newToken: String?) throws -> String
    /// Constant-time verification of a presented token.
    func verify(_ presented: String) throws -> Bool
}

extension TokenStore {
    /// Generates a 32-byte URL-safe random token suitable for `Authorization: Bearer`.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBytes { buf -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }
}

/// Constant-time byte-wise comparison. Returns true iff the two strings have the
/// same UTF-8 bytes. Length differences also short-circuit in constant time
/// relative to the *shorter* of the two strings.
public func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    // Compare lengths separately — this leaks length, which is acceptable
    // for tokens since we always issue fixed-length tokens.
    if aBytes.count != bBytes.count { return false }
    var diff: UInt8 = 0
    for i in 0..<aBytes.count {
        diff |= aBytes[i] ^ bBytes[i]
    }
    return diff == 0
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum TokenStoreError: Error, Sendable, Equatable {
    case keychainStatus(OSStatus)
    case encodingFailed
}
