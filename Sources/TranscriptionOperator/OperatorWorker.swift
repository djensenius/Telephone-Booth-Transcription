import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import TranscriptionShared

/// Long-running background worker that polls the Operator's `/v1/jobs/next`
/// endpoint, runs leased jobs locally against this app's HTTP server, and
/// submits results back via `succeed`/`fail`. Designed to run in addition
/// to (or instead of) the existing push-in path where the Operator reaches
/// this app's HTTP server directly.
///
/// **Concurrency:** one job at a time per worker, by design — the user's
/// installation has a single human speaker, so there's no benefit to
/// processing pulled jobs in parallel and serial behavior keeps lease
/// management trivial.
///
/// **Privacy:** the worker never logs audio bytes, transcripts, translated
/// text, or moderation input. Status snapshots include sanitized error
/// codes and job IDs only.
public actor OperatorWorker {
    public struct Status: Sendable, Equatable {
        public enum Phase: String, Sendable, Equatable {
            case stopped
            case idle           // waiting between polls
            case polling        // about to issue GET /v1/jobs/next
            case running        // executing a leased job
            case error          // last poll/submit failed; retrying with backoff
        }
        public var phase: Phase = .stopped
        public var lastJobID: String?
        public var lastJobKind: OperatorJob.Kind?
        public var lastSuccessAt: Date?
        public var lastErrorCode: String?
        public var lastErrorAt: Date?
        public var consecutiveFailures: Int = 0

        public init() {}
    }

    private let client: any OperatorClient
    private let dispatcher: any OperatorJobDispatcher
    private let pollIntervalSeconds: Int
    private let heartbeatIntervalSeconds: Int?
    private let logger: Logger
    private let clock: @Sendable () -> Date
    private let onStatusChange: (@Sendable (Status) -> Void)?

    private var status = Status()
    private var task: Task<Void, Never>?
    private var stopRequested = false

    public init(
        client: any OperatorClient,
        dispatcher: any OperatorJobDispatcher,
        pollIntervalSeconds: Int,
        heartbeatIntervalSeconds: Int? = nil,
        logger: Logger = Logger(label: "operator-worker"),
        clock: @Sendable @escaping () -> Date = { Date() },
        onStatusChange: (@Sendable (Status) -> Void)? = nil
    ) {
        self.client = client
        self.dispatcher = dispatcher
        self.pollIntervalSeconds = max(OperatorPollingConfig.minPollInterval,
                                       min(OperatorPollingConfig.maxPollInterval, pollIntervalSeconds))
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds.map { max(1, $0) }
        self.logger = logger
        self.clock = clock
        self.onStatusChange = onStatusChange
    }

    public func currentStatus() -> Status { status }

    /// Starts the polling loop. Idempotent — calling `start` while already
    /// running is a no-op.
    public func start() {
        guard task == nil else { return }
        stopRequested = false
        setPhase(.idle)
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Signals the loop to stop after the current iteration and awaits it.
    /// Cancels the task so any in-flight `Task.sleep` returns immediately
    /// rather than blocking for the rest of the poll interval (or backoff).
    /// Idempotent.
    public func stop() async {
        stopRequested = true
        let t = task
        task = nil
        if let t {
            t.cancel()
            await t.value
        }
        setPhase(.stopped)
    }

    private func runLoop() async {
        while !stopRequested && !Task.isCancelled {
            await tick()
            if stopRequested || Task.isCancelled { break }
            await sleepBackoff()
        }
    }

    private func tick() async {
        setPhase(.polling)
        let leased: OperatorJob?
        do {
            leased = try await client.leaseNextJob()
        } catch {
            recordError(code: errorCode(for: error), message: "lease failed: \(type(of: error))")
            return
        }
        guard let job = leased else {
            setPhase(.idle)
            return
        }
        setPhase(.running, jobID: job.id, kind: job.kind)
        // Keep the lease alive while the (potentially slow) job runs, then stop
        // and await the heartbeat task *before* submitting the outcome so no
        // heartbeat can race a succeed/fail.
        let heartbeat = startHeartbeat(for: job)
        let outcome: Result<OperatorJobResult, any Error>
        do {
            outcome = .success(try await dispatcher.execute(job: job))
        } catch {
            outcome = .failure(error)
        }
        await stopHeartbeat(heartbeat)

        switch outcome {
        case .success(let result):
            do {
                try await client.submitSuccess(jobID: job.id, leaseToken: job.leaseToken, result: result)
                recordSuccess()
            } catch {
                let code = errorCode(for: error)
                await submitFailure(job: job, error: .init(code: code, message: "\(type(of: error))"))
            }
        case .failure(let dispatchError as OperatorJobError):
            await submitFailure(job: job, error: dispatchError)
        case .failure(let error):
            let code = errorCode(for: error)
            await submitFailure(job: job, error: .init(code: code, message: "\(type(of: error))"))
        }
    }

    /// Spawns a detached-from-actor task that periodically extends the lease.
    /// Returns nil when heartbeating is disabled. The loop sleeps *before* its
    /// first heartbeat, so short jobs never issue one. Failures are logged and
    /// never surfaced to the job outcome.
    private func startHeartbeat(for job: OperatorJob) -> Task<Void, Never>? {
        guard let interval = heartbeatIntervalSeconds else { return nil }
        let client = self.client
        let logger = self.logger
        let jobID = job.id
        let leaseToken = job.leaseToken
        let nanos = UInt64(interval) * 1_000_000_000
        return Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                do {
                    try await client.heartbeat(jobID: jobID, leaseToken: leaseToken)
                } catch {
                    logger.debug("heartbeat failed: \(type(of: error))")
                }
            }
        }
    }

    private func stopHeartbeat(_ task: Task<Void, Never>?) async {
        guard let task else { return }
        task.cancel()
        await task.value
    }

    private func submitFailure(job: OperatorJob, error: OperatorJobError) async {
        do {
            try await client.submitFailure(jobID: job.id, leaseToken: job.leaseToken, error: error)
        } catch {
            logger.warning("failed to submit job failure: \(type(of: error))")
        }
        recordError(code: error.code, message: error.message)
    }

    private func sleepBackoff() async {
        // Exponential backoff up to ~30s when in error state, otherwise the
        // configured poll interval. The current iteration's `nanos` value is
        // never zero, so `Task.sleep(nanoseconds:)` always pauses for at
        // least one second between polls.
        let seconds: Int
        if status.phase == .error {
            let exp = min(5, status.consecutiveFailures)
            seconds = min(30, max(pollIntervalSeconds, Int(pow(2.0, Double(exp)))))
        } else {
            seconds = pollIntervalSeconds
        }
        let nanos = UInt64(seconds) * 1_000_000_000
        try? await Task.sleep(nanoseconds: nanos)
    }

    private func setPhase(_ phase: Status.Phase, jobID: String? = nil, kind: OperatorJob.Kind? = nil) {
        status.phase = phase
        if let jobID { status.lastJobID = jobID }
        if let kind { status.lastJobKind = kind }
        emitStatus()
    }

    private func recordSuccess() {
        status.consecutiveFailures = 0
        status.lastSuccessAt = clock()
        status.lastErrorCode = nil
        status.phase = .idle
        emitStatus()
    }

    private func recordError(code: String, message: String) {
        status.consecutiveFailures += 1
        status.lastErrorAt = clock()
        status.lastErrorCode = code
        status.phase = .error
        logger.warning("operator worker error code=\(code) detail=\(message)")
        emitStatus()
    }

    private func emitStatus() {
        guard let onStatusChange else { return }
        let snapshot = status
        onStatusChange(snapshot)
    }

    private func errorCode(for error: any Error) -> String {
        switch error {
        case OperatorClientError.notConfigured: return "operator_not_configured"
        case OperatorClientError.unauthorized: return "operator_unauthorized"
        case OperatorClientError.http(let code): return "operator_http_\(code)"
        case OperatorClientError.malformedResponse: return "operator_malformed_response"
        default: return "operator_\(type(of: error))"
        }
    }
}

/// Executes a leased job and produces an `OperatorJobResult`. Abstracted
/// so the worker can be tested with a fake dispatcher.
public protocol OperatorJobDispatcher: Sendable {
    func execute(job: OperatorJob) async throws -> OperatorJobResult
}
