import Foundation
import Logging
import TranscriptionShared

/// Long-running background worker that keeps the Mac supplied with Operator
/// work. Two independent sources feed one serialized job queue:
///
/// 1. the status WebSocket, which still solicits translation and moderation
///    (and transcription when an operator presses "Re-run transcription");
/// 2. a **discovery pass** that polls `GET /v1/worker/messages` for reviewable
///    messages with no succeeded transcription. Transcription is optional
///    enrichment on the Operator side and is no longer broadcast for new
///    uploads, so the app has to find that work itself.
///
/// **Privacy:** the worker never logs audio bytes, transcripts, translated
/// text, or moderation input. Status snapshots include sanitized error codes
/// and message IDs only.
public actor OperatorWorker {
    // swiftlint:disable nesting
    public struct Status: Sendable, Equatable {
        public enum Phase: String, Sendable, Equatable {
            case stopped
            case connecting
            case subscribed
            case running
            case error
        }
        public var phase: Phase = .stopped
        public var lastJobID: String?
        public var lastJobKind: OperatorJob.Kind?
        public var lastSuccessAt: Date?
        public var lastErrorCode: String?
        public var lastErrorAt: Date?
        public var consecutiveFailures: Int = 0
        /// When the discovery pass last completed a successful listing.
        public var lastDiscoveryAt: Date?
        /// How many messages that listing enqueued for transcription.
        public var lastDiscoveredCount: Int?

        public init() {}
    }

    /// One queued unit of work. `force` marks a deliberate human re-run, which
    /// bypasses the per-kind enable filter.
    private struct QueuedJob: Sendable, Equatable {
        var messageID: String
        var kind: OperatorJob.Kind
        var force: Bool

        var key: String { "\(kind.rawValue):\(messageID)" }
    }
    // swiftlint:enable nesting

    private let client: any OperatorClient
    private let dispatcher: any OperatorJobDispatcher
    private let workChannel: any OperatorWorkChannel
    private let reconnectBaseSeconds: Int
    /// Discovery poll interval. Reuses the worker's configured base delay.
    private var discoveryBaseSeconds: Int { reconnectBaseSeconds }
    private let enabledKinds: Set<OperatorJob.Kind>
    private let logger: Logger
    private let clock: @Sendable () -> Date
    private let onStatusChange: (@Sendable (Status) -> Void)?
    private let minimumHealthyConnectionSeconds: TimeInterval = 5

    private var status = Status()
    private var task: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var jobQueue: [QueuedJob] = []
    private var queuedKeys: Set<String> = []
    private var runningKey: String?
    private var discoveryFailures = 0
    /// How many times the discovery pass has enqueued each message this
    /// session. Caps repeated attempts so a message the Operator keeps listing
    /// (because a push failed, say) can't spin in a hot loop.
    private var discoveryAttempts: [String: Int] = [:]
    private var stopRequested = false

    /// Page size for the discovery listing, and how many pages one pass will
    /// follow before waiting for the next interval.
    private let discoveryPageLimit = 50
    private let discoveryMaxPages = 10
    private let maxDiscoveryAttempts = 3

    public init(
        client: any OperatorClient,
        dispatcher: any OperatorJobDispatcher,
        workChannel: any OperatorWorkChannel,
        reconnectBaseSeconds: Int,
        enabledKinds: Set<OperatorJob.Kind> = Set(OperatorJob.Kind.allCases),
        logger: Logger = Logger(label: "operator-worker"),
        clock: @Sendable @escaping () -> Date = { Date() },
        onStatusChange: (@Sendable (Status) -> Void)? = nil
    ) {
        self.client = client
        self.dispatcher = dispatcher
        self.workChannel = workChannel
        self.reconnectBaseSeconds = max(OperatorPollingConfig.minPollInterval,
                                        min(OperatorPollingConfig.maxPollInterval, reconnectBaseSeconds))
        self.enabledKinds = enabledKinds
        self.logger = logger
        self.clock = clock
        self.onStatusChange = onStatusChange
    }

    public func currentStatus() -> Status { status }

    /// Starts the WebSocket subscription loop and the discovery pass. Idempotent.
    public func start() {
        guard task == nil else { return }
        stopRequested = false
        setPhase(.connecting)
        task = Task { [weak self] in
            await self?.runLoop()
        }
        guard enabledKinds.contains(.transcription) else { return }
        discoveryTask = Task { [weak self] in
            await self?.discoveryLoop()
        }
    }

    /// Signals the loops to stop and awaits teardown. Idempotent.
    public func stop() async {
        stopRequested = true
        let runningTask = task
        let discovery = discoveryTask
        let drain = drainTask
        task = nil
        discoveryTask = nil
        drainTask = nil
        jobQueue.removeAll()
        queuedKeys.removeAll()
        await workChannel.disconnect()
        discovery?.cancel()
        drain?.cancel()
        if let runningTask {
            runningTask.cancel()
            await runningTask.value
        }
        await discovery?.value
        await drain?.value
        setPhase(.stopped)
    }

    /// Deliberately re-runs transcription for one message, regardless of
    /// whether the Operator already holds a transcript for it. Returns `false`
    /// when the worker isn't running or the job is already queued.
    @discardableResult
    public func requestTranscription(messageID: String) -> Bool {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, task != nil, !stopRequested else { return false }
        return enqueue(.init(messageID: trimmed, kind: .transcription, force: true))
    }

    private func runLoop() async {
        while !stopRequested && !Task.isCancelled {
            do {
                setPhase(.connecting)
                let connectedAt = clock()
                let stream = try await workChannel.connect()
                recordSubscribed()
                var confirmedHealthy = false
                for await envelope in stream {
                    if stopRequested || Task.isCancelled { break }
                    if !confirmedHealthy {
                        recordConnectionHealthy()
                        confirmedHealthy = true
                    }
                    handle(envelope)
                }
                if !stopRequested && !Task.isCancelled {
                    let connectedSeconds = clock().timeIntervalSince(connectedAt)
                    if !confirmedHealthy, connectedSeconds >= minimumHealthyConnectionSeconds {
                        recordConnectionHealthy()
                    }
                    recordError(code: "operator_ws_disconnected", message: "websocket disconnected")
                }
            } catch {
                recordError(code: errorCode(for: error), message: "connect failed: \(type(of: error))")
            }
            if !stopRequested && !Task.isCancelled {
                await sleepBackoff()
            }
        }
    }

    private func handle(_ envelope: OperatorWorkEnvelope) {
        for need in envelope.needs {
            enqueue(.init(messageID: envelope.messageId, kind: need, force: false))
        }
    }

    // MARK: - Discovery

    /// Polls the worker listing endpoint for reviewable messages that have no
    /// succeeded transcription and enqueues one transcription job per message.
    /// Runs independently of the WebSocket so a dropped or absent `work` event
    /// can never stall transcription.
    private func discoveryLoop() async {
        while !stopRequested && !Task.isCancelled {
            await runDiscoveryPass()
            if stopRequested || Task.isCancelled { break }
            await sleepDiscoveryInterval()
        }
    }

    private func runDiscoveryPass() async {
        var cursor: String?
        var enqueued = 0
        var pages = 0
        repeat {
            if stopRequested || Task.isCancelled { return }
            do {
                let page = try await client.listWork(
                    needs: .transcription,
                    limit: discoveryPageLimit,
                    cursor: cursor
                )
                for item in page.items where !item.hasSucceededTranscription {
                    guard discoveryAttempts[item.id, default: 0] < maxDiscoveryAttempts else { continue }
                    if enqueue(.init(messageID: item.id, kind: .transcription, force: false)) {
                        discoveryAttempts[item.id, default: 0] += 1
                        enqueued += 1
                    }
                }
                cursor = page.nextCursor
                pages += 1
            } catch {
                recordDiscoveryError(code: errorCode(for: error))
                return
            }
        } while cursor != nil && pages < discoveryMaxPages

        discoveryFailures = 0
        status.lastDiscoveryAt = clock()
        status.lastDiscoveredCount = enqueued
        emitStatus()
    }

    private func sleepDiscoveryInterval() async {
        let exp = min(5, discoveryFailures)
        let seconds = discoveryFailures == 0
            ? discoveryBaseSeconds
            : min(300, max(discoveryBaseSeconds, discoveryBaseSeconds * Int(pow(2.0, Double(exp)))))
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    // MARK: - Job queue

    /// Enqueues a job unless the same `(message, kind)` pair is already queued
    /// or in flight, so a `work` envelope and a discovery hit for the same
    /// message run exactly once. Returns whether it was actually enqueued.
    @discardableResult
    private func enqueue(_ job: QueuedJob) -> Bool {
        // Teardown can interleave with an in-flight discovery response; without
        // this guard a late enqueue would leave stale keys behind after `stop()`
        // has already drained the queue.
        guard !stopRequested, !Task.isCancelled else { return false }
        guard job.force || enabledKinds.contains(job.kind) else { return false }
        guard !job.messageID.isEmpty else { return false }
        guard !queuedKeys.contains(job.key), runningKey != job.key else { return false }
        queuedKeys.insert(job.key)
        jobQueue.append(job)
        startDrainIfNeeded()
        return true
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, !stopRequested else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !stopRequested && !Task.isCancelled, let job = dequeue() {
            await runNeed(job.kind, messageID: job.messageID)
            runningKey = nil
        }
        runningKey = nil
        drainTask = nil
    }

    private func dequeue() -> QueuedJob? {
        guard !jobQueue.isEmpty else { return nil }
        let job = jobQueue.removeFirst()
        queuedKeys.remove(job.key)
        runningKey = job.key
        return job
    }

    private func runNeed(_ need: OperatorJob.Kind, messageID: String) async {
        setPhase(.running, jobID: messageID, kind: need)
        do {
            let input = try await client.fetchWorkInput(messageID: messageID)
            guard let job = input.makeJob(for: need) else {
                recordError(code: "operator_work_input_missing", message: "missing input for \(need.rawValue)")
                return
            }
            let result = try await dispatcher.execute(job: job)
            try await client.pushResult(
                messageID: messageID,
                // Transcription results are unsolicited: the Operator no longer
                // pre-creates a pending row, and a re-run intentionally creates
                // a new succeeded row rather than updating the old one.
                transcriptionId: need == .transcription ? nil : input.transcription?.id,
                result: result
            )
            recordSuccess(jobID: messageID, kind: need)
        } catch let error as OperatorJobError {
            recordError(code: error.code, message: error.message)
        } catch {
            recordError(code: errorCode(for: error), message: "work failed: \(type(of: error))")
        }
    }

    private func sleepBackoff() async {
        let exp = min(5, status.consecutiveFailures)
        let seconds = min(30, max(reconnectBaseSeconds, Int(pow(2.0, Double(exp)))))
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    private func setPhase(_ phase: Status.Phase, jobID: String? = nil, kind: OperatorJob.Kind? = nil) {
        status.phase = phase
        if let jobID { status.lastJobID = jobID }
        if let kind { status.lastJobKind = kind }
        emitStatus()
    }

    private func recordSubscribed() {
        status.phase = .subscribed
        emitStatus()
    }

    private func recordConnectionHealthy() {
        status.consecutiveFailures = 0
        status.lastErrorCode = nil
        status.phase = .subscribed
        emitStatus()
    }

    private func recordSuccess(jobID: String, kind: OperatorJob.Kind) {
        status.consecutiveFailures = 0
        status.lastSuccessAt = clock()
        status.lastErrorCode = nil
        status.lastJobID = jobID
        status.lastJobKind = kind
        status.phase = .subscribed
        if kind == .transcription {
            // The Operator will stop listing this message; drop the counter so
            // it doesn't accumulate for the worker's whole lifetime, which also
            // restores a full attempt budget if the message ever comes back.
            discoveryAttempts.removeValue(forKey: jobID)
        }
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

    /// Discovery failures back off on their own schedule and must not disturb
    /// the WebSocket reconnect backoff or the phase the socket loop publishes.
    private func recordDiscoveryError(code: String) {
        discoveryFailures += 1
        status.lastErrorAt = clock()
        status.lastErrorCode = code
        logger.warning("operator discovery error code=\(code)")
        emitStatus()
    }

    private func emitStatus() {
        guard let onStatusChange else { return }
        onStatusChange(status)
    }

    private func errorCode(for error: any Error) -> String {
        switch error {
        case OperatorClientError.notConfigured, OperatorWorkChannelError.notConfigured:
            return "operator_not_configured"
        case OperatorClientError.unauthorized, OperatorWorkChannelError.unauthorized:
            return "operator_unauthorized"
        case OperatorClientError.http(let code):
            return "operator_http_\(code)"
        case OperatorClientError.malformedResponse:
            return "operator_malformed_response"
        case OperatorClientError.missingTranscriptionId:
            return "operator_missing_transcription_id"
        case OperatorWorkChannelError.invalidBaseURL:
            return "operator_invalid_base_url"
        default:
            return "operator_\(type(of: error))"
        }
    }
}

/// Executes a synthetic job and produces an `OperatorJobResult`. Abstracted so
/// the worker can be tested with a fake dispatcher.
public protocol OperatorJobDispatcher: Sendable {
    func execute(job: OperatorJob) async throws -> OperatorJobResult
}
