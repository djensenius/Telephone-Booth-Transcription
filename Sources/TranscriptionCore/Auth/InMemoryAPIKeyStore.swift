import Foundation

/// Test-friendly API key store backed by an in-memory dictionary.
public final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    public init(initial: [String: String] = [:]) {
        self.storage = initial
    }

    public func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func write(account: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
    }

    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}
