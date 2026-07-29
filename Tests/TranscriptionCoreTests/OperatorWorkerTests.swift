import Foundation
import Logging
import Testing
import TranscriptionOperator
import TranscriptionShared

struct PushCall: Sendable, Equatable {
    var messageID: String
    var transcriptionID: String?
    var result: OperatorJobResult
}

@Suite("OperatorWorker")
struct OperatorWorkerTests {
    actor FakeClient: OperatorClient {
        var inputs: [String: OperatorWorkInput] = [:]
        var fetchError: (any Error)?
        var pushCalls: [PushCall] = []
        var listPages: [OperatorWorkListPage] = []
        var listError: (any Error)?
        var listCalls: [OperatorWorkNeeds] = []

        func setInput(_ input: OperatorWorkInput, for id: String) { inputs[id] = input }
        func setFetchError(_ err: any Error) { fetchError = err }
        func setListPages(_ pages: [OperatorWorkListPage]) { listPages = pages }
        func setListError(_ err: any Error) { listError = err }

        nonisolated func listWork(
            needs: OperatorWorkNeeds,
            limit: Int,
            cursor: String?
        ) async throws -> OperatorWorkListPage {
            try await self.nextListPage(needs: needs)
        }

        func nextListPage(needs: OperatorWorkNeeds) throws -> OperatorWorkListPage {
            listCalls.append(needs)
            if let listError { throw listError }
            guard !listPages.isEmpty else { return OperatorWorkListPage(items: []) }
            return listPages.removeFirst()
        }

        nonisolated func fetchWorkInput(messageID: String) async throws -> OperatorWorkInput {
            try await self.fetchScriptedWorkInput(messageID: messageID)
        }

        func fetchScriptedWorkInput(messageID: String) async throws -> OperatorWorkInput {
            if let err = fetchError { fetchError = nil; throw err }
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
            await self.recordPush(messageID: messageID, transcriptionId: transcriptionId, result: result)
        }

        func recordPush(messageID: String, transcriptionId: String?, result: OperatorJobResult) {
            pushCalls.append(.init(messageID: messageID, transcriptionID: transcriptionId, result: result))
        }
    }

    actor FakeChannel: OperatorWorkChannel {
        var envelopes: [OperatorWorkEnvelope] = []
        var continuation: AsyncStream<OperatorWorkEnvelope>.Continuation?
        var connectError: (any Error)?

        func enqueue(_ envelope: OperatorWorkEnvelope) { envelopes.append(envelope) }
        func setConnectError(_ err: any Error) { connectError = err }

        nonisolated func connect() async throws -> AsyncStream<OperatorWorkEnvelope> {
            try await self.connectScriptedStream()
        }

        func connectScriptedStream() throws -> AsyncStream<OperatorWorkEnvelope> {
            if let err = connectError { connectError = nil; throw err }
            let pair = AsyncStream<OperatorWorkEnvelope>.makeStream(of: OperatorWorkEnvelope.self)
            continuation = pair.continuation
            for envelope in envelopes { pair.continuation.yield(envelope) }
            envelopes.removeAll()
            return pair.stream
        }

        nonisolated func disconnect() async { await self.disconnectScriptedStream() }

        func disconnectScriptedStream() {
            continuation?.finish()
            continuation = nil
        }
    }

    actor FakeDispatcher: OperatorJobDispatcher {
        var nextResult: OperatorJobResult?
        var nextError: (any Error)?
        var activeExecutions = 0
        var maxConcurrent = 0
        var executionLog: [(String, OperatorJob.Kind)] = []

        func setResult(_ result: OperatorJobResult) { nextResult = result }
        func setError(_ err: any Error) { nextError = err }

        nonisolated func execute(job: OperatorJob) async throws -> OperatorJobResult {
            try await self.executeScripted(job: job)
        }

        func executeScripted(job: OperatorJob) async throws -> OperatorJobResult {
            activeExecutions += 1
            maxConcurrent = max(maxConcurrent, activeExecutions)
            executionLog.append((job.id, job.kind))
            defer { activeExecutions -= 1 }
            if let err = nextError { nextError = nil; throw err }
            if let result = nextResult { nextResult = nil; return result }
            return .moderation(flagged: false, recommendation: "approve", maxScore: 0, model: nil)
        }
    }

    private func workInput(id: String) -> OperatorWorkInput {
        OperatorWorkInput(
            id: id,
            status: "pending",
            audio: .init(url: "https://example.invalid/audio.flac", sha256: String(repeating: "a", count: 64)),
            transcription: .init(id: "tr-\(id)", text: "bonjour", language: "fr", moderationText: "hello")
        )
    }

    @Test func successWorkPushesResultAndUpdatesStatus() async throws {
        let client = FakeClient()
        let channel = FakeChannel()
        let dispatcher = FakeDispatcher()
        await client.setInput(workInput(id: "m1"), for: "m1")
        await channel.enqueue(.init(messageId: "m1", needs: [.moderation]))
        await dispatcher.setResult(.moderation(flagged: false, recommendation: "approve", maxScore: 0.0, model: nil))

        let worker = OperatorWorker(client: client, dispatcher: dispatcher, workChannel: channel,
                                    reconnectBaseSeconds: 1, logger: Logger(label: "test"))
        await worker.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await worker.stop()

        let pushes = await client.pushCalls
        #expect(pushes.count == 1)
        #expect(pushes.first?.messageID == "m1")
        #expect(pushes.first?.transcriptionID == "tr-m1")
        #expect(pushes.first?.result == .moderation(
            flagged: false,
            recommendation: "approve",
            maxScore: 0.0,
            model: nil
        ))

        let status = await worker.currentStatus()
        #expect(status.phase == .stopped)
        #expect(status.lastJobID == "m1")
        #expect(status.lastJobKind == .moderation)
        #expect(status.consecutiveFailures == 0)
    }

    @Test func dispatcherErrorRecordsErrorWithoutPush() async throws {
        let client = FakeClient()
        let channel = FakeChannel()
        let dispatcher = FakeDispatcher()
        await client.setInput(workInput(id: "m2"), for: "m2")
        await channel.enqueue(.init(messageId: "m2", needs: [.translation]))
        await dispatcher.setError(OperatorJobError(code: "translation_malformed", message: "local translation failed"))

        let worker = OperatorWorker(client: client, dispatcher: dispatcher, workChannel: channel,
                                    reconnectBaseSeconds: 1, logger: Logger(label: "test"))
        await worker.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await worker.stop()

        let pushes = await client.pushCalls
        #expect(pushes.isEmpty)
        let status = await worker.currentStatus()
        #expect(status.lastErrorCode == "translation_malformed")
    }

    @Test func fetchErrorRecordsErrorWithoutDispatching() async throws {
        let client = FakeClient()
        let channel = FakeChannel()
        let dispatcher = FakeDispatcher()
        await client.setFetchError(OperatorClientError.unauthorized)
        await channel.enqueue(.init(messageId: "m3", needs: [.moderation]))

        let worker = OperatorWorker(client: client, dispatcher: dispatcher, workChannel: channel,
                                    reconnectBaseSeconds: 1, logger: Logger(label: "test"))
        await worker.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await worker.stop()

        let log = await dispatcher.executionLog
        #expect(log.isEmpty)
        let status = await worker.currentStatus()
        #expect(status.lastErrorCode == "operator_unauthorized")
    }

    @Test func dispatcherRunsOneNeedAtATime() async throws {
        let client = FakeClient()
        let channel = FakeChannel()
        let dispatcher = FakeDispatcher()
        await client.setInput(workInput(id: "a"), for: "a")
        await client.setInput(workInput(id: "b"), for: "b")
        await client.setInput(workInput(id: "c"), for: "c")
        await channel.enqueue(.init(messageId: "a", needs: [.moderation]))
        await channel.enqueue(.init(messageId: "b", needs: [.translation]))
        await channel.enqueue(.init(messageId: "c", needs: [.moderation]))

        let worker = OperatorWorker(client: client, dispatcher: dispatcher, workChannel: channel,
                                    reconnectBaseSeconds: 1, logger: Logger(label: "test"))
        await worker.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await worker.stop()

        let maxConc = await dispatcher.maxConcurrent
        #expect(maxConc == 1)
        let log = await dispatcher.executionLog.map(\.0)
        #expect(log == ["a", "b", "c"])
    }

    @Test func stopIsIdempotentAndClean() async throws {
        let client = FakeClient()
        let channel = FakeChannel()
        let dispatcher = FakeDispatcher()
        let worker = OperatorWorker(client: client, dispatcher: dispatcher, workChannel: channel,
                                    reconnectBaseSeconds: 1, logger: Logger(label: "test"))
        await worker.stop()
        await worker.start()
        await worker.stop()
        await worker.stop()
        let status = await worker.currentStatus()
        #expect(status.phase == .stopped)
    }
}
