import Foundation

/// Test-only in-memory implementation of `RequestLogStoring`.
public actor InMemoryRequestLogStore: RequestLogStoring {
    private var entries: [RequestLogEntry] = []
    private var nextID: Int64 = 1
    private let retention: RetentionPolicy

    public init(retention: RetentionPolicy = .unlimited) {
        self.retention = retention
    }

    public func record(_ entry: RequestLogEntry) async throws {
        var copy = entry
        if copy.id == nil {
            copy.id = nextID
            nextID += 1
        }
        entries.append(copy)
        enforceRetention()
    }

    public func recent(limit: Int) async throws -> [RequestLogEntry] {
        let sorted = entries.sorted { $0.receivedAt > $1.receivedAt }
        return Array(sorted.prefix(limit))
    }

    public func count() async throws -> Int { entries.count }

    public func purge() async throws { entries.removeAll() }

    private func enforceRetention() {
        let now = Date()
        if let maxAge = retention.maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            entries.removeAll { $0.receivedAt < cutoff }
        }
        if let maxRows = retention.maxRows, maxRows > 0, entries.count > maxRows {
            entries.sort { $0.receivedAt > $1.receivedAt }
            entries = Array(entries.prefix(maxRows))
        }
    }
}
