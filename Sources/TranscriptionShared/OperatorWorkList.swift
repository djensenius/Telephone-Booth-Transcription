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
    public var status: String
    public var receivedAt: Date?
    public var durationMs: Int?
    public var latestTranscriptionStatus: String?

    public init(
        id: String,
        status: String = "",
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
        status = (try? container.decode(String.self, forKey: .status)) ?? ""
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

    private static func parseTimestamp(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
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
        let decoded = (try? container.decode([OperatorWorkListItem].self, forKey: .items)) ?? []
        items = decoded.filter { !$0.id.isEmpty }
        let cursor = try? container.decodeIfPresent(String.self, forKey: .nextCursor)
        nextCursor = (cursor?.isEmpty == false) ? cursor : nil
    }
}
