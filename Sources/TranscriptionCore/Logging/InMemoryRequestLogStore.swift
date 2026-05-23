import Foundation

/// Test-only in-memory implementation of `RequestLogStoring`.
public actor InMemoryRequestLogStore: RequestLogStoring {
    private var entries: [RequestLogEntry] = []
    private var nextID: Int64 = 1

    public init() {}

    public func record(_ entry: RequestLogEntry) async throws {
        var copy = entry
        if copy.id == nil {
            copy.id = nextID
            nextID += 1
        }
        entries.append(copy)
    }

    public func recent(limit: Int) async throws -> [RequestLogEntry] {
        let sorted = entries.sorted { $0.receivedAt > $1.receivedAt }
        return Array(sorted.prefix(limit))
    }

    public func count() async throws -> Int { entries.count }

    public func purge() async throws { entries.removeAll() }
}
