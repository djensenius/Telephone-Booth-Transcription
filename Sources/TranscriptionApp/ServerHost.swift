#if os(macOS)
import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import NIOCore
import NIOPosix
import TranscriptionAuth
import TranscriptionCore
import TranscriptionReview

/// Owns the lifecycle of the embedded HTTP server, the power assertion, and
/// the shared `HTTPClient`. All UI mutations go through this actor.
///
/// Lifecycle transitions are serialized: each call to `start()` or `stop()`
/// awaits any in-flight transition before proceeding, preventing races when the
/// user taps Start/Stop rapidly or the app is exiting.
@MainActor
// swiftlint:disable:next type_body_length
final class ServerHost: ObservableObject {
    enum RunState: Equatable {
        case stopped
        case starting
        case running(host: String, port: Int)
        case stopping
        case errored(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running(let host, let port): return "Running on http://\(host):\(port)"
            case .stopping: return "Stopping…"
            case .errored(let why): return "Error: \(why)"
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isActive: Bool {
            switch self {
            case .starting, .running, .stopping: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: RunState = .stopped
    @Published var config: ServerConfig {
        didSet {
            guard !isDemo else { return }
            ConfigPersistence.save(config, keyStore: apiKeyStore)
            Task { await self.reconcileOperatorWorker() }
        }
    }
    @Published var preventSleep: Bool {
        didSet {
            guard !isDemo else { return }
            UserDefaults.standard.set(preventSleep, forKey: "preventSleep")
            applyPowerAssertion()
        }
    }
    @Published private(set) var sleepAssertionHeld: Bool = false

    /// Snapshot of the Operator push worker's status, updated whenever the
    /// worker transitions phase. `nil` when the worker has never started.
    @Published private(set) var operatorWorkerStatus: OperatorWorker.Status?

    let tokenStore: any TokenStore
    let apiKeyStore: any APIKeyStoring
    let logStore: any RequestLogStoring
    private let powerAssertion = PowerAssertion()
    private let logger = Logger(label: "server-host")

    /// When true, the host is a deterministic demo/screenshot stand-in and all
    /// real lifecycle operations are no-ops.
    let isDemo: Bool

    private var httpClient: HTTPClient?
    private var serverTask: Task<Void, Never>?

    /// Active Operator push worker, when enabled. Lives alongside (and
    /// depends on) the HTTP server because the worker dispatches via
    /// loopback.
    private var operatorWorker: OperatorWorker?
    /// Operator base URL the running worker was built with. Compared against the
    /// Review client's before a manual re-run is allowed.
    private var operatorWorkerBaseURL: String?
    private var reconcileTask: Task<Void, Never>?

    /// Observer for OIDC auth-state changes; retained so account changes also
    /// reconcile background Operator-related work.
    /// `nonisolated(unsafe)` so `deinit` can remove it; only ever assigned once
    /// during init and read in `deinit`.
    private nonisolated(unsafe) var authObserver: (any NSObjectProtocol)?

    /// Serialization gate: each lifecycle operation awaits the previous one.
    private var lifecycleGate: Task<Void, Never>?

    convenience init() {
        self.init(demo: DemoMode.isActive)
    }

    init(demo: Bool) {
        if demo {
            // Demo/screenshot mode: deterministic sample data, no Keychain, no
            // network, no real server. The published `state` is pinned to
            // `.running` so the UI renders as if serving traffic.
            let keyStore = InMemoryAPIKeyStore()
            self.apiKeyStore = keyStore
            self.tokenStore = InMemoryTokenStore(initial: DemoData.token)
            self.logStore = InMemoryRequestLogStore(seed: DemoData.requestLog)
            self.config = DemoData.config
            self.preventSleep = true
            self.state = .running(host: DemoData.bindHost, port: DemoData.bindPort)
            self.sleepAssertionHeld = true
            self.isDemo = true
            return
        }

        self.isDemo = false
        #if canImport(Security)
        let keyStore = KeychainAPIKeyStore()
        self.apiKeyStore = keyStore
        self.tokenStore = KeychainTokenStore()
        #else
        let keyStore = InMemoryAPIKeyStore()
        self.apiKeyStore = keyStore
        self.tokenStore = InMemoryTokenStore()
        #endif
        self.config = ConfigPersistence.load(keyStore: keyStore) ?? ServerConfig()
        self.preventSleep = UserDefaults.standard.bool(forKey: "preventSleep")
        do {
            self.logStore = try RequestLogStore()
        } catch {
            self.logStore = InMemoryRequestLogStore()
            logger.error("falling back to in-memory request log: \(error)")
        }

        // Restart the Operator worker when auth state changes so legacy review
        // sign-in transitions still reconcile the worker lifecycle.
        self.authObserver = NotificationCenter.default.addObserver(
            forName: .operatorAuthStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reconcileOperatorWorker()
            }
        }
    }

    deinit {
        if let authObserver {
            NotificationCenter.default.removeObserver(authObserver)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func start() async {
        if isDemo { return }
        // Wait for any prior stop transition to complete.
        await lifecycleGate?.value

        switch state {
        case .stopped, .errored:
            break
        default:
            return
        }
        state = .starting

        if let previousTask = serverTask {
            await previousTask.value
            serverTask = nil
        }

        if let client = httpClient {
            try? await client.shutdown()
            httpClient = nil
        }

        let cfg = config.validated()
        let tokenStore = self.tokenStore
        let logStore = self.logStore
        let logger = self.logger

        if !cfg.isLoopbackHost {
            logger.warning(
                """
                Server binding to non-loopback address \(cfg.bindHost). \
                Traffic (including bearer tokens) is unencrypted. \
                Use a TLS reverse proxy for production deployments.
                """
            )
        }

        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        self.httpClient = client

        let task = Task<Void, Never> { [weak self] in
            let server = TranscriptionServer(
                config: cfg,
                tokenStore: tokenStore,
                logStore: logStore,
                httpClient: client,
                logger: logger
            )
            let app = server.makeApplication()
            let writer = server.logWriter

            // Check for early cancellation before entering runService.
            guard !Task.isCancelled else {
                await MainActor.run {
                    guard let self else { return }
                    self.state = .stopped
                    self.applyPowerAssertion()
                }
                return
            }

            await MainActor.run {
                self?.state = .running(host: cfg.bindHost, port: cfg.bindPort)
                self?.applyPowerAssertion()
            }

            // Start the Operator push worker once the HTTP server is up, since
            // the worker dispatches work via loopback.
            Task { @MainActor [weak self] in
                await self?.reconcileOperatorWorker()
            }

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { await writer.run() }
                    group.addTask { try await app.runService() }
                    // When the app finishes (cancelled or error), shut down the writer.
                    // shutdown() finishes the stream so run() returns naturally;
                    // no cancelAll() needed -- let the group await the writer to completion.
                    try await group.next()
                    await writer.shutdown()
                }
            } catch is CancellationError {
                // Expected on stop — not an error.
                await writer.shutdown()
            } catch {
                await writer.shutdown()
                await MainActor.run {
                    // Skip error publication when cancellation was deliberate.
                    guard self?.state != .stopping else { return }
                    self?.state = .errored(String(describing: error))
                    self?.applyPowerAssertion()
                }
            }
        }
        self.serverTask = task
    }

    func stop() async {
        if isDemo { return }
        guard state.isActive else { return }
        if case .stopping = state { return }
        state = .stopping

        let stopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Stop the worker before tearing down the loopback target.
            await self.stopOperatorWorker()

            // Cancel the server task (triggers CancellationError in runService).
            self.serverTask?.cancel()

            // Await the server task so runService() fully winds down.
            await self.serverTask?.value
            self.serverTask = nil

            // Shut down the HTTP client after the server is done using it.
            if let client = self.httpClient {
                try? await client.shutdown()
            }
            self.httpClient = nil

            self.state = .stopped
            self.applyPowerAssertion()
            self.lifecycleGate = nil
        }

        lifecycleGate = stopTask
        await stopTask.value
    }

    /// Gracefully shuts down the server, awaiting in-flight work and HTTP client
    /// cleanup. Use this from app termination handlers that can defer exit.
    func shutdown() async {
        if isDemo { return }
        guard state.isRunning || state == .starting else { return }
        state = .stopping
        await stopOperatorWorker()
        serverTask?.cancel()
        // Await the server task to allow in-flight requests to drain.
        await serverTask?.value
        serverTask = nil
        if let client = httpClient {
            try? await client.shutdown()
        }
        httpClient = nil
        state = .stopped
        applyPowerAssertion()
    }

    func rotateToken() {
        do {
            _ = try tokenStore.rotate(to: nil)
        } catch {
            logger.error("token rotation failed: \(error)")
        }
    }

    private func applyPowerAssertion() {
        if isDemo {
            sleepAssertionHeld = true
            return
        }
        let shouldHold = preventSleep && state.isRunning
        if shouldHold {
            _ = powerAssertion.acquire()
        } else {
            powerAssertion.release()
        }
        sleepAssertionHeld = powerAssertion.isHeld
    }

    // Starts, stops, or restarts the Operator push worker based on the
    // current configuration, token presence, and server state. Idempotent
    // — safe to call from `didSet` observers and lifecycle transitions.
    //
    // Reconciliations are serialized: each one chains onto the previous, so
    // overlapping calls can never leave two workers running (and polling the
    // same Operator) at once.
    func reconcileOperatorWorker() async {
        let previous = reconcileTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performOperatorWorkerReconcile()
        }
        reconcileTask = task
        await task.value
    }

    // swiftlint:disable:next function_body_length
    private func performOperatorWorkerReconcile() async {
        guard case .running(let host, let port) = state else {
            await stopOperatorWorker()
            return
        }
        let cfg = config.operatorPolling.validated()
        let operatorToken = operatorAPIKey()
        let shouldRun = cfg.enabled
            && cfg.isRunnableWithToken
            && !operatorToken.isEmpty
        guard shouldRun else {
            await stopOperatorWorker()
            return
        }
        // Restart on any meaningful change. Cheap to teardown+rebuild.
        await stopOperatorWorker()
        guard let client = httpClient else { return }
        let opClient = HTTPOperatorClient(
            httpClient: client,
            config: cfg,
            authHeaderProvider: { OperatorPollingConfig.bearerAuthorizationHeader(for: operatorToken) },
            logger: logger
        )
        let channel = URLSessionOperatorWorkChannel(
            config: cfg,
            authHeaderProvider: { OperatorPollingConfig.bearerAuthorizationHeader(for: operatorToken) },
            logger: logger
        )
        let bearer = (try? tokenStore.current()) ?? ""
        let dispatcher = LoopbackOperatorJobDispatcher(
            httpClient: client,
            bindHost: host,
            bindPort: port,
            bearerToken: bearer,
            timeout: .seconds(Int64(config.upstreamTimeout.seconds)),
            maxAudioBytes: config.maxRequestBytes,
            logger: logger
        )
        let worker = OperatorWorker(
            client: opClient,
            dispatcher: dispatcher,
            workChannel: channel,
            reconnectBaseSeconds: cfg.pollIntervalSeconds,
            enabledKinds: Set(cfg.requestedKindList),
            logger: logger,
            onStatusChange: { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.operatorWorkerStatus = status
                }
            }
        )
        self.operatorWorker = worker
        self.operatorWorkerBaseURL = cfg.baseURL
        await worker.start()
    }

    private func stopOperatorWorker() async {
        operatorWorkerBaseURL = nil
        guard let worker = operatorWorker else { return }
        operatorWorker = nil
        await worker.stop()
        operatorWorkerStatus = nil
    }
}

/// Lets the Review surface hand a message to the local push worker for
/// transcription — both for messages that were never transcribed and as a
/// deliberate re-run of one that already has a transcript.
extension ServerHost: TranscriptionRerunRequesting {
    func requestTranscription(messageID: String) async -> Bool {
        guard let worker = operatorWorker, workerTargetsReviewedOperator else { return false }
        return await worker.requestTranscription(messageID: messageID)
    }

    /// Review and the worker are configured independently, so a re-run must be
    /// refused unless both target the same Operator — otherwise the app would
    /// transcribe against a different backend than the one being reviewed.
    private var workerTargetsReviewedOperator: Bool {
        // Compare the URL the *running* worker captured, not the latest edited
        // configuration: reconciliation is asynchronous, so an edit that hasn't
        // restarted the worker yet must not authorize a re-run against the new
        // Operator.
        guard let raw = operatorWorkerBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let workerURL = URL(string: raw) else { return false }
        // Scheme and host are case-insensitive; the path is not, so a tenant
        // prefix like `/TenantA` must not match `/tenanta`.
        func normalized(_ url: URL) -> String {
            var path = url.path
            while path.hasSuffix("/") { path.removeLast() }
            let scheme = (url.scheme ?? "").lowercased()
            let host = (url.host ?? "").lowercased()
            let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
            let explicitPort = url.port.flatMap { $0 == defaultPort ? nil : $0 }
            let port = explicitPort.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)\(path)"
        }
        return normalized(workerURL) == normalized(OperatorAPIConfig.shared.baseURL)
    }
}

#endif
