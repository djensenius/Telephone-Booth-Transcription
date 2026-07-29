//
//  ReviewTranscriptionQueueTests.swift
//  TranscriptionReviewTests
//
//  Covers the transcription-state surface the Review queue gained once the
//  Operator stopped gating a message on its transcription: reviewable messages
//  with no transcript, silent recordings, and deliberate re-runs.
//

import Foundation
import Testing
@testable import TranscriptionReview

@Suite("Review transcription queue")
struct ReviewTranscriptionQueueTests {
    private final class QueueClient: OperatorReviewClient, @unchecked Sendable {
        var seed: String

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

        func submitTranslation(
            messageID: String,
            translatedText: String,
            translatedLanguage: String?
        ) async throws -> Transcription {
            throw OperatorReviewError.invalidResponse
        }
    }

    private final class StubRerunner: TranscriptionRerunRequesting, @unchecked Sendable {
        private let lock = NSLock()
        private var _requested: [String] = []
        var accepts = true

        var requested: [String] {
            lock.lock(); defer { lock.unlock() }
            return _requested
        }

        func requestTranscription(messageID: String) async -> Bool {
            lock.withLock { _requested.append(messageID) }
            return accepts
        }
    }

    /// `untranscribed` is pending with no transcription row, `silent` succeeded
    /// with empty text, `spoken` succeeded with text, `done` is approved.
    private static let seed = """
    {"items":[
      {"id":"untranscribed","status":"pending","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":"2026-01-02T03:04:06Z",
       "audio":{"url":"https://e.com/u.flac","sha256":"u","durationMs":null},
       "latestTranscription":null,"latestModeration":null},
      {"id":"silent","status":"pending","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/s.flac","sha256":"s","durationMs":null},
       "latestTranscription":{"id":"ts","messageId":"silent","provider":"mac_app","model":null,
         "status":"succeeded","text":"  ","language":null,"durationMs":null,"latencyMs":null,
         "error":null,"requestedById":null,"createdAt":"2026-01-02T03:04:07Z","completedAt":null,
         "translationStatus":null,"translatedText":null,"translatedLanguage":null,
         "translationProvider":null,"translationModel":null,"translationError":null,
         "translationLatencyMs":null,"translationCompletedAt":null},
       "latestModeration":null},
      {"id":"spoken","status":"received","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/t.flac","sha256":"t","durationMs":null},
       "latestTranscription":{"id":"tt","messageId":"spoken","provider":"mac_app","model":null,
         "status":"succeeded","text":"hola","language":"es","durationMs":null,"latencyMs":null,
         "error":null,"requestedById":null,"createdAt":"2026-01-02T03:04:07Z","completedAt":null,
         "translationStatus":null,"translatedText":null,"translatedLanguage":null,
         "translationProvider":null,"translationModel":null,"translationError":null,
         "translationLatencyMs":null,"translationCompletedAt":null},
       "latestModeration":null},
      {"id":"done","status":"approved","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
       "audio":{"url":"https://e.com/d.flac","sha256":"d","durationMs":null},
       "latestTranscription":null,"latestModeration":null}
    ]}
    """

    /// Same page, but `untranscribed` now carries a succeeded transcript.
    private static let seedAfterTranscription = """
    {"items":[
      {"id":"untranscribed","status":"pending","questionId":null,"notes":null,
       "createdAt":"2026-01-02T03:04:05Z","receivedAt":"2026-01-02T03:04:06Z",
       "audio":{"url":"https://e.com/u.flac","sha256":"u","durationMs":null},
       "latestTranscription":{"id":"tu","messageId":"untranscribed","provider":"mac_app","model":null,
         "status":"succeeded","text":"bonjour","language":"fr","durationMs":null,"latencyMs":null,
         "error":null,"requestedById":null,"createdAt":"2026-01-02T03:05:07Z","completedAt":null,
         "translationStatus":null,"translatedText":null,"translatedLanguage":null,
         "translationProvider":null,"translationModel":null,"translationError":null,
         "translationLatencyMs":null,"translationCompletedAt":null},
       "latestModeration":null}
    ]}
    """

    @Test("reviewable messages with no succeeded transcription form their own bucket")
    @MainActor
    func awaitingTranscriptionBucket() async {
        let store = ReviewStore(client: QueueClient(seed: Self.seed), pollInterval: .seconds(1))
        await store.refresh()

        #expect(store.awaitingTranscription.map(\.id) == ["untranscribed"])
        #expect(store.alreadyTranscribed.map(\.id) == ["silent", "spoken"])
    }

    @Test("a silent recording is distinguishable from an untranscribed one")
    @MainActor
    func silentIsNotUntranscribed() async {
        let store = ReviewStore(client: QueueClient(seed: Self.seed), pollInterval: .seconds(1))
        await store.refresh()

        let silent = store.messages.first { $0.id == "silent" }
        #expect(silent?.transcriptionIsSilent == true)
        #expect(silent?.needsTranscription == false)

        let untranscribed = store.messages.first { $0.id == "untranscribed" }
        #expect(untranscribed?.transcriptionIsSilent == false)
        #expect(untranscribed?.needsTranscription == true)
    }

    @Test("requesting transcription marks the message queued until a newer transcript lands")
    @MainActor
    func requestTranscriptionQueuesAndClears() async {
        let client = QueueClient(seed: Self.seed)
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        let rerunner = StubRerunner()
        store.transcriptionRerunner = rerunner
        await store.refresh()

        let target = try! #require(store.awaitingTranscription.first)
        await store.requestTranscription(target)

        #expect(rerunner.requested == ["untranscribed"])
        #expect(store.isTranscriptionQueued("untranscribed"))
        #expect(store.actionError == nil)
        #expect(store.isActing(on: "untranscribed") == false)

        client.seed = Self.seedAfterTranscription
        await store.refresh()
        #expect(store.isTranscriptionQueued("untranscribed") == false)
        #expect(store.awaitingTranscription.isEmpty)
    }

    @Test("a re-run of an already-transcribed message is accepted")
    @MainActor
    func rerunOfTranscribedMessage() async {
        let store = ReviewStore(client: QueueClient(seed: Self.seed), pollInterval: .seconds(1))
        let rerunner = StubRerunner()
        store.transcriptionRerunner = rerunner
        await store.refresh()

        let target = try! #require(store.alreadyTranscribed.first { $0.id == "spoken" })
        await store.requestTranscription(target)

        #expect(rerunner.requested == ["spoken"])
        #expect(store.isTranscriptionQueued("spoken"))
        #expect(store.actionError == nil)
    }

    @Test("a rejected request surfaces an actionError and stays unqueued")
    @MainActor
    func rejectedRequestSurfacesError() async {
        let store = ReviewStore(client: QueueClient(seed: Self.seed), pollInterval: .seconds(1))
        let rerunner = StubRerunner()
        rerunner.accepts = false
        store.transcriptionRerunner = rerunner
        await store.refresh()

        let target = try! #require(store.awaitingTranscription.first)
        await store.requestTranscription(target)

        #expect(store.actionError != nil)
        #expect(store.isTranscriptionQueued("untranscribed") == false)
    }

    @Test("without a worker the request is refused rather than silently dropped")
    @MainActor
    func noRerunnerSurfacesError() async {
        let store = ReviewStore(client: QueueClient(seed: Self.seed), pollInterval: .seconds(1))
        await store.refresh()

        let target = try! #require(store.awaitingTranscription.first)
        await store.requestTranscription(target)

        #expect(store.actionError != nil)
        #expect(store.isTranscriptionQueued("untranscribed") == false)
    }
}
