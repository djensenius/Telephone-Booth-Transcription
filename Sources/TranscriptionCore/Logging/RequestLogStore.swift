import Foundation
import GRDB

/// A single row in the request log.
public struct RequestLogEntry: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public var id: Int64?
    public var receivedAt: Date
    public var method: String
    public var path: String
    public var status: Int
    public var durationMs: Int
    public var clientIP: String?
    public var model: String?
    public var requestBytes: Int
    public var responseBytes: Int
    public var authOK: Bool
    /// If moderation: was the input flagged?
    public var moderationFlagged: Bool?
    /// Error class name if the request failed.
    public var error: String?

    public static let databaseTableName = "request_log"

    public init(
        id: Int64? = nil,
        receivedAt: Date,
        method: String,
        path: String,
        status: Int,
        durationMs: Int,
        clientIP: String? = nil,
        model: String? = nil,
        requestBytes: Int = 0,
        responseBytes: Int = 0,
        authOK: Bool = true,
        moderationFlagged: Bool? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.method = method
        self.path = path
        self.status = status
        self.durationMs = durationMs
        self.clientIP = clientIP
        self.model = model
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.authOK = authOK
        self.moderationFlagged = moderationFlagged
        self.error = error
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Protocol so tests can swap in an in-memory implementation.
public protocol RequestLogStoring: Sendable {
    func record(_ entry: RequestLogEntry) async throws
    func recent(limit: Int) async throws -> [RequestLogEntry]
    func count() async throws -> Int
    func purge() async throws
}

/// GRDB-backed persistent request log. The database lives at the path provided
/// at construction time; the standard location is
/// `~/Library/Application Support/TelephoneBoothTranscription/requests.sqlite`.
public final class RequestLogStore: RequestLogStoring {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.label = "request-log"
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    /// Convenience initializer that resolves the default Application Support path.
    public convenience init() throws {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TelephoneBoothTranscription", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try self.init(path: base.appendingPathComponent("requests.sqlite").path)
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("create_request_log") { db in
            try db.create(table: RequestLogEntry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("receivedAt", .datetime).notNull().indexed()
                t.column("method", .text).notNull()
                t.column("path", .text).notNull()
                t.column("status", .integer).notNull()
                t.column("durationMs", .integer).notNull()
                t.column("clientIP", .text)
                t.column("model", .text)
                t.column("requestBytes", .integer).notNull().defaults(to: 0)
                t.column("responseBytes", .integer).notNull().defaults(to: 0)
                t.column("authOK", .boolean).notNull().defaults(to: true)
                t.column("moderationFlagged", .boolean)
                t.column("error", .text)
            }
        }
        try migrator.migrate(dbQueue)
    }

    public func record(_ entry: RequestLogEntry) async throws {
        try await dbQueue.write { db in
            _ = try entry.inserted(db)
        }
    }

    public func recent(limit: Int) async throws -> [RequestLogEntry] {
        try await dbQueue.read { db in
            try RequestLogEntry
                .order(Column("receivedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func count() async throws -> Int {
        try await dbQueue.read { db in
            try RequestLogEntry.fetchCount(db)
        }
    }

    public func purge() async throws {
        _ = try await dbQueue.write { db in
            try RequestLogEntry.deleteAll(db)
        }
    }
}
