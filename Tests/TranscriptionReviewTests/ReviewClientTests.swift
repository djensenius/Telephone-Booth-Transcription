//
//  ReviewClientTests.swift
//  TranscriptionReviewTests
//

import Foundation
import Testing
@testable import TranscriptionReview

@Suite("Operator API config + client plumbing")
struct ReviewClientTests {
    @Test("url(forPath:) resolves against the base URL")
    func resolvesPaths() {
        let config = OperatorAPIConfig(baseURL: URL(string: "https://api.example.com")!)
        #expect(config.url(forPath: "/v1/messages").absoluteString
                == "https://api.example.com/v1/messages")
        #expect(config.url(forPath: "v1/messages/abc/transcriptions").absoluteString
                == "https://api.example.com/v1/messages/abc/transcriptions")
    }

    private struct NoTokenProvider: BearerTokenProviding {
        func authorizationHeader() async -> String? { nil }
    }

    @Test("fetch without a token throws unauthenticated")
    func fetchWithoutTokenThrows() async {
        let client = HTTPOperatorReviewClient(
            config: OperatorAPIConfig(baseURL: URL(string: "https://api.example.com")!),
            tokenProvider: NoTokenProvider()
        )
        await #expect(throws: OperatorReviewError.unauthenticated) {
            _ = try await client.fetchMessages(status: nil, since: nil, limit: 10)
        }
    }

    @Test("ReviewStore buckets messages by translation/moderation need")
    @MainActor
    func storeBuckets() async {
        let store = ReviewStore(client: StubClient(), pollInterval: .seconds(1))
        await store.refresh()
        #expect(store.state == .loaded)
        #expect(store.awaitingTranslation.count == 1)
        #expect(store.awaitingModeration.count == 1)
    }

    @Test("overlapping refreshes coalesce onto one fetch")
    @MainActor
    func coalescesRefreshes() async {
        let counting = CountingClient()
        let store = ReviewStore(client: counting, pollInterval: .seconds(1))
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)
        #expect(counting.callCount == 1)
        #expect(store.state == .loaded)
    }

    @Test("decide folds the updated message back into local state")
    @MainActor
    func decideUpdatesState() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingModeration.first)
        #expect(store.awaitingModeration.count == 1)

        client.decisionResult = .success(target.approved())
        await store.decide(target, .approve, notes: "ok")

        #expect(store.awaitingModeration.isEmpty)
        #expect(store.isActing(on: target.id) == false)
        #expect(store.actionError == nil)
        #expect(client.lastDecisionNotes == "ok")
    }

    @Test("submitTranslation clears the message from the translation bucket")
    @MainActor
    func translationUpdatesState() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingTranslation.first)

        client.translationResult = .success(target.latestTranscription!.translated("hello"))
        await store.submitTranslation(target, text: "hello", language: "en")

        #expect(store.awaitingTranslation.isEmpty)
        #expect(store.actionError == nil)
    }

    @Test("a failed decision surfaces an actionError and clears the pending flag")
    @MainActor
    func decideFailureSurfacesError() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingModeration.first)

        client.decisionResult = .failure(.api(status: 409, code: "message_not_decidable"))
        await store.decide(target, .approve)

        #expect(store.actionError != nil)
        #expect(store.isActing(on: target.id) == false)
        // Unchanged: still awaiting moderation.
        #expect(store.awaitingModeration.count == 1)
    }

    private final class ActionClient: OperatorReviewClient, @unchecked Sendable {
        var decisionResult: Result<Message, OperatorReviewError> = .failure(.invalidResponse)
        var translationResult: Result<Transcription, OperatorReviewError> = .failure(.invalidResponse)
        private(set) var lastDecisionNotes: String?

        func fetchTranscriptions(messageID: String) async throws -> TranscriptionList {
            TranscriptionList(items: [])
        }

        func fetchMessages(status: MessageStatus?, since: Date?, limit: Int) async throws -> MessageList {
            try OperatorJSON.decoder.decode(MessageList.self, from: Data(ActionClient.seed.utf8))
        }

        func submitDecision(
            messageID: String,
            decision: ReviewDecision,
            notes: String?
        ) async throws -> Message {
            lastDecisionNotes = notes
            return try decisionResult.get()
        }

        func submitTranslation(
            messageID: String,
            translatedText: String,
            translatedLanguage: String?
        ) async throws -> Transcription {
            try translationResult.get()
        }

        static let seed = """
        {"items":[
          {"id":"a","status":"received","questionId":null,"notes":null,
           "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
           "audio":{"url":"https://e.com/a.flac","sha256":"a","durationMs":null},
           "latestTranscription":{"id":"t","messageId":"a","provider":"openai","model":null,
             "status":"succeeded","text":"hola","language":"es","durationMs":null,"latencyMs":null,
             "error":null,"requestedById":null,"createdAt":"2026-01-02T03:04:07Z","completedAt":null,
             "translationStatus":null,"translatedText":null,"translatedLanguage":null,
             "translationProvider":null,"translationModel":null,"translationError":null,
             "translationLatencyMs":null,"translationCompletedAt":null},
           "latestModeration":null}
        ]}
        """
    }

    private final class CountingClient: OperatorReviewClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0
        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _callCount
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

        func fetchMessages(status: MessageStatus?, since: Date?, limit: Int) async throws -> MessageList {
            lock.withLock { _callCount += 1 }
            try? await Task.sleep(for: .milliseconds(20))
            return MessageList(items: [])
        }
    }

    private struct StubClient: OperatorReviewClient {
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

        func fetchMessages(status: MessageStatus?, since: Date?, limit: Int) async throws -> MessageList {
            let json = """
            {"items":[
              {"id":"a","status":"received","questionId":null,"notes":null,
               "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
               "audio":{"url":"https://e.com/a.flac","sha256":"a","durationMs":null},
               "latestTranscription":{"id":"t","messageId":"a","provider":"openai","model":null,
                 "status":"succeeded","text":"hola","language":"es","durationMs":null,"latencyMs":null,
                 "error":null,"requestedById":null,"createdAt":"2026-01-02T03:04:07Z","completedAt":null,
                 "translationStatus":null,"translatedText":null,"translatedLanguage":null,
                 "translationProvider":null,"translationModel":null,"translationError":null,
                 "translationLatencyMs":null,"translationCompletedAt":null},
               "latestModeration":null},
              {"id":"b","status":"approved","questionId":null,"notes":null,
               "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
               "audio":{"url":"https://e.com/b.flac","sha256":"b","durationMs":null},
               "latestTranscription":null,"latestModeration":null}
            ]}
            """
            return try OperatorJSON.decoder.decode(MessageList.self, from: Data(json.utf8))
        }
    }
}

private extension Message {
    func approved() -> Message {
        Message(
            id: id, status: .approved, questionId: questionId, notes: notes,
            createdAt: createdAt, receivedAt: receivedAt, audio: audio,
            latestTranscription: latestTranscription, latestModeration: latestModeration
        )
    }
}

private extension Transcription {
    func translated(_ text: String) -> Transcription {
        Transcription(
            id: id, messageId: messageId, provider: provider, model: model,
            status: status, text: self.text, language: language, durationMs: durationMs,
            latencyMs: latencyMs, error: error, requestedById: requestedById,
            createdAt: createdAt, completedAt: completedAt,
            translationStatus: .succeeded, translatedText: text, translatedLanguage: "en",
            translationProvider: nil, translationModel: nil, translationError: nil,
            translationLatencyMs: nil, translationCompletedAt: createdAt
        )
    }
}
