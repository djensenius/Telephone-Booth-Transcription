//
//  DemoReviewData.swift
//  Telephone-Booth-Transcription
//
//  Deterministic sample review queue for demo mode and previews. Review is the
//  app's primary surface but needs an Operator session, so without this it
//  can't be screenshotted or eyeballed at all — the other demo tabs already get
//  that treatment via `DemoData`.
//
//  None of this is real traffic. It exists purely to render the UI.
//

import Foundation
import TranscriptionReview

/// A stand-in Operator that serves a fixed queue and applies writes locally, so
/// approving or translating in demo mode behaves like the real thing.
actor DemoOperatorReviewClient: OperatorReviewClient {
    /// Messages are held as JSON objects rather than decoded models because the
    /// review models are immutable value types with no public initializer.
    /// Round-tripping through their `Codable` conformance keeps this demo-only
    /// helper from widening the module's real API surface.
    private var raw: [[String: Any]]

    init() {
        raw = DemoReviewData.messageObjects()
    }

    func fetchMessages(status: MessageStatus?, since: Date?, limit: Int) async throws -> MessageList {
        try decodeList()
    }

    func fetchTranscriptions(messageID: String) async throws -> TranscriptionList {
        TranscriptionList(items: [])
    }

    func submitDecision(
        messageID: String,
        decision: ReviewDecision,
        notes: String?
    ) async throws -> Message {
        guard let index = raw.firstIndex(where: { $0["id"] as? String == messageID }) else {
            throw OperatorReviewError.api(status: 404, code: "not_found")
        }
        raw[index]["status"] = decision == .approve ? "approved" : "rejected"
        if let notes, !notes.isEmpty { raw[index]["notes"] = notes }
        return try decode(Message.self, from: raw[index])
    }

    func submitTranscription(
        messageID: String,
        text: String,
        language: String?,
        model: String?
    ) async throws -> Transcription {
        guard let index = raw.firstIndex(where: { $0["id"] as? String == messageID }) else {
            throw OperatorReviewError.api(status: 404, code: "not_found")
        }
        // A submitted transcript creates a new row on the Operator, so mint a
        // new id here too: the moderation attached to the old row no longer
        // applies to this text.
        let transcription = DemoReviewData.transcription(
            id: "tr-demo-\(UUID().uuidString.prefix(8))",
            messageID: messageID,
            text: text,
            language: language ?? "en",
            minutesAgo: 0
        )
        raw[index]["latestTranscription"] = transcription
        return try decode(Transcription.self, from: transcription)
    }

    func submitTranslation(
        messageID: String,
        translatedText: String,
        translatedLanguage: String?
    ) async throws -> Transcription {
        guard let index = raw.firstIndex(where: { $0["id"] as? String == messageID }),
              var transcription = raw[index]["latestTranscription"] as? [String: Any] else {
            throw OperatorReviewError.api(status: 404, code: "no_succeeded_transcription")
        }
        transcription["translationStatus"] = "succeeded"
        transcription["translatedText"] = translatedText
        transcription["translatedLanguage"] = translatedLanguage ?? "en"
        transcription["translationProvider"] = "mac_app"
        transcription["translationError"] = NSNull()
        raw[index]["latestTranscription"] = transcription
        return try decode(Transcription.self, from: transcription)
    }

    private func decodeList() throws -> MessageList {
        let data = try JSONSerialization.data(withJSONObject: ["items": raw])
        return try OperatorJSON.decoder.decode(MessageList.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try OperatorJSON.decoder.decode(type, from: data)
    }
}

/// The fixed queue demo mode serves. Spans every state the review UI
/// distinguishes, so each filter has something to show.
enum DemoReviewData {
    private static func ago(_ minutes: Double) -> String {
        OperatorJSON.iso8601String(from: Date().addingTimeInterval(-minutes * 60))
    }

    private static func audio(_ seed: String) -> [String: Any] {
        ["url": "https://example.invalid/\(seed).flac", "sha256": seed, "durationMs": 5400]
    }

    static func transcription(
        id: String,
        messageID: String,
        status: String = "succeeded",
        text: String?,
        language: String?,
        error: String? = nil,
        translationStatus: String? = nil,
        translatedText: String? = nil,
        translationError: String? = nil,
        minutesAgo: Double
    ) -> [String: Any] {
        [
            "id": id,
            "messageId": messageID,
            "provider": "mac_app",
            "model": "apple-speech-analyzer",
            "status": status,
            "text": text ?? NSNull(),
            "language": language ?? NSNull(),
            "durationMs": 5400,
            "latencyMs": 820,
            "error": error ?? NSNull(),
            "requestedById": NSNull(),
            "createdAt": ago(minutesAgo),
            "completedAt": ago(minutesAgo),
            "translationStatus": translationStatus ?? NSNull(),
            "translatedText": translatedText ?? NSNull(),
            "translatedLanguage": translatedText == nil ? NSNull() : "en",
            "translationProvider": translationStatus == nil ? NSNull() : "mac_app",
            "translationModel": NSNull(),
            "translationError": translationError ?? NSNull(),
            "translationLatencyMs": NSNull(),
            "translationCompletedAt": NSNull(),
        ]
    }

    private static func moderation(
        id: String,
        messageID: String,
        transcriptionID: String,
        recommendation: String,
        flagged: Bool,
        maxScore: Double,
        reason: String,
        minutesAgo: Double
    ) -> [String: Any] {
        [
            "id": id,
            "messageId": messageID,
            "transcriptionId": transcriptionID,
            "provider": "mac_app",
            "model": "apple-foundation-models",
            "status": "succeeded",
            "flagged": flagged,
            "recommendation": recommendation,
            "maxScore": maxScore,
            "categories": NSNull(),
            "reasonSummary": reason,
            "latencyMs": 140,
            "error": NSNull(),
            "createdAt": ago(minutesAgo),
            "completedAt": ago(minutesAgo),
        ]
    }

    private static func message(
        id: String,
        status: String,
        minutesAgo: Double,
        transcription: [String: Any]? = nil,
        moderation: [String: Any]? = nil
    ) -> [String: Any] {
        [
            "id": id,
            "status": status,
            "questionId": NSNull(),
            "notes": NSNull(),
            "createdAt": ago(minutesAgo),
            "receivedAt": ago(minutesAgo),
            "audio": audio(id),
            "latestTranscription": transcription ?? NSNull(),
            "latestModeration": moderation ?? NSNull(),
        ]
    }

    /// Newest first, matching the Operator's ordering.
    static func messageObjects() -> [[String: Any]] {
        [
            message(id: "demo-new", status: "pending", minutesAgo: 3),

            message(
                id: "demo-failed-transcript",
                status: "pending",
                minutesAgo: 11,
                transcription: transcription(
                    id: "t-failed",
                    messageID: "demo-failed-transcript",
                    status: "failed",
                    text: nil,
                    language: nil,
                    error: "The transcription upstream timed out.",
                    minutesAgo: 10
                )
            ),

            message(
                id: "demo-untranslated",
                status: "pending",
                minutesAgo: 24,
                transcription: transcription(
                    id: "t-fr",
                    messageID: "demo-untranslated",
                    text: "Allô? Je voulais juste dire que la cabine téléphonique au bout "
                        + "de la rue m'a rappelé les étés chez ma grand-mère.",
                    language: "fr",
                    minutesAgo: 23
                )
            ),

            message(
                id: "demo-failed-translation",
                status: "pending",
                minutesAgo: 38,
                transcription: transcription(
                    id: "t-ja",
                    messageID: "demo-failed-translation",
                    text: "もしもし。この電話ボックスの中は静かですね。ここで少し考える時間が持てました。",
                    language: "ja",
                    translationStatus: "failed",
                    translationError: "The on-device model ran out of context.",
                    minutesAgo: 37
                )
            ),

            message(
                id: "demo-approve",
                status: "pending",
                minutesAgo: 52,
                transcription: transcription(
                    id: "t-es",
                    messageID: "demo-approve",
                    text: "Hola. Solo quería decir que este proyecto me parece precioso. "
                        + "Gracias por dejarnos hablar.",
                    language: "es",
                    translationStatus: "succeeded",
                    translatedText: "Hello. I just wanted to say that I think this project is "
                        + "beautiful. Thank you for letting us speak.",
                    minutesAgo: 51
                ),
                moderation: moderation(
                    id: "m-approve",
                    messageID: "demo-approve",
                    transcriptionID: "t-es",
                    recommendation: "approve",
                    flagged: false,
                    maxScore: 0.02,
                    reason: "Warm, on-topic message with no policy concerns.",
                    minutesAgo: 51
                )
            ),

            message(
                id: "demo-review",
                status: "pending",
                minutesAgo: 74,
                transcription: transcription(
                    id: "t-en",
                    messageID: "demo-review",
                    text: "I don't know who listens to these, but I've been having a rough "
                        + "few months and this felt like the only place left to say it.",
                    language: "en",
                    translationStatus: "succeeded",
                    translatedText: "I don't know who listens to these, but I've been having a "
                        + "rough few months and this felt like the only place left to say it.",
                    minutesAgo: 73
                ),
                moderation: moderation(
                    id: "m-review",
                    messageID: "demo-review",
                    transcriptionID: "t-en",
                    recommendation: "review",
                    flagged: false,
                    maxScore: 0.41,
                    reason: "Mentions personal distress. Needs a human read before publishing.",
                    minutesAgo: 73
                )
            ),

            message(
                id: "demo-reject",
                status: "received",
                minutesAgo: 96,
                transcription: transcription(
                    id: "t-rej",
                    messageID: "demo-reject",
                    text: "[caller reads out a phone number and a home address]",
                    language: "en",
                    translationStatus: "succeeded",
                    translatedText: "[caller reads out a phone number and a home address]",
                    minutesAgo: 95
                ),
                moderation: moderation(
                    id: "m-reject",
                    messageID: "demo-reject",
                    transcriptionID: "t-rej",
                    recommendation: "reject",
                    flagged: true,
                    maxScore: 0.88,
                    reason: "Contains personal contact details belonging to a third party.",
                    minutesAgo: 95
                )
            ),

            message(
                id: "demo-silent",
                status: "pending",
                minutesAgo: 130,
                transcription: transcription(
                    id: "t-silent",
                    messageID: "demo-silent",
                    text: "   ",
                    language: nil,
                    minutesAgo: 129
                )
            ),

            message(
                id: "demo-approved",
                status: "approved",
                minutesAgo: 220,
                transcription: transcription(
                    id: "t-done",
                    messageID: "demo-approved",
                    text: "Buongiorno! Che bella idea, questa cabina.",
                    language: "it",
                    translationStatus: "succeeded",
                    translatedText: "Good morning! What a lovely idea, this booth.",
                    minutesAgo: 219
                ),
                moderation: moderation(
                    id: "m-done",
                    messageID: "demo-approved",
                    transcriptionID: "t-done",
                    recommendation: "approve",
                    flagged: false,
                    maxScore: 0.01,
                    reason: "No concerns.",
                    minutesAgo: 219
                )
            ),

            message(
                id: "demo-rejected",
                status: "rejected",
                minutesAgo: 300,
                transcription: transcription(
                    id: "t-gone",
                    messageID: "demo-rejected",
                    text: "[thirty seconds of wind noise]",
                    language: "en",
                    translationStatus: "succeeded",
                    translatedText: "[thirty seconds of wind noise]",
                    minutesAgo: 299
                )
            ),
        ]
    }
}
