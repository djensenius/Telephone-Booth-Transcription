#if canImport(Security)
import Foundation
import Security
import Testing
@testable import TranscriptionCore

@Suite("KeychainTokenStore integration", .serialized, .enabled(if: KeychainTokenStoreTests.keychainAvailable))
struct KeychainTokenStoreTests {
    /// Unique service per test run to avoid collisions.
    private static let testService = "dev.djensenius.tbt-test-\(UUID().uuidString)"
    private static let testAccount = "test-token"

    /// Returns true if the Keychain is fully available in this environment
    /// (supports add, attribute retrieval, and delete).
    static let keychainAvailable: Bool = {
        let probeService = "dev.djensenius.tbt-availability-probe"
        let probeAccount = "probe"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: Data("probe".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return false }
        defer { SecItemDelete(query as CFDictionary) }

        var readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &item)
        guard readStatus == errSecSuccess,
              let dict = item as? [String: Any],
              dict[kSecAttrAccessible as String] as? String != nil else {
            return false
        }
        return true
    }()

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



    @Test func newItemUsesThisDeviceOnlyAccessibility() throws {
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
