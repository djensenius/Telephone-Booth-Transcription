import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import NIOCore
import NIOPosix
import TranscriptionCore

/// Owns the lifecycle of the embedded HTTP server, the power assertion, and
/// the shared `HTTPClient`. All UI mutations go through this actor.
///
/// Lifecycle transitions are serialized: each call to `start()` or `stop()`
/// awaits any in-flight transition before proceeding, preventing races when the
/// user taps Start/Stop rapidly or the app is exiting.
@MainActor
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
            case .running(let h, let p): return "Running on http://\(h):\(p)"
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
        didSet { ConfigPersistence.save(config) }
    }
    @Published var preventSleep: Bool {
        didSet {
            UserDefaults.standard.set(preventSleep, forKey: "preventSleep")
            applyPowerAssertion()
        }
    }
    @Published private(set) var sleepAssertionHeld: Bool = false

    let tokenStore: any TokenStore
    let logStore: any RequestLogStoring
    private let powerAssertion = PowerAssertion()
    private let logger = Logger(label: "server-host")

    private var httpClient: HTTPClient?
    private var serverTask: Task<Void, Never>?

    /// Serialization gate: each lifecycle operation awaits the previous one.
    private var lifecycleGate: Task<Void, Never>?

    init() {
        self.config = ConfigPersistence.load() ?? ServerConfig()
        self.preventSleep = UserDefaults.standard.bool(forKey: "preventSleep")
        #if canImport(Security)
        self.tokenStore = KeychainTokenStore()
        #else
        self.tokenStore = InMemoryTokenStore()
        #endif
        do {
            self.logStore = try RequestLogStore()
        } catch {
            self.logStore = InMemoryRequestLogStore()
            logger.error("falling back to in-memory request log: \(error)")
        }
    }

    func start() async {
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

        let cfg = config
        let tokenStore = self.tokenStore
        let logStore = self.logStore
        let logger = self.logger

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
        guard state.isActive else { return }
        if case .stopping = state { return }
        state = .stopping

        let stopTask = Task { @MainActor [weak self] in
            guard let self else { return }

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
        guard state.isRunning || state == .starting else { return }
        state = .stopping
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

    func currentToken() -> String {
        (try? tokenStore.current()) ?? ""
    }

    /// Fetches `/v1/models` from one of the user's configured upstreams (or
    /// from this server itself once it's running) so the UI can populate
    /// model pickers. Returns an empty list on any failure.
    func fetchModels(from baseURL: String, apiKey: String?) async -> [String] {
        guard !baseURL.isEmpty,
              let url = URL(string: baseURL.hasSuffix("/")
                            ? "\(baseURL)models"
                            : "\(baseURL)/models") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["data"] as? [[String: Any]] else {
                return []
            }
            return list.compactMap { $0["id"] as? String }.sorted()
        } catch {
            return []
        }
    }

    private func applyPowerAssertion() {
        let shouldHold = preventSleep && state.isRunning
        if shouldHold {
            _ = powerAssertion.acquire()
        } else {
            powerAssertion.release()
        }
        sleepAssertionHeld = powerAssertion.isHeld
    }
}

/// Persists `ServerConfig` to `UserDefaults` as JSON.
enum ConfigPersistence {
    private static let key = "serverConfig.v1"

    static func save(_ config: ServerConfig) {
        let dto = ConfigDTO(config)
        if let data = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> ServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard let dto = try? JSONDecoder().decode(ConfigDTO.self, from: data) else { return nil }
        return dto.asConfig.validated()
    }

    private struct ConfigDTO: Codable {
        var bindHost: String
        var bindPort: Int
        var transcriptionBackendKind: String       // "proxy" | "nativeMacOS" | "appleSpeechAnalyzer"
        var transcriptionBase: String
        var transcriptionKey: String?
        var moderationBase: String
        var moderationKey: String?
        var maxRequestBytes: Int
        var upstreamTimeoutSeconds: Double
        var maxConcurrentRequests: Int
        var logBodies: Bool
        var moderationFallbackEnabled: Bool
        var moderationModel: String
        var defaultTranscriptionModel: String?
        var nativeTranscriptionLocale: String?

        init(_ c: ServerConfig) {
            bindHost = c.bindHost
            bindPort = c.bindPort
            switch c.transcriptionBackend {
            case .proxy(let up):
                transcriptionBackendKind = "proxy"
                transcriptionBase = up.baseURL
                transcriptionKey = up.apiKey
            case .nativeMacOS:
                transcriptionBackendKind = "nativeMacOS"
                transcriptionBase = UpstreamConfig.defaultTranscription.baseURL
                transcriptionKey = nil
            case .appleSpeechAnalyzer:
                transcriptionBackendKind = "appleSpeechAnalyzer"
                transcriptionBase = UpstreamConfig.defaultTranscription.baseURL
                transcriptionKey = nil
            }
            moderationBase = c.moderationUpstream.baseURL
            moderationKey = c.moderationUpstream.apiKey
            maxRequestBytes = c.maxRequestBytes
            upstreamTimeoutSeconds = c.upstreamTimeout.seconds
            maxConcurrentRequests = c.maxConcurrentRequests
            logBodies = c.logBodies
            moderationFallbackEnabled = c.moderationFallbackEnabled
            moderationModel = c.moderationModel
            defaultTranscriptionModel = c.defaultTranscriptionModel
            nativeTranscriptionLocale = c.nativeTranscriptionLocale
        }

        var asConfig: ServerConfig {
            let backend: TranscriptionBackend
            switch transcriptionBackendKind {
            case "nativeMacOS":
                backend = .nativeMacOS
            case "appleSpeechAnalyzer":
                backend = .appleSpeechAnalyzer
            default:
                backend = .proxy(.init(baseURL: transcriptionBase, apiKey: transcriptionKey))
            }
            return ServerConfig(
                bindHost: bindHost,
                bindPort: bindPort,
                transcriptionBackend: backend,
                moderationUpstream: .init(baseURL: moderationBase, apiKey: moderationKey),
                maxRequestBytes: maxRequestBytes,
                upstreamTimeout: .seconds(upstreamTimeoutSeconds),
                maxConcurrentRequests: maxConcurrentRequests,
                logBodies: logBodies,
                moderationFallbackEnabled: moderationFallbackEnabled,
                moderationModel: moderationModel,
                defaultTranscriptionModel: defaultTranscriptionModel ?? "",
                nativeTranscriptionLocale: nativeTranscriptionLocale ?? "en-US"
            )
        }
    }
}
