#if canImport(Security)
import Foundation
import Security

/// Stores the server's bearer token in the macOS login keychain.
///
/// One generic-password entry per (service, account) tuple. We use a constant
/// service identifier ("dev.djensenius.telephone-booth-transcription") and the
/// account "server-token". The Keychain ACL inherits the app's code-signing
/// identity so other apps can't read the item.
public final class KeychainTokenStore: TokenStore {
    public static let defaultService = "dev.djensenius.telephone-booth-transcription"
    public static let defaultAccount = "server-token"

    private let service: String
    private let account: String

    public init(
        service: String = KeychainTokenStore.defaultService,
        account: String = KeychainTokenStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func current() throws -> String {
        if let existing = try read() {
            return existing
        }
        let fresh = Self.generateToken()
        try write(fresh)
        return fresh
    }

    @discardableResult
    public func rotate(to newToken: String?) throws -> String {
        let token = newToken ?? Self.generateToken()
        try write(token)
        return token
    }

    public func verify(_ presented: String) throws -> Bool {
        let stored = try current()
        return constantTimeEquals(stored, presented)
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
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let str = String(data: data, encoding: .utf8) else {
                throw TokenStoreError.encodingFailed
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.keychainStatus(status)
        }
    }

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
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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
