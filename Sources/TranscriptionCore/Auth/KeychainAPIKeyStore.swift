#if canImport(Security)
import Foundation
import Security

/// Stores upstream API keys in the macOS login Keychain.
///
/// Uses the same service identifier as `KeychainTokenStore` but different
/// account names so each key gets its own Keychain item.
public final class KeychainAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let service: String

    public init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try _read(account: account)
    }

    public func write(account: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        try _write(account: account, value: value)
    }

    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychainStatus(status)
        }
    }

    // MARK: - Private

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func _read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let str = String(data: data, encoding: .utf8) else {
                throw APIKeyStoreError.encodingFailed
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw APIKeyStoreError.keychainStatus(status)
        }
    }

    private func _write(account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw APIKeyStoreError.encodingFailed
        }
        let query = baseQuery(account: account)
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
                throw APIKeyStoreError.keychainStatus(addStatus)
            }
        default:
            throw APIKeyStoreError.keychainStatus(updateStatus)
        }
    }
}
#endif
