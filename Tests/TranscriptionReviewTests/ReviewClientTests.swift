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
