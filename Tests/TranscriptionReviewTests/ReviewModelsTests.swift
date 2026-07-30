//
//  ReviewModelsTests.swift
//  TranscriptionReviewTests
//

import Foundation
import Testing
@testable import TranscriptionReview

@Suite("Review model decoding")
struct ReviewModelsTests {
    private func decodeMessageList(_ json: String) throws -> MessageList {
        try OperatorJSON.decoder.decode(MessageList.self, from: Data(json.utf8))
    }

    static let fullMessageJSON = """
    {"items":[{
      "id":"11111111-1111-1111-1111-111111111111",
      "status":"pending",
      "questionId":null,
      "notes":null,
      "createdAt":"2026-01-02T03:04:05.123Z",
      "receivedAt":"2026-01-02T03:04:06Z",
      "audio":{"url":"https://example.com/a.flac","sha256":"abc","durationMs":4200},
      "latestTranscription":{
        "id":"t1","messageId":"11111111-1111-1111-1111-111111111111",
        "provider":"openai","model":"whisper-1","status":"succeeded",
        "text":"bonjour le monde","language":"fr","durationMs":4200,
        "latencyMs":900,"error":null,"requestedById":null,
        "createdAt":"2026-01-02T03:04:07Z","completedAt":"2026-01-02T03:04:08Z",
        "translationStatus":null,"translatedText":null,"translatedLanguage":null,
        "translationProvider":null,"translationModel":null,"translationError":null,
        "translationLatencyMs":null,"translationCompletedAt":null
      },
      "latestModeration":{
        "id":"m1","messageId":"11111111-1111-1111-1111-111111111111",
        "transcriptionId":"t1","provider":"openai","model":"omni-moderation",
        "status":"succeeded","flagged":false,"recommendation":"review",
        "maxScore":0.12,"categories":{"hate":0.01},"reasonSummary":"borderline",
        "latencyMs":120,"error":null,
        "createdAt":"2026-01-02T03:04:09Z","completedAt":"2026-01-02T03:04:10Z"
      }
    }]}
    """

    @Test("decodes a message list with transcription + moderation")
    func decodesFullMessage() throws {
        let json = Self.fullMessageJSON
        let list = try decodeMessageList(json)
        let message = try #require(list.items.first)
        #expect(message.status == .pending)
        #expect(message.latestTranscription?.text == "bonjour le monde")
        #expect(message.latestModeration?.recommendation == .review)
        #expect(message.audio.durationMs == 4200)
    }

    @Test("unknown enum values decode without throwing")
    func decodesUnknownEnums() throws {
        let json = """
        {"items":[{
          "id":"x","status":"quarantined","questionId":null,"notes":null,
          "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
          "audio":{"url":"https://example.com/a.flac","sha256":"abc","durationMs":null},
          "latestTranscription":null,"latestModeration":null
        }]}
        """
        let list = try decodeMessageList(json)
        #expect(list.items.first?.status == .unknown("quarantined"))
    }

    @Test("a succeeded transcription with no translation needs translation")
    func classifiesUntranslated() throws {
        let json = """
        {"items":[{
          "id":"x","status":"received","questionId":null,"notes":null,
          "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
          "audio":{"url":"https://example.com/a.flac","sha256":"abc","durationMs":null},
          "latestTranscription":{
            "id":"t1","messageId":"x","provider":"openai","model":null,
            "status":"succeeded","text":"hola","language":"es","durationMs":null,
            "latencyMs":null,"error":null,"requestedById":null,
            "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
            "translationStatus":null,"translatedText":null,"translatedLanguage":null,
            "translationProvider":null,"translationModel":null,"translationError":null,
            "translationLatencyMs":null,"translationCompletedAt":null
          },
          "latestModeration":null
        }]}
        """
        let message = try #require(try decodeMessageList(json).items.first)
        #expect(message.needsTranslation)
        #expect(message.awaitingModerationDecision)
    }

    @Test("a translated transcription does not need translation")
    func classifiesTranslated() throws {
        let json = """
        {"items":[{
          "id":"x","status":"approved","questionId":null,"notes":null,
          "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
          "audio":{"url":"https://example.com/a.flac","sha256":"abc","durationMs":null},
          "latestTranscription":{
            "id":"t1","messageId":"x","provider":"openai","model":null,
            "status":"succeeded","text":"hola","language":"es","durationMs":null,
            "latencyMs":null,"error":null,"requestedById":null,
            "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
            "translationStatus":"succeeded","translatedText":"hello","translatedLanguage":"en",
            "translationProvider":"openai","translationModel":"gpt","translationError":null,
            "translationLatencyMs":50,"translationCompletedAt":"2026-01-02T03:04:08Z"
          },
          "latestModeration":null
        }]}
        """
        let translated = try #require(try decodeMessageList(json).items.first)
        #expect(!translated.needsTranslation)
        #expect(!translated.awaitingModerationDecision)
    }

    @Test("translation in non-succeeded states still needs translation")
    func classifiesPendingAndFailedTranslation() throws {
        for translationStatus in ["pending", "failed"] {
            let json = """
            {"items":[{
              "id":"x","status":"received","questionId":null,"notes":null,
              "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
              "audio":{"url":"https://example.com/a.flac","sha256":"abc","durationMs":null},
              "latestTranscription":{
                "id":"t1","messageId":"x","provider":"openai","model":null,
                "status":"succeeded","text":"hola","language":"es","durationMs":null,
                "latencyMs":null,"error":null,"requestedById":null,
                "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
                "translationStatus":"\(translationStatus)","translatedText":null,"translatedLanguage":null,
                "translationProvider":null,"translationModel":null,"translationError":null,
                "translationLatencyMs":null,"translationCompletedAt":null
              },
              "latestModeration":null
            }]}
            """
            let message = try #require(try decodeMessageList(json).items.first)
            #expect(message.needsTranslation)
        }
    }

    @Test("whitespace-only translated text is treated as untranslated")
    func classifiesWhitespaceTranslation() throws {
        let json = """
        {"items":[{
          "id":"x","status":"approved","questionId":null,"notes":null,
          "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
          "audio":{"url":"https://example.com/a.flac","sha256":"abc","durationMs":null},
          "latestTranscription":{
            "id":"t1","messageId":"x","provider":"openai","model":null,
            "status":"succeeded","text":"hola","language":"es","durationMs":null,
            "latencyMs":null,"error":null,"requestedById":null,
            "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
            "translationStatus":"succeeded","translatedText":"   ","translatedLanguage":"en",
            "translationProvider":"openai","translationModel":"gpt","translationError":null,
            "translationLatencyMs":1,"translationCompletedAt":"2026-01-02T03:04:08Z"
          },
          "latestModeration":null
        }]}
        """
        let message = try #require(try decodeMessageList(json).items.first)
        #expect(message.needsTranslation)
    }

    @Test("whitespace-only source text does not need translation")
    func classifiesWhitespaceSource() throws {
        let json = """
        {"items":[{
          "id":"x","status":"received","questionId":null,"notes":null,
          "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
          "audio":{"url":"https://example.com/a.flac","sha256":"abc","durationMs":null},
          "latestTranscription":{
            "id":"t1","messageId":"x","provider":"openai","model":null,
            "status":"succeeded","text":"   ","language":"es","durationMs":null,
            "latencyMs":null,"error":null,"requestedById":null,
            "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
            "translationStatus":null,"translatedText":null,"translatedLanguage":null,
            "translationProvider":null,"translationModel":null,"translationError":null,
            "translationLatencyMs":null,"translationCompletedAt":null
          },
          "latestModeration":null
        }]}
        """
        let message = try #require(try decodeMessageList(json).items.first)
        #expect(!message.needsTranslation)
    }

    @Test("replacing the transcription drops a moderation that belonged to the old row")
    func replacingTranscriptionDropsStaleModeration() throws {
        let message = try #require(try decodeMessageList(Self.fullMessageJSON).items.first)
        let old = try #require(message.latestTranscription)
        #expect(message.latestModeration?.transcriptionId == old.id)

        // A submitted transcript creates a new row; the previous verdict was
        // computed for different text and must not be shown against it.
        let replaced = message.replacingLatestTranscription(old.copy(id: "t2"))
        #expect(replaced.latestModeration == nil)

        // A translation updates the same row in place, so its verdict stands.
        let translated = message.replacingLatestTranscription(old.copy(id: old.id))
        #expect(translated.latestModeration == message.latestModeration)
    }
}

private extension Transcription {
    func copy(id newID: String) -> Transcription {
        Transcription(
            id: newID, messageId: messageId, provider: provider, model: model,
            status: status, text: text, language: language, durationMs: durationMs,
            latencyMs: latencyMs, error: error, requestedById: requestedById,
            createdAt: createdAt, completedAt: completedAt,
            translationStatus: translationStatus, translatedText: translatedText,
            translatedLanguage: translatedLanguage, translationProvider: translationProvider,
            translationModel: translationModel, translationError: translationError,
            translationLatencyMs: translationLatencyMs, translationCompletedAt: translationCompletedAt
        )
    }
}
