import Foundation
import Logging
import Testing
@testable import TranscriptionCore

@Suite("OperatorWorker")
struct OperatorWorkerTests {
    /// Fake client recording calls and returning queued responses.
    actor FakeClient: OperatorClient {
        var queuedJobs: [OperatorJob?] = []
        var leaseError: (any Error)?
        var successCalls: [(String, String, OperatorJobResult)] = []
        var failureCalls: [(String, String, OperatorJobError)] = []
        var heartbeatCalls: [(String, String)] = []

        func enqueue(_ job: OperatorJob?) { queuedJobs.append(job) }
        func setLeaseError(_ err: any Error) { leaseError = err }

        nonisolated func leaseNextJob() async throws -> OperatorJob? {
            try await self._leaseNextJob()
        }
        func _leaseNextJob() async throws -> OperatorJob? {
            if let err = leaseError { leaseError = nil; throw err }
            guard !queuedJobs.isEmpty else { return nil }
            return queuedJobs.removeFirst()
        }
        nonisolated func submitSuccess(jobID: String, leaseToken: String, result: OperatorJobResult) async throws {
            await self._submitSuccess(jobID: jobID, leaseToken: leaseToken, result: result)
        }
        func _submitSuccess(jobID: String, leaseToken: String, result: OperatorJobResult) {
            successCalls.append((jobID, leaseToken, result))
        }
        nonisolated func submitFailure(jobID: String, leaseToken: String, error: OperatorJobError) async throws {
            await self._submitFailure(jobID: jobID, leaseToken: leaseToken, error: error)
        }
        func _submitFailure(jobID: String, leaseToken: String, error: OperatorJobError) {
            failureCalls.append((jobID, leaseToken, error))
        }
        nonisolated func heartbeat(jobID: String, leaseToken: String) async throws {
            await self._heartbeat(jobID: jobID, leaseToken: leaseToken)
        }
        func _heartbeat(jobID: String, leaseToken: String) {
            heartbeatCalls.append((jobID, leaseToken))
        }
    }

    actor FakeDispatcher: OperatorJobDispatcher {
        var nextResult: OperatorJobResult?
        var nextError: (any Error)?
        var activeExecutions: Int = 0
        var maxConcurrent: Int = 0
        var executionLog: [String] = []

        func setResult(_ r: OperatorJobResult) { nextResult = r }
        func setError(_ err: any Error) { nextError = err }

        nonisolated func execute(job: OperatorJob) async throws -> OperatorJobResult {
            try await self._execute(job: job)
        }
        func _execute(job: OperatorJob) async throws -> OperatorJobResult {
            activeExecutions += 1
            maxConcurrent = max(maxConcurrent, activeExecutions)
            executionLog.append(job.id)
            defer { activeExecutions -= 1 }
            if let err = nextError { nextError = nil; throw err }
            if let r = nextResult { nextResult = nil; return r }
            return .transcription(text: "ok", language: nil, model: nil)
        }
    }

    private func makeJob(id: String, kind: OperatorJob.Kind = .moderation) -> OperatorJob {
        switch kind {
        case .moderation:
            return OperatorJob(id: id, leaseToken: "lease-\(id)", kind: .moderation,
                               payload: .moderation(.init(input: "x")))
        case .translation:
            return OperatorJob(id: id, leaseToken: "lease-\(id)", kind: .translation,
                               payload: .translation(.init(input: "x")))
        case .transcription:
            return OperatorJob(id: id, leaseToken: "lease-\(id)", kind: .transcription,
                               payload: .transcription(.init(audioURL: "https://x/audio", sha256: "abc")))
        }
    }

    @Test func successJobSubmitsResultAndUpdatesStatus() async throws {
        let client = FakeClient()
        let dispatcher = FakeDispatcher()
        await client.enqueue(makeJob(id: "j1"))
        await dispatcher.setResult(.moderation(flagged: false, recommendation: "allow", maxScore: 0.0, model: nil))

        let worker = OperatorWorker(
            client: client,
            dispatcher: dispatcher,
            pollIntervalSeconds: 1,
            logger: Logger(label: "test")
        )
        await worker.start()
        // Allow first tick to complete.
        try await Task.sleep(nanoseconds: 200_000_000)
        await worker.stop()

        let successes = await client.successCalls
        #expect(successes.count == 1)
        #expect(successes.first?.0 == "j1")
        #expect(successes.first?.1 == "lease-j1")

        let failures = await client.failureCalls
        #expect(failures.isEmpty)

        let status = await worker.currentStatus()
        #expect(status.phase == .stopped)
        #expect(status.lastJobID == "j1")
        #expect(status.lastJobKind == .moderation)
        #expect(status.consecutiveFailures == 0)
        #expect(status.lastErrorCode == nil)
    }

    @Test func dispatcherErrorMappedToSubmitFailure() async throws {
        let client = FakeClient()
        let dispatcher = FakeDispatcher()
        await client.enqueue(makeJob(id: "j2"))
        await dispatcher.setError(OperatorJobError(code: "translation_malformed",
                                                   message: "bad shape"))

        let worker = OperatorWorker(
            client: client,
            dispatcher: dispatcher,
            pollIntervalSeconds: 1,
            logger: Logger(label: "test")
        )
        await worker.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await worker.stop()

        let failures = await client.failureCalls
        #expect(failures.count == 1)
        #expect(failures.first?.2.code == "translation_malformed")

        let status = await worker.currentStatus()
        #expect(status.lastErrorCode == "translation_malformed")
        #expect(status.consecutiveFailures >= 1)
    }

    @Test func leaseErrorRecordsErrorWithoutSubmitting() async throws {
        struct Boom: Error {}
        let client = FakeClient()
        let dispatcher = FakeDispatcher()
        await client.setLeaseError(OperatorClientError.unauthorized)

        let worker = OperatorWorker(
            client: client,
            dispatcher: dispatcher,
            pollIntervalSeconds: 1,
            logger: Logger(label: "test")
        )
        await worker.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await worker.stop()

        let successes = await client.successCalls
        let failures = await client.failureCalls
        #expect(successes.isEmpty)
        #expect(failures.isEmpty) // no job leased -> no failure submission
        let status = await worker.currentStatus()
        #expect(status.lastErrorCode == "operator_unauthorized")
    }

    @Test func dispatcherRunsOneJobAtATime() async throws {
        let client = FakeClient()
        let dispatcher = FakeDispatcher()
        await client.enqueue(makeJob(id: "a"))
        await client.enqueue(makeJob(id: "b"))
        await client.enqueue(makeJob(id: "c"))

        let worker = OperatorWorker(
            client: client,
            dispatcher: dispatcher,
            pollIntervalSeconds: 1,
            logger: Logger(label: "test")
        )
        await worker.start()
        // Three 1-second polls.
        try await Task.sleep(nanoseconds: 3_500_000_000)
        await worker.stop()

        let maxConc = await dispatcher.maxConcurrent
        #expect(maxConc == 1)
        let log = await dispatcher.executionLog
        #expect(log == ["a", "b", "c"])
    }

    @Test func stopIsIdempotentAndClean() async throws {
        let client = FakeClient()
        let dispatcher = FakeDispatcher()
        let worker = OperatorWorker(
            client: client,
            dispatcher: dispatcher,
            pollIntervalSeconds: 1,
            logger: Logger(label: "test")
        )
        await worker.stop()  // before start
        await worker.start()
        await worker.stop()
        await worker.stop()  // double-stop
        let status = await worker.currentStatus()
        #expect(status.phase == .stopped)
    }
}
