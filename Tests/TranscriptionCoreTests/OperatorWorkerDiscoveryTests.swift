import Foundation
import Logging
import Testing
import TranscriptionOperator
import TranscriptionShared

/// Covers the app-initiated transcription path: the Operator no longer
/// broadcasts `work` envelopes for new uploads, so the worker discovers
/// messages itself and posts results unsolicited.
@Suite("OperatorWorker discovery")
struct OperatorWorkerDiscoveryTests {
    actor DiscoveryClient: OperatorClient {
        var pages: [OperatorWorkListPage]
        var inputs: [String: OperatorWorkInput] = [:]
        var pushCalls: [PushCall] = []
        var listCalls: [OperatorWorkNeeds] = []
        var listError: (any Error)?

        init(pages: [OperatorWorkListPage] = []) {
            self.pages = pages
        }

        func setInput(_ input: OperatorWorkInput, for id: String) { inputs[id] = input }
        func setListError(_ error: any Error) { listError = error }
        func calls() -> [OperatorWorkNeeds] { listCalls }
        func pushes() -> [PushCall] { pushCalls }

        nonisolated func listWork(
            needs: OperatorWorkNeeds,
            limit: Int,
            cursor: String?
        ) async throws -> OperatorWorkListPage {
            try await self.nextPage(needs: needs)
        }

        func nextPage(needs: OperatorWorkNeeds) throws -> OperatorWorkListPage {
            listCalls.append(needs)
            if let listError { throw listError }
            guard !pages.isEmpty else { return OperatorWorkListPage(items: []) }
            return pages.removeFirst()
        }

        nonisolated func fetchWorkInput(messageID: String) async throws -> OperatorWorkInput {
            try await self.scriptedInput(messageID: messageID)
        }

        func scriptedInput(messageID: String) throws -> OperatorWorkInput {
            guard let input = inputs[messageID] else {
                throw OperatorClientError.malformedResponse("missing scripted input")
            }
            return input
        }

        nonisolated func pushResult(
            messageID: String,
            transcriptionId: String?,
            result: OperatorJobResult
        ) async throws {
            await self.record(messageID: messageID, transcriptionId: transcriptionId, result: result)
        }

        func record(messageID: String, transcriptionId: String?, result: OperatorJobResult) {
            pushCalls.append(.init(messageID: messageID, transcriptionID: transcriptionId, result: result))
        }
    }

    /// A channel that connects but never yields a `work` envelope on its own —
    /// exactly the new Operator behaviour for a freshly landed upload. Envelopes
    /// pushed before `connect()` are buffered so tests can't race the loop.
    actor SilentChannel: OperatorWorkChannel {
        var continuation: AsyncStream<OperatorWorkEnvelope>.Continuation?
        var pending: [OperatorWorkEnvelope] = []

        nonisolated func connect() async throws -> AsyncStream<OperatorWorkEnvelope> {
            await self.openStream()
        }

        func openStream() -> AsyncStream<OperatorWorkEnvelope> {
            let pair = AsyncStream<OperatorWorkEnvelope>.makeStream(of: OperatorWorkEnvelope.self)
            continuation = pair.continuation
            for envelope in pending { pair.continuation.yield(envelope) }
            pending.removeAll()
            return pair.stream
        }

        func yield(_ envelope: OperatorWorkEnvelope) {
            if let continuation {
                continuation.yield(envelope)
            } else {
                pending.append(envelope)
            }
        }

        nonisolated func disconnect() async { await self.close() }
        func close() {
            continuation?.finish()
            continuation = nil
        }
    }

    actor RecordingDispatcher: OperatorJobDispatcher {
        var jobs: [OperatorJob] = []
        var result: OperatorJobResult = .transcription(text: "bonjour", language: "fr", model: nil)

        func setResult(_ value: OperatorJobResult) { result = value }
        func recorded() -> [OperatorJob] { jobs }

        nonisolated func execute(job: OperatorJob) async throws -> OperatorJobResult {
            await self.run(job: job)
        }

        func run(job: OperatorJob) -> OperatorJobResult {
            jobs.append(job)
            return result
        }
    }

    private func audioInput(id: String, transcriptionID: String? = nil) -> OperatorWorkInput {
        OperatorWorkInput(
            id: id,
            status: "pending",
            audio: .init(url: "https://example.invalid/audio.flac", sha256: String(repeating: "a", count: 64)),
            transcription: transcriptionID.map { .init(id: $0, text: "bonjour", language: "fr") }
        )
    }

    private func makeWorker(
        client: any OperatorClient,
        dispatcher: any OperatorJobDispatcher,
        channel: any OperatorWorkChannel,
        kinds: Set<OperatorJob.Kind> = Set(OperatorJob.Kind.allCases)
    ) -> OperatorWorker {
        OperatorWorker(
            client: client,
            dispatcher: dispatcher,
            workChannel: channel,
            reconnectBaseSeconds: 1,
            enabledKinds: kinds,
            logger: Logger(label: "test")
        )
    }

    @Test func discoveryTranscribesWithoutAnyWorkEnvelope() async throws {
        let client = DiscoveryClient(pages: [
            OperatorWorkListPage(items: [OperatorWorkListItem(id: "m1", status: "pending")])
        ])
        await client.setInput(audioInput(id: "m1"), for: "m1")
        let dispatcher = RecordingDispatcher()
        let worker = makeWorker(client: client, dispatcher: dispatcher, channel: SilentChannel())

        await worker.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await worker.stop()

        let jobs = await dispatcher.recorded()
        #expect(jobs.map(\.kind) == [.transcription])
        let pushes = await client.pushes()
        #expect(pushes.count == 1)
        #expect(pushes.first?.messageID == "m1")
        // Unsolicited: no pending transcription row exists to update.
        #expect(pushes.first?.transcriptionID == nil)
        let needs = await client.calls()
        #expect(needs.allSatisfy { $0 == .transcription })

        let status = await worker.currentStatus()
        #expect(status.lastDiscoveredCount == 1)
        #expect(status.lastDiscoveryAt != nil)
    }

    @Test func discoverySkipsMessagesThatAlreadyHaveATranscription() async throws {
        let client = DiscoveryClient(pages: [
            OperatorWorkListPage(items: [
                OperatorWorkListItem(id: "done", status: "pending", latestTranscriptionStatus: "succeeded"),
                OperatorWorkListItem(id: "todo", status: "received", latestTranscriptionStatus: "failed")
            ])
        ])
        await client.setInput(audioInput(id: "todo"), for: "todo")
        let dispatcher = RecordingDispatcher()
        let worker = makeWorker(client: client, dispatcher: dispatcher, channel: SilentChannel())

        await worker.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await worker.stop()

        let jobs = await dispatcher.recorded()
        #expect(jobs.map(\.id) == ["todo"])
    }

    @Test func manualRerunTranscribesAnAlreadyTranscribedMessage() async throws {
        let client = DiscoveryClient()
        await client.setInput(audioInput(id: "m9", transcriptionID: "tr-old"), for: "m9")
        let dispatcher = RecordingDispatcher()
        let worker = makeWorker(client: client, dispatcher: dispatcher, channel: SilentChannel())

        await worker.start()
        let accepted = await worker.requestTranscription(messageID: "m9")
        #expect(accepted)
        try await Task.sleep(nanoseconds: 300_000_000)
        await worker.stop()

        let jobs = await dispatcher.recorded()
        #expect(jobs.map(\.kind) == [.transcription])
        let pushes = await client.pushes()
        #expect(pushes.count == 1)
        // A re-run creates a new succeeded row rather than updating `tr-old`.
        #expect(pushes.first?.transcriptionID == nil)
    }

    @Test func manualRerunIsRejectedWhenTheWorkerIsNotRunning() async throws {
        let worker = makeWorker(
            client: DiscoveryClient(),
            dispatcher: RecordingDispatcher(),
            channel: SilentChannel()
        )
        let accepted = await worker.requestTranscription(messageID: "m1")
        #expect(!accepted)
    }

    @Test func envelopeAndDiscoveryForTheSameMessageRunOnce() async throws {
        let client = DiscoveryClient(pages: [
            OperatorWorkListPage(items: [OperatorWorkListItem(id: "dup", status: "pending")])
        ])
        await client.setInput(audioInput(id: "dup"), for: "dup")
        let dispatcher = RecordingDispatcher()
        let channel = SilentChannel()
        // Buffered before the worker starts, so the envelope is guaranteed to be
        // delivered the moment the socket loop connects — racing the discovery
        // pass for the same message, which is exactly what's under test.
        await channel.yield(.init(messageId: "dup", needs: [.transcription]))
        let worker = makeWorker(client: client, dispatcher: dispatcher, channel: channel)

        await worker.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await worker.stop()

        let jobs = await dispatcher.recorded()
        #expect(jobs.count == 1)
    }

    @Test func aTranslationEnvelopeStillRunsAlongsideDiscovery() async throws {
        let client = DiscoveryClient(pages: [
            OperatorWorkListPage(items: [OperatorWorkListItem(id: "m1", status: "pending")])
        ])
        await client.setInput(audioInput(id: "m1"), for: "m1")
        await client.setInput(audioInput(id: "m2", transcriptionID: "tr-m2"), for: "m2")
        let dispatcher = RecordingDispatcher()
        await dispatcher.setResult(
            .translation(translatedText: "hello", sourceLanguage: "fr", targetLanguage: "en", model: nil)
        )
        let channel = SilentChannel()
        await channel.yield(.init(messageId: "m2", needs: [.translation]))
        let worker = makeWorker(client: client, dispatcher: dispatcher, channel: channel)

        await worker.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await worker.stop()

        let kinds = Set(await dispatcher.recorded().map(\.kind))
        #expect(kinds == [.transcription, .translation])
        // Translation results still reference the fetched transcription row.
        let pushes = await client.pushes()
        let translation = pushes.first { $0.messageID == "m2" }
        #expect(translation?.transcriptionID == "tr-m2")
    }

    @Test func discoveryDoesNotRunWhenTranscriptionIsDisabled() async throws {
        let client = DiscoveryClient(pages: [
            OperatorWorkListPage(items: [OperatorWorkListItem(id: "m1", status: "pending")])
        ])
        await client.setInput(audioInput(id: "m1"), for: "m1")
        let dispatcher = RecordingDispatcher()
        let worker = makeWorker(
            client: client,
            dispatcher: dispatcher,
            channel: SilentChannel(),
            kinds: [.translation, .moderation]
        )

        await worker.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await worker.stop()

        let calls = await client.calls()
        #expect(calls.isEmpty)
        let jobs = await dispatcher.recorded()
        #expect(jobs.isEmpty)
    }

    @Test func discoveryFailureIsRecordedWithoutDisturbingTheSocketBackoff() async throws {
        let client = DiscoveryClient()
        await client.setListError(OperatorClientError.http(404))
        let dispatcher = RecordingDispatcher()
        let worker = makeWorker(client: client, dispatcher: dispatcher, channel: SilentChannel())

        await worker.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        let status = await worker.currentStatus()
        await worker.stop()

        #expect(status.lastErrorCode == "operator_http_404")
        #expect(status.consecutiveFailures == 0)
        #expect(status.lastDiscoveryAt == nil)
    }

    @Test func discoveryFollowsPaginationCursors() async throws {
        let client = DiscoveryClient(pages: [
            OperatorWorkListPage(items: [OperatorWorkListItem(id: "p1", status: "pending")], nextCursor: "c1"),
            OperatorWorkListPage(items: [OperatorWorkListItem(id: "p2", status: "pending")])
        ])
        await client.setInput(audioInput(id: "p1"), for: "p1")
        await client.setInput(audioInput(id: "p2"), for: "p2")
        let dispatcher = RecordingDispatcher()
        let worker = makeWorker(client: client, dispatcher: dispatcher, channel: SilentChannel())

        await worker.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        await worker.stop()

        let ids = await dispatcher.recorded().map(\.id).sorted()
        #expect(ids == ["p1", "p2"])
    }
}

@Suite("Operator work list decoding")
struct OperatorWorkListDecodingTests {
    @Test func decodesTheProposedShape() throws {
        let json = Data("""
        {
          "items": [
            {
              "id": "m1",
              "status": "pending",
              "receivedAt": "2026-07-29T04:12:49.000Z",
              "durationMs": 4200,
              "latestTranscriptionStatus": "succeeded"
            }
          ],
          "nextCursor": "abc"
        }
        """.utf8)
        let page = try JSONDecoder().decode(OperatorWorkListPage.self, from: json)
        #expect(page.items.count == 1)
        #expect(page.nextCursor == "abc")
        let item = try #require(page.items.first)
        #expect(item.id == "m1")
        #expect(item.status == "pending")
        #expect(item.durationMs == 4200)
        #expect(item.receivedAt != nil)
        #expect(item.hasSucceededTranscription)
    }

    @Test func toleratesMissingAndUnknownFields() throws {
        let json = Data("""
        { "items": [ { "id": "m2", "status": "received" }, { "status": "pending" } ] }
        """.utf8)
        let page = try JSONDecoder().decode(OperatorWorkListPage.self, from: json)
        // The entry with no id is dropped; historical `received` still decodes.
        #expect(page.items.map(\.id) == ["m2"])
        #expect(page.nextCursor == nil)
        #expect(page.items[0].hasSucceededTranscription == false)
        #expect(page.items[0].receivedAt == nil)
    }

    @Test func rejectsAPageWithoutItems() {
        let json = Data(#"{ "nextCursor": "abc" }"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(OperatorWorkListPage.self, from: json)
        }
    }

    @Test func rejectsAMalformedCursor() {
        let json = Data(#"{ "items": [], "nextCursor": 12 }"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(OperatorWorkListPage.self, from: json)
        }
    }

    @Test func decodesTimestampsWithoutFractionalSeconds() throws {
        let json = Data("""
        { "items": [ { "id": "m3", "status": "pending", "receivedAt": "2026-07-29T04:12:49Z" } ] }
        """.utf8)
        let page = try JSONDecoder().decode(OperatorWorkListPage.self, from: json)
        #expect(page.items.first?.receivedAt != nil)
    }
}
