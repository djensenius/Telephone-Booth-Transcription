import Foundation
import Logging
import TranscriptionShared

/// Long-running background worker that subscribes to the Operator status
/// WebSocket, fetches message work inputs on demand, runs one local job at a
/// time, and pushes results back to the Operator.
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

        public init() {}
    }
    // swiftlint:enable nesting

    private let client: any OperatorClient
    private let dispatcher: any OperatorJobDispatcher
    private let workChannel: any OperatorWorkChannel
    private let reconnectBaseSeconds: Int
    private let enabledKinds: Set<OperatorJob.Kind>
    private let logger: Logger
    private let clock: @Sendable () -> Date
    private let onStatusChange: (@Sendable (Status) -> Void)?
    private let minimumHealthyConnectionSeconds: TimeInterval = 5

    private var status = Status()
    private var task: Task<Void, Never>?
    private var stopRequested = false

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

    /// Starts the WebSocket subscription loop. Idempotent.
    public func start() {
        guard task == nil else { return }
        stopRequested = false
        setPhase(.connecting)
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Signals the loop to stop and awaits teardown. Idempotent.
    public func stop() async {
        stopRequested = true
        let runningTask = task
        task = nil
        await workChannel.disconnect()
        if let runningTask {
            runningTask.cancel()
            await runningTask.value
        }
        setPhase(.stopped)
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
                    await handle(envelope)
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

    private func handle(_ envelope: OperatorWorkEnvelope) async {
        let needs = envelope.needs.filter(enabledKinds.contains)
        guard !needs.isEmpty else { return }
        for need in needs {
            if stopRequested || Task.isCancelled { break }
            await runNeed(need, messageID: envelope.messageId)
        }
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
                transcriptionId: input.transcription?.id,
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
