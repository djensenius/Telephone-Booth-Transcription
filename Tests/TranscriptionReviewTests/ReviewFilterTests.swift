//
//  ReviewFilterTests.swift
//  TranscriptionReviewTests
//
//  Covers the one-list-with-filters model that replaced the stacked per-stage
//  buckets (issue #79). The invariant that matters: every reviewable message has
//  exactly one next step, so it appears in exactly one work filter — no message
//  is ever listed twice.
//

import Foundation
import Testing
@testable import TranscriptionReview

@Suite("Review filters")
struct ReviewFilterTests {
    private final class SeededClient: OperatorReviewClient, @unchecked Sendable {
        let seed: String

        init(seed: String) { self.seed = seed }

        func fetchMessages(status: MessageStatus?, since: Date?, limit: Int) async throws -> MessageList {
            try OperatorJSON.decoder.decode(MessageList.self, from: Data(seed.utf8))
        }

        func fetchTranscriptions(messageID: String) async throws -> TranscriptionList {
            TranscriptionList(items: [])
        }

        func submitDecision(messageID: String, decision: ReviewDecision, notes: String?) async throws -> Message {
            throw OperatorReviewError.invalidResponse
        }

        func submitTranscription(
            messageID: String,
            text: String,
            language: String?,
            model: String?
        ) async throws -> Transcription {
            throw OperatorReviewError.invalidResponse
        }

        func submitTranslation(
            messageID: String,
            translatedText: String,
            translatedLanguage: String?
        ) async throws -> Transcription {
            throw OperatorReviewError.invalidResponse
        }

        func submitModeration(
            messageID: String,
            transcriptionId: String?,
            inputText: String?,
            flagged: Bool,
            recommendation: String,
            maxScore: Double,
            reasonSummary: String?,
            model: String?
        ) async throws -> Moderation {
            throw OperatorReviewError.invalidResponse
        }
    }

    /// One message per state the queue distinguishes:
    /// - `untranscribed` — reviewable, no transcription row
    /// - `failed-transcript` — reviewable, newest transcription attempt failed
    /// - `untranslated` — transcribed, never translated
    /// - `failed-translation` — transcribed, translation attempt failed
    /// - `ready` — transcribed and translated, waiting only on a decision
    /// - `silent` — succeeded transcription with no speech; decidable as-is
    /// - `approved` — already decided
    private static let seed = """
    {"items":[
      {"id":"untranscribed","status":"pending","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/a.flac","sha256":"a","durationMs":null},
       "latestTranscription":null,"latestModeration":null},

      {"id":"failed-transcript","status":"pending","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/b.flac","sha256":"b","durationMs":null},
       "latestTranscription":{"id":"tb","messageId":"failed-transcript","provider":"mac_app",
         "model":null,"status":"failed","text":null,"language":null,"durationMs":null,
         "latencyMs":null,"error":"upstream exploded","requestedById":null,
         "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
         "translationStatus":null,"translatedText":null,"translatedLanguage":null,
         "translationProvider":null,"translationModel":null,"translationError":null,
         "translationLatencyMs":null,"translationCompletedAt":null},
       "latestModeration":null},

      {"id":"untranslated","status":"pending","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/c.flac","sha256":"c","durationMs":null},
       "latestTranscription":{"id":"tc","messageId":"untranslated","provider":"mac_app",
         "model":null,"status":"succeeded","text":"hola","language":"es","durationMs":null,
         "latencyMs":null,"error":null,"requestedById":null,
         "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
         "translationStatus":null,"translatedText":null,"translatedLanguage":null,
         "translationProvider":null,"translationModel":null,"translationError":null,
         "translationLatencyMs":null,"translationCompletedAt":null},
       "latestModeration":null},

      {"id":"failed-translation","status":"pending","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/d.flac","sha256":"d","durationMs":null},
       "latestTranscription":{"id":"td","messageId":"failed-translation","provider":"mac_app",
         "model":null,"status":"succeeded","text":"bonjour","language":"fr","durationMs":null,
         "latencyMs":null,"error":null,"requestedById":null,
         "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
         "translationStatus":"failed","translatedText":null,"translatedLanguage":null,
         "translationProvider":"mac_app","translationModel":null,
         "translationError":"model timed out",
         "translationLatencyMs":null,"translationCompletedAt":null},
       "latestModeration":null},

      {"id":"ready","status":"received","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/e.flac","sha256":"e","durationMs":null},
       "latestTranscription":{"id":"te","messageId":"ready","provider":"mac_app",
         "model":null,"status":"succeeded","text":"guten tag","language":"de","durationMs":null,
         "latencyMs":null,"error":null,"requestedById":null,
         "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
         "translationStatus":"succeeded","translatedText":"good day","translatedLanguage":"en",
         "translationProvider":"mac_app","translationModel":null,"translationError":null,
         "translationLatencyMs":null,"translationCompletedAt":null},
       "latestModeration":{"id":"me","messageId":"ready","transcriptionId":"te",
         "provider":"openai","model":null,"status":"succeeded","flagged":false,
         "recommendation":"approve","maxScore":0.01,"categories":null,
         "reasonSummary":"looks fine","latencyMs":null,"error":null,
         "createdAt":"2026-01-02T03:04:09Z","completedAt":null}},

      {"id":"silent","status":"pending","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/f.flac","sha256":"f","durationMs":null},
       "latestTranscription":{"id":"tf","messageId":"silent","provider":"mac_app",
         "model":null,"status":"succeeded","text":"   ","language":null,"durationMs":null,
         "latencyMs":null,"error":null,"requestedById":null,
         "createdAt":"2026-01-02T03:04:07Z","completedAt":null,
         "translationStatus":null,"translatedText":null,"translatedLanguage":null,
         "translationProvider":null,"translationModel":null,"translationError":null,
         "translationLatencyMs":null,"translationCompletedAt":null},
       "latestModeration":null},

      {"id":"approved","status":"approved","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/g.flac","sha256":"g","durationMs":null},
       "latestTranscription":null,"latestModeration":null}
    ]}
    """

    @MainActor
    private func loadedStore() async -> ReviewStore {
        let store = ReviewStore(client: SeededClient(seed: Self.seed), pollInterval: .seconds(3600))
        await store.refresh()
        return store
    }

    @Test("each work filter holds the messages waiting on that step")
    @MainActor
    func partitionsByNextStep() async {
        let store = await loadedStore()

        #expect(store.messages(for: .transcribe).map(\.id) == ["untranscribed", "failed-transcript"])
        #expect(store.messages(for: .translate).map(\.id) == ["untranslated", "failed-translation"])
        #expect(store.messages(for: .decide).map(\.id) == ["ready", "silent"])
        #expect(store.messages(for: .all).count == 7)
    }

    @Test("no message appears in more than one work filter")
    @MainActor
    func filtersDoNotOverlap() async {
        let store = await loadedStore()
        let work: [ReviewStore.Filter] = [.transcribe, .translate, .decide]
        let ids = work.flatMap { store.messages(for: $0).map(\.id) }

        #expect(Set(ids).count == ids.count)
        // And they exactly tile the "needs you" list — that tab is the union.
        #expect(Set(ids) == Set(store.messages(for: .needsAttention).map(\.id)))
    }

    @Test("needs-attention excludes decided messages")
    @MainActor
    func excludesDecided() async {
        let store = await loadedStore()
        let ids = store.messages(for: .needsAttention).map(\.id)

        #expect(!ids.contains("approved"))
        #expect(ids.count == 6)
        #expect(store.messages(for: .all).map(\.id).contains("approved"))
    }

    @Test("counts match the filtered lists, and All carries no badge")
    @MainActor
    func countsMatch() async {
        let store = await loadedStore()

        #expect(store.count(for: .needsAttention) == 6)
        #expect(store.count(for: .transcribe) == 2)
        #expect(store.count(for: .translate) == 2)
        #expect(store.count(for: .decide) == 2)
        #expect(store.count(for: .all) == nil)
    }

    @Test("a silent recording skips straight to a decision")
    @MainActor
    func silentIsDecidable() async {
        let store = await loadedStore()
        let silent = store.message(id: "silent")

        #expect(silent?.nextStep == .decision)
        #expect(silent?.transcriptionIsSilent == true)
    }

    @Test("a failed translation still needs translating, but reports the failure")
    @MainActor
    func failedTranslationIsDistinct() async {
        let store = await loadedStore()
        let failed = store.message(id: "failed-translation")

        #expect(failed?.nextStep == .translation)
        #expect(failed?.translationFailed == true)
        #expect(failed?.latestTranscription?.translationError == "model timed out")
        #expect(store.translationFailures.map(\.id) == ["failed-translation"])

        // A message that was simply never translated must not be confused with
        // one whose translation failed: same step, different explanation.
        let untranslated = store.message(id: "untranslated")
        #expect(untranslated?.nextStep == .translation)
        #expect(untranslated?.translationFailed == false)
    }

    @Test("preview text prefers the English translation over the source")
    @MainActor
    func previewPrefersTranslation() async {
        let store = await loadedStore()

        #expect(store.message(id: "ready")?.previewText == "good day")
        #expect(store.message(id: "untranslated")?.previewText == "hola")
        #expect(store.message(id: "untranscribed")?.previewText == nil)
        #expect(store.message(id: "silent")?.previewText == nil)
    }

    @Test("message(id:) tracks the store rather than a captured copy")
    @MainActor
    func looksMessagesUpByID() async {
        let store = await loadedStore()

        #expect(store.message(id: "ready")?.status == .received)
        #expect(store.message(id: "nope") == nil)
    }
}
