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

    // MARK: - Moderation state

    private func decodeModeration(
        status: String,
        flagged: String = "null",
        recommendation: String = "null",
        maxScore: String = "null",
        model: String = "\"omni-moderation\"",
        provider: String = "\"openai\"",
        error: String = "null"
    ) throws -> Moderation {
        let json = """
        {"items":[{
          "id":"m","status":"pending","questionId":null,"notes":null,
          "createdAt":"2026-01-02T03:04:05.123Z","receivedAt":null,
          "audio":{"url":"https://example.com/a.flac","sha256":"abc","durationMs":1},
          "latestTranscription":null,
          "latestModeration":{
            "id":"m1","messageId":"x","transcriptionId":"t1","provider":\(provider),
            "model":\(model),"status":"\(status)","flagged":\(flagged),
            "recommendation":\(recommendation),"maxScore":\(maxScore),
            "categories":null,"reasonSummary":null,"latencyMs":null,
            "error":\(error),"createdAt":"2026-01-02T03:04:09Z","completedAt":null
          }
        }]}
        """
        let message = try #require(try decodeMessageList(json).items.first)
        return try #require(message.latestModeration)
    }

    @Test("a pending moderation reports pending, not failed")
    func moderationPending() throws {
        let moderation = try decodeModeration(status: "pending")
        #expect(moderation.isPending)
        #expect(!moderation.didFail)
    }

    @Test("a failed moderation reports failed and carries its error")
    func moderationFailed() throws {
        let moderation = try decodeModeration(status: "failed", error: "\"upstream 500\"")
        #expect(moderation.didFail)
        #expect(!moderation.isPending)
        #expect(moderation.error == "upstream 500")
    }

    @Test("a succeeded moderation is neither pending nor failed")
    func moderationSucceeded() throws {
        let moderation = try decodeModeration(status: "succeeded", recommendation: "\"approve\"")
        #expect(!moderation.isPending)
        #expect(!moderation.didFail)
    }

    @Test("the source label names the provider and model")
    func moderationSourceLabel() throws {
        let withModel = try decodeModeration(status: "succeeded")
        #expect(withModel.sourceLabel == "OpenAI · omni-moderation")

        // No model, or a blank one, falls back to just the provider.
        let noModel = try decodeModeration(status: "succeeded", model: "null")
        #expect(noModel.sourceLabel == "OpenAI")
        let blankModel = try decodeModeration(status: "succeeded", model: "\"  \"")
        #expect(blankModel.sourceLabel == "OpenAI")

        // An unnamed provider still gets a visible label rather than a bare
        // separator in the UI.
        let unnamed = try decodeModeration(status: "succeeded", provider: "\"  \"")
        #expect(unnamed.sourceLabel == "AI · omni-moderation")
    }

    @Test("an unrecognized provider is presented as prose, not as a wire value")
    func unknownProviderDisplayName() {
        #expect(AiProvider(rawValue: "on_device").displayName == "On device")
        #expect(AiProvider(rawValue: "foundation_models").displayName == "Foundation models")
        // Known providers keep their curated spelling.
        #expect(AiProvider(rawValue: "openai").displayName == "OpenAI")
        #expect(AiProvider(rawValue: "mac_app").displayName == "Mac app")
        // Degenerate input doesn't crash, and never renders as invisible
        // whitespace: an absent name reads as absent.
        #expect(AiProvider(rawValue: "").displayName == "")
        #expect(AiProvider(rawValue: "   ").displayName == "")
    }

    @Test("the flagged score label only appears when flagged")
    func moderationFlaggedScoreLabel() throws {
        // Flagged with a score: a label is produced.
        let flagged = try decodeModeration(
            status: "succeeded", flagged: "true", recommendation: "\"reject\"", maxScore: "0.87"
        )
        #expect(flagged.flaggedScoreLabel != nil)

        // Not flagged: no label, even with a score present.
        let notFlagged = try decodeModeration(
            status: "succeeded", flagged: "false", maxScore: "0.87"
        )
        #expect(notFlagged.flaggedScoreLabel == nil)

        // Flagged but no score: nothing to show.
        let noScore = try decodeModeration(status: "succeeded", flagged: "true")
        #expect(noScore.flaggedScoreLabel == nil)
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
