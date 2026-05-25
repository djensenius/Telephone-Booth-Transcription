#if canImport(Security)
import Foundation
import Logging
import Security

/// Stores the server's bearer token in the macOS login keychain.
///
/// One generic-password entry per (service, account) tuple. We use a constant
/// service identifier ("dev.djensenius.telephone-booth-transcription") and the
/// account "server-token". The Keychain ACL inherits the app's code-signing
/// identity so other apps can't read the item.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    public static let defaultService = "dev.djensenius.telephone-booth-transcription"
    public static let defaultAccount = "server-token"

    private let lock = NSLock()
    private let service: String
    private let account: String

    private let logger = Logger(label: "keychain-token-store")

    public init(
        service: String = KeychainTokenStore.defaultService,
        account: String = KeychainTokenStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func current() throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try _currentUnlocked()
    }

    @discardableResult
    public func rotate(to newToken: String?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let token = newToken ?? Self.generateToken()
        try write(token)
        return token
    }

    public func verify(_ presented: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let stored = try _currentUnlocked()
        return constantTimeEquals(stored, presented)
    }

    // MARK: - Internal helpers

    /// Returns the current token, creating one if necessary.
    /// Caller must already hold `lock`.
    private func _currentUnlocked() throws -> String {
        if let existing = try read() {
            return existing
        }
        let fresh = Self.generateToken()
        try write(fresh)
        return fresh
    }

    // MARK: - Keychain primitives

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let dict = item as? [String: Any],
                  let data = dict[kSecValueData as String] as? Data,
                  let str = String(data: data, encoding: .utf8) else {
                throw TokenStoreError.encodingFailed
            }
            // Migrate items stored with a broader accessibility level.
            // Migration is best-effort; a failure still returns the token.
            let currentAccessibility = dict[kSecAttrAccessible as String] as? String
            let desired = Self.desiredAccessibility as String
            if currentAccessibility != desired {
                do {
                    try migrateAccessibility(token: str)
                } catch {
                    logger.warning("Keychain accessibility migration failed, will retry next read: \(error)")
                }
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.keychainStatus(status)
        }
    }

    /// Re-creates the keychain item with the correct accessibility attribute.
    /// `SecItemUpdate` cannot change `kSecAttrAccessible`, so we delete + re-add.
    private func migrateAccessibility(token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStoreError.encodingFailed
        }
        let deleteStatus = SecItemDelete(baseQuery() as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw TokenStoreError.keychainStatus(deleteStatus)
        }
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = Self.desiredAccessibility
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStoreError.keychainStatus(addStatus)
        }
    }

    /// The accessibility level for new and migrated keychain items.
    /// "AfterFirstUnlock" allows background access (needed for auto-launch);
    /// "ThisDeviceOnly" excludes the item from backups and iCloud Keychain sync.
    nonisolated(unsafe) static let desiredAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private func write(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStoreError.encodingFailed
        }
        let query = baseQuery()
        let attrs: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = Self.desiredAccessibility
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TokenStoreError.keychainStatus(addStatus)
            }
        default:
            throw TokenStoreError.keychainStatus(updateStatus)
        }
    }
}
#endif
