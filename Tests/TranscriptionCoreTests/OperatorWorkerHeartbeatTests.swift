import Foundation
import Logging
import Testing
import TranscriptionOperator
import TranscriptionShared

@Suite("OperatorWorker push filters")
struct OperatorWorkerPushFilterTests {
    actor RecordingClient: OperatorClient {
        var inputs: [String: OperatorWorkInput] = [:]
        var pushes = 0

        func setInput(_ input: OperatorWorkInput, for id: String) { inputs[id] = input }
        func pushCount() -> Int { pushes }

        nonisolated func listWork(
            needs: OperatorWorkNeeds,
            limit: Int,
            cursor: String?
        ) async throws -> OperatorWorkListPage {
            OperatorWorkListPage(items: [])
        }

        nonisolated func fetchWorkInput(messageID: String) async throws -> OperatorWorkInput {
            await inputs[messageID] ?? OperatorWorkInput(id: messageID, status: "missing")
        }

        nonisolated func pushResult(
            messageID: String,
            transcriptionId: String?,
            expectedLatestTranscriptionId: String?,
            inputSha256: String?,
            result: OperatorJobResult
        ) async throws {
            await bump()
        }

        private func bump() { pushes += 1 }
    }

    actor ScriptedChannel: OperatorWorkChannel {
        let envelopes: [OperatorWorkEnvelope]
        var continuation: AsyncStream<OperatorWorkEnvelope>.Continuation?

        init(envelopes: [OperatorWorkEnvelope]) {
            self.envelopes = envelopes
        }

        nonisolated func connect() async throws -> AsyncStream<OperatorWorkEnvelope> {
            await self._connect()
        }

        private func _connect() -> AsyncStream<OperatorWorkEnvelope> {
            let pair = AsyncStream<OperatorWorkEnvelope>.makeStream(of: OperatorWorkEnvelope.self)
            continuation = pair.continuation
            for envelope in envelopes { pair.continuation.yield(envelope) }
            return pair.stream
        }

        nonisolated func disconnect() async { await self._disconnect() }
        private func _disconnect() { continuation?.finish() }
    }

    actor RecordingDispatcher: OperatorJobDispatcher {
        var jobs: [OperatorJob] = []

        nonisolated func execute(job: OperatorJob) async throws -> OperatorJobResult {
            await self._execute(job: job)
        }

        private func _execute(job: OperatorJob) -> OperatorJobResult {
            jobs.append(job)
            return .moderation(flagged: false, recommendation: "approve", maxScore: 0, model: nil)
        }
    }

    @Test func disabledKindsAreSkipped() async throws {
        let client = RecordingClient()
        let input = OperatorWorkInput(
            id: "m",
            status: "pending",
            transcription: .init(
                id: "tr",
                text: "bonjour",
                language: "fr",
                moderationText: "hello",
                moderationInputSha256: String(repeating: "a", count: 64)
            )
        )
        await client.setInput(input, for: "m")
        let channel = ScriptedChannel(envelopes: [.init(messageId: "m", needs: [.translation, .moderation])])
        let dispatcher = RecordingDispatcher()
        let worker = OperatorWorker(
            client: client,
            dispatcher: dispatcher,
            workChannel: channel,
            reconnectBaseSeconds: 1,
            enabledKinds: [.moderation],
            logger: Logger(label: "test")
        )

        await worker.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await worker.stop()

        let kinds = await dispatcher.jobs.map(\.kind)
        #expect(kinds == [.moderation])
        let pushes = await client.pushCount()
        #expect(pushes == 1)
    }

    @Test func workEnvelopeDecodeIgnoresNonWork() throws {
        let message = Data(#"{"kind":"message","messageId":"m","needs":["moderation"]}"#.utf8)
        let decoded = try OperatorWorkEnvelope.decodeWork(from: message)
        #expect(decoded == nil)
    }

    @Test func workInputBuildsTranslationJobWithTranscriptionIDAvailable() throws {
        let source = "\u{00A0}\u{FEFF}\u{0085}bonjour\u{0085}\u{2029}"
        let input = OperatorWorkInput(
            id: "m",
            status: "pending",
            transcription: .init(
                id: "tr",
                text: source,
                language: "fr",
                moderationText: "hello",
                moderationInputSha256: String(repeating: "a", count: 64)
            )
        )
        let job = try #require(input.makeJob(for: .translation))
        #expect(job.id == "m")
        #expect(job.kind == .translation)
        if case .translation(let payload) = job.payload {
            #expect(payload.input == "\u{0085}bonjour\u{0085}")
            #expect(payload.sourceLanguage == "fr")
        } else {
            Issue.record("expected translation payload")
        }
    }

    @Test func workInputPreservesTheOperatorsCanonicalModerationText() throws {
        let canonical = "\u{0085}hello\u{0085}"
        let input = OperatorWorkInput(
            id: "m",
            status: "pending",
            transcription: .init(
                id: "tr",
                text: "bonjour",
                moderationText: canonical,
                moderationInputSha256: String(repeating: "a", count: 64)
            )
        )

        let job = try #require(input.makeJob(for: .moderation))
        if case .moderation(let payload) = job.payload {
            #expect(payload.input == canonical)
        } else {
            Issue.record("expected moderation payload")
        }
    }
}
