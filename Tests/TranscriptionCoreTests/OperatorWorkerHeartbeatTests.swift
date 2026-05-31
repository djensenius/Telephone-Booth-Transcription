import AsyncHTTPClient
import Foundation
import Logging
import Testing
import TranscriptionOperator
import TranscriptionShared

@Suite("OperatorWorker heartbeat")
struct OperatorWorkerHeartbeatTests {
    actor RecordingClient: OperatorClient {
        var queued: [OperatorJob?] = []
        var heartbeats = 0
        var successes = 0

        func enqueue(_ job: OperatorJob?) { queued.append(job) }
        func heartbeatCount() -> Int { heartbeats }
        func successCount() -> Int { successes }

        nonisolated func leaseNextJob() async throws -> OperatorJob? { try await pop() }
        private func pop() -> OperatorJob? { queued.isEmpty ? nil : queued.removeFirst() }

        nonisolated func submitSuccess(jobID: String, leaseToken: String, result: OperatorJobResult) async throws {
            await bumpSuccess()
        }
        private func bumpSuccess() { successes += 1 }

        nonisolated func submitFailure(jobID: String, leaseToken: String, error: OperatorJobError) async throws {}

        nonisolated func heartbeat(jobID: String, leaseToken: String) async throws { await bump() }
        private func bump() { heartbeats += 1 }
    }

    /// Dispatcher whose execution takes a fixed duration, so a heartbeat can
    /// fire mid-flight.
    struct SlowDispatcher: OperatorJobDispatcher {
        let durationNanos: UInt64
        func execute(job: OperatorJob) async throws -> OperatorJobResult {
            try? await Task.sleep(nanoseconds: durationNanos)
            return .moderation(flagged: false, recommendation: "allow", maxScore: 0, model: nil)
        }
    }

    @Test func issuesHeartbeatsForLongJob() async throws {
        let client = RecordingClient()
        let job = OperatorJob(id: "j", leaseToken: "lt", kind: .moderation,
                              payload: .moderation(.init(input: "x")))
        await client.enqueue(job)

        let worker = OperatorWorker(
            client: client,
            dispatcher: SlowDispatcher(durationNanos: 2_500_000_000),
            pollIntervalSeconds: 1,
            heartbeatIntervalSeconds: 1,
            logger: Logger(label: "test")
        )
        await worker.start()
        try await Task.sleep(nanoseconds: 3_200_000_000)
        await worker.stop()

        let beats = await client.heartbeatCount()
        let successes = await client.successCount()
        #expect(beats >= 1)
        #expect(successes == 1)
    }

    @Test func disabledByDefaultIssuesNoHeartbeat() async throws {
        let client = RecordingClient()
        let job = OperatorJob(id: "j", leaseToken: "lt", kind: .moderation,
                              payload: .moderation(.init(input: "x")))
        await client.enqueue(job)

        let worker = OperatorWorker(
            client: client,
            dispatcher: SlowDispatcher(durationNanos: 200_000_000),
            pollIntervalSeconds: 1,
            logger: Logger(label: "test")
        )
        await worker.start()
        try await Task.sleep(nanoseconds: 600_000_000)
        await worker.stop()

        let beats = await client.heartbeatCount()
        #expect(beats == 0)
    }
}

@Suite("HTTPOperatorClient capability gating")
struct OperatorClientCapabilityTests {
    private func makeConfig() -> OperatorPollingConfig {
        OperatorPollingConfig(enabled: true, baseURL: "https://operator.invalid",
                              pollIntervalSeconds: 5, leaseSeconds: 60)
    }

    @Test func emptyCapabilitiesLeaseReturnsNilWithoutIO() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = HTTPOperatorClient(
            httpClient: httpClient,
            config: makeConfig(),
            token: "tkn",
            capabilities: []
        )
        // base URL is unreachable; if this attempted I/O it would throw, not
        // return nil.
        let job = try await client.leaseNextJob()
        try? await httpClient.shutdown()
        #expect(job == nil)
    }

    @Test func disjointCapabilitiesLeaseReturnsNil() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        var config = makeConfig()
        config.translationEnabled = false
        config.moderationEnabled = false
        // config only enables transcription; device can only do moderation.
        let client = HTTPOperatorClient(
            httpClient: httpClient,
            config: config,
            token: "tkn",
            capabilities: [.moderation]
        )
        let job = try await client.leaseNextJob()
        try? await httpClient.shutdown()
        #expect(job == nil)
    }
}
