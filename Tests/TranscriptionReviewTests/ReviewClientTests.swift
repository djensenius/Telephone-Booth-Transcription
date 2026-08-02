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
        let ok = await store.submitTranslation(target, text: "hello", language: "en")

        #expect(ok)
        #expect(store.awaitingTranslation.isEmpty)
        #expect(store.actionError == nil)
    }

    /// The caller discards its local draft on success, so a failure has to be
    /// distinguishable: otherwise a transient error throws away the translation
    /// the operator was trying to submit.
    @Test("a failed translation submit reports failure and leaves the queue alone")
    @MainActor
    func translationFailureIsReported() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingTranslation.first)

        client.translationResult = .failure(OperatorReviewError.invalidResponse)
        let ok = await store.submitTranslation(target, text: "hello", language: "en")

        #expect(ok == false)
        #expect(store.awaitingTranslation.isEmpty == false)
        #expect(store.actionError != nil)
    }

    @Test("submitTranscription posts the transcript and folds the row back in")
    @MainActor
    func transcriptionUpdatesState() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingModeration.first)

        client.transcriptionResult = .success(target.latestTranscription!.retranscribed("bonjour"))
        let ok = await store.submitTranscription(
            target, text: "bonjour", language: "fr", model: "apple-speech-analyzer"
        )

        #expect(ok)
        #expect(store.actionError == nil)
        #expect(store.isActing(on: target.id) == false)
        #expect(client.lastTranscriptionSubmission?.text == "bonjour")
        #expect(client.lastTranscriptionSubmission?.language == "fr")
        #expect(client.lastTranscriptionSubmission?.model == "apple-speech-analyzer")
        #expect(store.messages.first(where: { $0.id == target.id })?.latestTranscription?.text == "bonjour")
        // The Operator re-runs translation and moderation for the new row, so
        // the queue is pulled rather than left up to a poll interval stale.
        #expect(client.fetchCount == 2)
    }

    @Test("a failed transcript submit surfaces an actionError and returns false")
    @MainActor
    func transcriptionFailureSurfacesError() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingModeration.first)

        client.transcriptionResult = .failure(.api(status: 404, code: "not_found"))
        let ok = await store.submitTranscription(target, text: "bonjour", language: nil, model: nil)

        #expect(ok == false)
        #expect(store.actionError != nil)
        #expect(store.isActing(on: target.id) == false)
    }

    @Test("submitModeration folds the returned verdict into latestModeration")
    @MainActor
    func moderationUpdatesState() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingModeration.first)
        #expect(target.latestModeration == nil)

        client.moderationResult = .success(
            Moderation(
                id: "mod", messageId: target.id, transcriptionId: target.latestTranscription?.id,
                provider: .macApp, model: "apple-foundation-models", status: .succeeded,
                flagged: true, recommendation: .reject, maxScore: 0.82, categories: nil,
                reasonSummary: nil, latencyMs: 140, error: nil,
                createdAt: target.createdAt, completedAt: target.createdAt
            )
        )
        let ok = await store.submitModeration(
            target, flagged: true, recommendation: "reject", maxScore: 0.82,
            model: "apple-foundation-models"
        )

        #expect(ok)
        #expect(store.actionError == nil)
        #expect(store.isActing(on: target.id) == false)
        #expect(client.lastModerationSubmission?.transcriptionId == target.latestTranscription?.id)
        #expect(client.lastModerationSubmission?.recommendation == "reject")
        #expect(client.lastModerationSubmission?.maxScore == 0.82)
        let updated = store.messages.first(where: { $0.id == target.id })
        #expect(updated?.latestModeration?.recommendation == .reject)
        #expect(updated?.latestModeration?.flagged == true)
    }

    @Test("a failed moderation submit surfaces an actionError and returns false")
    @MainActor
    func moderationFailureSurfacesError() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingModeration.first)

        client.moderationResult = .failure(.api(status: 404, code: "not_found"))
        let ok = await store.submitModeration(
            target, flagged: false, recommendation: "approve", maxScore: 0.1, model: nil
        )

        #expect(ok == false)
        #expect(store.actionError != nil)
        #expect(store.isActing(on: target.id) == false)
        #expect(store.messages.first(where: { $0.id == target.id })?.latestModeration == nil)
    }

    @Test("a verdict tied to a superseded transcription is not folded in")
    @MainActor
    func moderationForStaleTranscriptionIsDropped() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingModeration.first)

        client.moderationResult = .success(
            Moderation(
                id: "mod", messageId: target.id, transcriptionId: "an-older-transcription",
                provider: .macApp, model: "apple-foundation-models", status: .succeeded,
                flagged: true, recommendation: .reject, maxScore: 0.82, categories: nil,
                reasonSummary: nil, latencyMs: 140, error: nil,
                createdAt: target.createdAt, completedAt: target.createdAt
            )
        )
        let ok = await store.submitModeration(
            target, flagged: true, recommendation: "reject", maxScore: 0.82,
            model: "apple-foundation-models"
        )

        // The submission itself succeeded, so the caller still clears its local
        // verdict — but the verdict describes text this message no longer has.
        #expect(ok)
        #expect(store.actionError == nil)
        #expect(store.messages.first(where: { $0.id == target.id })?.latestModeration == nil)
    }

    @Test("a slow submit does not displace a newer verdict")
    @MainActor
    func moderationDoesNotDisplaceNewerVerdict() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.awaitingModeration.first)
        let transcriptionId = target.latestTranscription?.id

        func verdict(_ id: String, _ recommendation: ModerationRecommendation, at date: Date) -> Moderation {
            Moderation(
                id: id, messageId: target.id, transcriptionId: transcriptionId,
                provider: .macApp, model: "apple-foundation-models", status: .succeeded,
                flagged: true, recommendation: recommendation, maxScore: 0.82, categories: nil,
                reasonSummary: nil, latencyMs: 140, error: nil,
                createdAt: date, completedAt: date
            )
        }

        // Stand in for a verdict another operator's poll already put on screen.
        let newer = Date(timeIntervalSince1970: 2_000)
        client.moderationResult = .success(verdict("newer", .reject, at: newer))
        _ = await store.submitModeration(
            target, flagged: true, recommendation: "reject", maxScore: 0.82,
            model: "apple-foundation-models"
        )
        #expect(store.messages.first(where: { $0.id == target.id })?
            .latestModeration?.id == "newer")

        // This one was computed first but came back last; it must not win.
        client.moderationResult = .success(
            verdict("older", .approve, at: Date(timeIntervalSince1970: 1_000))
        )
        let ok = await store.submitModeration(
            target, flagged: false, recommendation: "approve", maxScore: 0.1,
            model: "apple-foundation-models"
        )

        // Submitted successfully — the Operator has it, and it is the Operator's
        // job to order the rows — but the screen keeps the newer verdict.
        #expect(ok)
        #expect(store.actionError == nil)
        let shown = store.messages.first(where: { $0.id == target.id })?.latestModeration
        #expect(shown?.id == "newer")
        #expect(shown?.recommendation == .reject)
    }

    @Test("submitTranscriptAndTranslation posts the transcript, then the translation")
    @MainActor
    func combinedSubmitPostsBoth() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.messages.first)

        // The Operator attaches a translation to the row the transcript created,
        // so both responses have to come off the same transcription — otherwise
        // the fake would answer the second call with the superseded row.
        let submitted = target.latestTranscription!.retranscribed("bonjour")
        client.transcriptionResult = .success(submitted)
        client.translationResult = .success(submitted.translated("hello"))
        let ok = await store.submitTranscriptAndTranslation(
            target, transcript: "bonjour", language: "fr",
            model: "apple-speech-analyzer", translation: "hello"
        )

        #expect(ok)
        #expect(store.actionError == nil)
        #expect(store.isActing(on: target.id) == false)
        #expect(client.lastTranscriptionSubmission?.text == "bonjour")
        #expect(client.lastTranscriptionSubmission?.language == "fr")
        #expect(client.translationSubmissions == ["hello"])
        let final = store.messages.first(where: { $0.id == target.id })
        #expect(final?.latestTranscription?.text == "bonjour")
        #expect(final?.translationText == "hello")
    }

    /// The Operator attaches a translation to the message's latest transcription,
    /// so a transcript that never landed leaves nothing to translate — the
    /// second POST must not be attempted.
    @Test("a failed transcript skips the translation in the combined submit")
    @MainActor
    func combinedSubmitStopsWhenTranscriptFails() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.messages.first)

        client.transcriptionResult = .failure(.api(status: 404, code: "not_found"))
        let ok = await store.submitTranscriptAndTranslation(
            target, transcript: "bonjour", translation: "hello"
        )

        #expect(ok == false)
        #expect(store.actionError != nil)
        #expect(client.translationSubmissions.isEmpty)
    }

    /// The transcript already landed, so the caller must be told the whole
    /// action failed (to keep the drafts) while the queue reflects the
    /// transcript that did go through — leaving a plain translation retry.
    @Test("a failed translation in the combined submit still submitted the transcript")
    @MainActor
    func combinedSubmitKeepsTranscriptWhenTranslationFails() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.messages.first)

        client.transcriptionResult = .success(target.latestTranscription!.retranscribed("bonjour"))
        client.translationResult = .failure(OperatorReviewError.invalidResponse)
        let ok = await store.submitTranscriptAndTranslation(
            target, transcript: "bonjour", translation: "hello"
        )

        #expect(ok == false)
        #expect(store.actionError != nil)
        #expect(client.lastTranscriptionSubmission?.text == "bonjour")
        #expect(client.translationSubmissions == ["hello"])
        #expect(store.messages.first(where: { $0.id == target.id })?
            .latestTranscription?.text == "bonjour")
    }

    /// The translation route attaches to whatever transcription is latest, so a
    /// transcript that landed in the gap between the two writes would otherwise
    /// receive a translation of text it never held.
    @Test("a transcript superseded between the two writes blocks the translation")
    @MainActor
    func combinedSubmitStopsWhenTranscriptIsSuperseded() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.messages.first)

        // The Operator answers with a different transcript than the one posted:
        // something else landed first and this row is not what was submitted.
        client.transcriptionResult = .success(target.latestTranscription!.retranscribed("salut"))
        let ok = await store.submitTranscriptAndTranslation(
            target, transcript: "bonjour", translation: "hello"
        )

        #expect(ok == false)
        #expect(store.actionError != nil)
        #expect(client.translationSubmissions.isEmpty)
    }

    @Test("generated review owns its text until moderation finishes")
    @MainActor
    func generatedReviewRetainsTextWriteOwnership() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.messages.first)
        let gate = Gate()

        client.translationResult = .success(target.latestTranscription!.translated("hello"))
        client.moderationResult = .failure(.api(status: 500, code: "moderation_failed"))
        client.moderationGate = gate
        let task = Task {
            await store.submitGeneratedReview(
                target,
                transcript: nil,
                translation: "hello",
                flagged: false,
                recommendation: "approve"
            )
        }
        await gate.waitUntilEntered()

        #expect(store.isWritingText(for: target.id))
        await gate.open()
        #expect(await task.value == false)
        #expect(store.isWritingText(for: target.id) == false)
        #expect(store.messages.first(where: { $0.id == target.id })?.translationText == "hello")
    }

    @Test("replacing translated text clears a recommendation for the old text")
    @MainActor
    func translationReplacementClearsStaleModeration() async {
        let client = ActionClient()
        let store = ReviewStore(client: client, pollInterval: .seconds(1))
        await store.refresh()
        let target = try! #require(store.messages.first)
        client.moderationResult = .success(
            Moderation(
                id: "old", messageId: target.id, transcriptionId: target.latestTranscription?.id,
                provider: .macApp, model: nil, status: .succeeded, flagged: false,
                recommendation: .approve, maxScore: 0.1, categories: nil,
                reasonSummary: nil, latencyMs: nil, error: nil,
                createdAt: target.createdAt, completedAt: target.createdAt
            )
        )
        let moderationSaved = await store.submitModeration(
            target, flagged: false, recommendation: "approve"
        )
        #expect(moderationSaved)

        client.translationResult = .success(target.latestTranscription!.translated("hello"))
        let translationSaved = await store.submitTranslation(target, text: "hello")
        #expect(translationSaved)
        #expect(store.messages.first(where: { $0.id == target.id })?.latestModeration == nil)
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
        var transcriptionResult: Result<Transcription, OperatorReviewError> = .failure(.invalidResponse)
        var moderationResult: Result<Moderation, OperatorReviewError> = .failure(.invalidResponse)
        var moderationGate: Gate?
        private(set) var lastDecisionNotes: String?
        private(set) var lastTranscriptionSubmission: (text: String, language: String?, model: String?)?
        private(set) var lastModerationSubmission: (
            transcriptionId: String?, flagged: Bool, recommendation: String, maxScore: Double, model: String?
        )?
        private(set) var translationSubmissions: [String] = []
        private(set) var fetchCount = 0
        private var submittedTranscription: Transcription?

        func fetchTranscriptions(messageID: String) async throws -> TranscriptionList {
            TranscriptionList(items: [])
        }

        func fetchMessages(status: MessageStatus?, since: Date?, limit: Int) async throws -> MessageList {
            fetchCount += 1
            let list = try OperatorJSON.decoder.decode(MessageList.self, from: Data(ActionClient.seed.utf8))
            // Once a transcript has been accepted, the server hands the new row
            // back on every subsequent read — otherwise a refresh would look
            // like it reverted the submission.
            guard let submitted = submittedTranscription else { return list }
            return MessageList(items: list.items.map {
                $0.id == submitted.messageId ? $0.replacingLatestTranscription(submitted) : $0
            })
        }

        func submitDecision(
            messageID: String,
            decision: ReviewDecision,
            notes: String?
        ) async throws -> Message {
            lastDecisionNotes = notes
            return try decisionResult.get()
        }

        func submitTranscription(
            messageID: String,
            text: String,
            language: String?,
            model: String?
        ) async throws -> Transcription {
            lastTranscriptionSubmission = (text, language, model)
            let transcription = try transcriptionResult.get()
            submittedTranscription = transcription
            return transcription
        }

        func submitTranslation(
            messageID: String,
            translatedText: String,
            translatedLanguage: String?
        ) async throws -> Transcription {
            translationSubmissions.append(translatedText)
            let transcription = try translationResult.get()
            // Same contract as a transcript submission: once accepted, the
            // server hands the updated row back on every subsequent read.
            submittedTranscription = transcription
            return transcription
        }

        func submitModeration(
            messageID: String,
            transcriptionId: String?,
            flagged: Bool,
            recommendation: String,
            maxScore: Double,
            reasonSummary: String?,
            model: String?
        ) async throws -> Moderation {
            lastModerationSubmission = (transcriptionId, flagged, recommendation, maxScore, model)
            await moderationGate?.wait()
            return try moderationResult.get()
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

    private actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var entryContinuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private var hasEntered = false

        func wait() async {
            hasEntered = true
            entryContinuations.forEach { $0.resume() }
            entryContinuations.removeAll()
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func waitUntilEntered() async {
            if hasEntered { return }
            await withCheckedContinuation { entryContinuations.append($0) }
        }

        func open() {
            isOpen = true
            continuations.forEach { $0.resume() }
            continuations.removeAll()
        }
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
            flagged: Bool,
            recommendation: String,
            maxScore: Double,
            reasonSummary: String?,
            model: String?
        ) async throws -> Moderation {
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
            flagged: Bool,
            recommendation: String,
            maxScore: Double,
            reasonSummary: String?,
            model: String?
        ) async throws -> Moderation {
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
    func retranscribed(_ text: String) -> Transcription {
        Transcription(
            id: "t2", messageId: messageId, provider: .macApp, model: "apple-speech-analyzer",
            status: .succeeded, text: text, language: language, durationMs: durationMs,
            latencyMs: latencyMs, error: nil, requestedById: "op", createdAt: createdAt,
            completedAt: createdAt, translationStatus: nil, translatedText: nil,
            translatedLanguage: nil, translationProvider: nil, translationModel: nil,
            translationError: nil, translationLatencyMs: nil, translationCompletedAt: nil
        )
    }

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
