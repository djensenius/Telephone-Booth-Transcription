import Foundation

/// Test-only in-memory implementation of `RequestLogStoring`.
public actor InMemoryRequestLogStore: RequestLogStoring {
    private var entries: [RequestLogEntry] = []
    private var nextID: Int64 = 1
    private let retention: RetentionPolicy

    public init(retention: RetentionPolicy = .unlimited) {
        self.retention = retention
    }

    /// Pre-populates the store with `seed` entries. Any entry missing an `id`
    /// is assigned one. Useful for previews, demos, and tests that need a
    /// non-empty log without going through `record`.
    public init(retention: RetentionPolicy = .unlimited, seed: [RequestLogEntry]) {
        self.retention = retention
        var seeded: [RequestLogEntry] = []
        var counter: Int64 = 1
        for entry in seed {
            var copy = entry
            if copy.id == nil {
                copy.id = counter
                counter += 1
            } else {
                counter = max(counter, copy.id! + 1)
            }
            seeded.append(copy)
        }

        self.entries = Self.applyingRetention(retention, to: seeded)
        self.nextID = counter
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
        entries = Self.applyingRetention(retention, to: entries)
    }

    /// Pure retention transform shared by the seeded initializer and
    /// `enforceRetention()` so the two never drift.
    private static func applyingRetention(
        _ retention: RetentionPolicy,
        to input: [RequestLogEntry],
        now: Date = Date()
    ) -> [RequestLogEntry] {
        var result = input
        if let maxAge = retention.maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            result.removeAll { $0.receivedAt < cutoff }
        }
        if let maxRows = retention.maxRows, maxRows > 0, result.count > maxRows {
            result.sort { $0.receivedAt > $1.receivedAt }
            result = Array(result.prefix(maxRows))
        }
        return result
    }
}
