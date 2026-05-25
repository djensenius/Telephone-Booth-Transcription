#if canImport(Security)
import Foundation
import Security
import Testing
@testable import TranscriptionCore

@Suite("KeychainTokenStore integration", .serialized)
struct KeychainTokenStoreTests {
    /// Unique service per test run to avoid collisions.
    private static let testService = "dev.djensenius.tbt-test-\(UUID().uuidString)"
    private static let testAccount = "test-token"

    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: Self.testService, account: Self.testAccount)
    }

    private func cleanup() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.testService,
            kSecAttrAccount as String: Self.testAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Returns true if the Keychain is available in this environment.
    private func keychainAvailable() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.djensenius.tbt-availability-probe",
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("probe".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            SecItemDelete(query as CFDictionary)
            return true
        }
        return false
    }

    @Test func newItemUsesThisDeviceOnlyAccessibility() throws {
        try #require(keychainAvailable(), "Keychain not available in this environment")
        defer { cleanup() }
        let store = makeStore()
        _ = try store.current()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.testService,
            kSecAttrAccount as String: Self.testAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        #expect(status == errSecSuccess)
        let attrs = item as? [String: Any]
        let accessibility = attrs?[kSecAttrAccessible as String] as? String
        #expect(accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func migratesFromBroaderAccessibility() throws {
        try #require(keychainAvailable(), "Keychain not available in this environment")
        defer { cleanup() }

        // Manually insert an item with the old (broader) accessibility
        let token = "test-migration-token-12345678901234567890"
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.testService,
            kSecAttrAccount as String: Self.testAccount,
            kSecValueData as String: token.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        #expect(addStatus == errSecSuccess)

        // Reading via the store should trigger migration
        let store = makeStore()
        let readToken = try store.current()
        #expect(readToken == token)

        // Verify the accessibility was updated
        let verifyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.testService,
            kSecAttrAccount as String: Self.testAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(verifyQuery as CFDictionary, &item)
        #expect(status == errSecSuccess)
        let attrs = item as? [String: Any]
        let accessibility = attrs?[kSecAttrAccessible as String] as? String
        #expect(accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func rotatePreservesCorrectAccessibility() throws {
        try #require(keychainAvailable(), "Keychain not available in this environment")
        defer { cleanup() }
        let store = makeStore()
        _ = try store.current()
        _ = try store.rotate(to: "rotated-value-12345678901234567890")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.testService,
            kSecAttrAccount as String: Self.testAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        #expect(status == errSecSuccess)
        let attrs = item as? [String: Any]
        let accessibility = attrs?[kSecAttrAccessible as String] as? String
        #expect(accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
#endif
