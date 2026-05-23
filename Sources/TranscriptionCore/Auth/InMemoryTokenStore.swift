import Foundation

/// Test-friendly token store backed by an in-memory value.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(initial: String? = nil) {
        self.token = initial
    }

    public func current() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let existing = token { return existing }
        let fresh = Self.generateToken()
        token = fresh
        return fresh
    }

    @discardableResult
    public func rotate(to newToken: String?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let next = newToken ?? Self.generateToken()
        token = next
        return next
    }

    public func verify(_ presented: String) throws -> Bool {
        let stored = try current()
        return constantTimeEquals(stored, presented)
    }
}
