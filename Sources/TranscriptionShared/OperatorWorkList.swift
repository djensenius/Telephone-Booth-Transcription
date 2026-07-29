import Foundation

/// Working set requested from `GET /v1/worker/messages`.
public enum OperatorWorkNeeds: String, Sendable, Equatable, CaseIterable {
    /// Reviewable messages with no succeeded transcription — the default queue.
    case transcription
    /// All reviewable messages, including ones that already have a transcript,
    /// so the AI can deliberately be re-run over them.
    case any
}

/// One entry from `GET /v1/worker/messages`. Decoding is deliberately tolerant:
/// `status` stays a raw string (a freshly landed message reports `pending`, but
/// `received` still exists for historical rows) and every field except `id` is
/// optional so Operator-side additions never break this client.
public struct OperatorWorkListItem: Sendable, Equatable, Decodable {
    public var id: String
    /// Absent when the Operator omits it; never coerced to an empty string, so
    /// callers can tell "not reported" from a real value.
    public var status: String?
    public var receivedAt: Date?
    public var durationMs: Int?
    public var latestTranscriptionStatus: String?

    public init(
        id: String,
        status: String? = nil,
        receivedAt: Date? = nil,
        durationMs: Int? = nil,
        latestTranscriptionStatus: String? = nil
    ) {
        self.id = id
        self.status = status
        self.receivedAt = receivedAt
        self.durationMs = durationMs
        self.latestTranscriptionStatus = latestTranscriptionStatus
    }

    /// True when the Operator already holds a succeeded transcription for this
    /// message. Discovery skips these; a deliberate re-run does not.
    public var hasSucceededTranscription: Bool {
        latestTranscriptionStatus?.lowercased() == "succeeded"
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, receivedAt, durationMs, latestTranscriptionStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        durationMs = try? container.decodeIfPresent(Int.self, forKey: .durationMs)
        latestTranscriptionStatus = try? container.decodeIfPresent(
            String.self, forKey: .latestTranscriptionStatus
        )
        if let raw = try? container.decodeIfPresent(String.self, forKey: .receivedAt) {
            receivedAt = Self.parseTimestamp(raw)
        } else {
            receivedAt = nil
        }
    }

    /// Formatter construction is far more expensive than parsing, and a
    /// discovery pass decodes hundreds of items on a short interval, so both
    /// variants are built once (mirroring `OperatorJSON`).
    /// `ISO8601DateFormatter` is documented as thread-safe for reads once
    /// configured; these are configured here and never mutated again.
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseTimestamp(_ value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }
}

/// One page of `GET /v1/worker/messages`.
public struct OperatorWorkListPage: Sendable, Equatable, Decodable {
    public var items: [OperatorWorkListItem]
    public var nextCursor: String?

    public init(items: [OperatorWorkListItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case items, nextCursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The page's collection is required: a malformed 200 must surface as a
        // decode failure so the worker records it and retries, rather than
        // masquerading as an empty — and therefore "successful" — pass.
        items = try container.decode([OperatorWorkListItem].self, forKey: .items)
            .filter { !$0.id.isEmpty }
        let cursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        nextCursor = (cursor?.isEmpty == false) ? cursor : nil
    }
}
