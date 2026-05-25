import Foundation

/// Protocol for storing and retrieving named API keys.
/// Production uses the macOS Keychain; tests use an in-memory implementation.
public protocol APIKeyStoring: Sendable {
    /// Returns the stored value for the given account, or nil if none exists.
    func read(account: String) throws -> String?
    /// Writes (or overwrites) the value for the given account.
    func write(account: String, value: String) throws
    /// Deletes the value for the given account. No-op if it doesn't exist.
    func delete(account: String) throws
}

/// Well-known account identifiers for upstream API keys.
public enum APIKeyAccount {
    public static let transcription = "upstream-transcription-api-key"
    public static let moderation = "upstream-moderation-api-key"
}
