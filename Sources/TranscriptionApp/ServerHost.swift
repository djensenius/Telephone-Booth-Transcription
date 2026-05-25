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
        didSet { ConfigPersistence.save(config, keyStore: apiKeyStore) }
    }
    @Published var preventSleep: Bool {
        didSet {
            UserDefaults.standard.set(preventSleep, forKey: "preventSleep")
            applyPowerAssertion()
        }
    }
    @Published private(set) var sleepAssertionHeld: Bool = false

    let tokenStore: any TokenStore
    let apiKeyStore: any APIKeyStoring
    let logStore: any RequestLogStoring
    private let powerAssertion = PowerAssertion()
    private let logger = Logger(label: "server-host")

    private var httpClient: HTTPClient?
    private var serverTask: Task<Void, Never>?

    /// Serialization gate: each lifecycle operation awaits the previous one.
    private var lifecycleGate: Task<Void, Never>?

    init() {
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

        let cfg = config.validated()
        let tokenStore = self.tokenStore
        let logStore = self.logStore
        let logger = self.logger

        if !cfg.isLoopbackHost {
            logger.warning(
                "Server binding to non-loopback address \(cfg.bindHost). Traffic (including bearer tokens) is unencrypted. Use a TLS reverse proxy for production deployments."
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

    /// Returns the transcription upstream API key from Keychain, or empty string.
    func transcriptionAPIKey() -> String {
        (try? apiKeyStore.read(account: APIKeyAccount.transcription)) ?? ""
    }

    /// Returns the moderation upstream API key from Keychain, or empty string.
    func moderationAPIKey() -> String {
        (try? apiKeyStore.read(account: APIKeyAccount.moderation)) ?? ""
    }

    /// Persists the transcription API key to Keychain and updates the in-memory config.
    func setTranscriptionAPIKey(_ value: String) {
        let key = value.isEmpty ? nil : value
        if case .proxy(var up) = config.transcriptionBackend {
            up.apiKey = key
            config.transcriptionBackend = .proxy(up)
        }
    }

    /// Persists the moderation API key to Keychain and updates the in-memory config.
    func setModerationAPIKey(_ value: String) {
        config.moderationUpstream.apiKey = value.isEmpty ? nil : value
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
///
/// API keys are stored in the macOS Keychain (via `APIKeyStoring`), **not** in
/// UserDefaults. A one-time migration moves any keys that were previously
/// serialized in the DTO into Keychain.
enum ConfigPersistence {
    private static let key = "serverConfig.v1"

    static func save(_ config: ServerConfig, keyStore: any APIKeyStoring) {
        let dto = ConfigDTO(config)
        if let data = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Persist API keys in Keychain
        if case .proxy(let up) = config.transcriptionBackend {
            persistKey(up.apiKey, account: APIKeyAccount.transcription, store: keyStore)
        } else {
            persistKey(nil, account: APIKeyAccount.transcription, store: keyStore)
        }
        persistKey(config.moderationUpstream.apiKey, account: APIKeyAccount.moderation, store: keyStore)
    }

    static func load(keyStore: any APIKeyStoring) -> ServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard var dto = try? JSONDecoder().decode(ConfigDTO.self, from: data) else { return nil }

        // One-time migration: move keys from DTO into Keychain.
        // Only clear a key from the DTO if the Keychain write succeeds,
        // so a locked Keychain doesn't permanently lose the key.
        var migrated = false
        if let tKey = dto.transcriptionKey, !tKey.isEmpty {
            do {
                try keyStore.write(account: APIKeyAccount.transcription, value: tKey)
                dto.transcriptionKey = nil
                migrated = true
            } catch {
                // Leave in DTO for retry on next launch
            }
        }
        if let mKey = dto.moderationKey, !mKey.isEmpty {
            do {
                try keyStore.write(account: APIKeyAccount.moderation, value: mKey)
                dto.moderationKey = nil
                migrated = true
            } catch {
                // Leave in DTO for retry on next launch
            }
        }
        if migrated, let cleaned = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(cleaned, forKey: key)
        }

        // Inject keys from Keychain into the config
        var config = dto.asConfig
        let transcriptionKey = try? keyStore.read(account: APIKeyAccount.transcription)
        let moderationKey = try? keyStore.read(account: APIKeyAccount.moderation)
        if case .proxy(var up) = config.transcriptionBackend {
            up.apiKey = transcriptionKey
            config.transcriptionBackend = .proxy(up)
        }
        config.moderationUpstream.apiKey = moderationKey
        return config.validated()
    }

    private static func persistKey(_ value: String?, account: String, store: any APIKeyStoring) {
        if let key = value, !key.isEmpty {
            try? store.write(account: account, value: key)
        } else {
            try? store.delete(account: account)
        }
    }

    private struct ConfigDTO: Codable {
        var bindHost: String
        var bindPort: Int
        var transcriptionBackendKind: String       // "proxy" | "nativeMacOS" | "appleSpeechAnalyzer"
        var transcriptionBase: String
        // Retained for migration decoding only — never written to new saves.
        var transcriptionKey: String?
        var moderationBase: String
        // Retained for migration decoding only — never written to new saves.
        var moderationKey: String?
        var maxRequestBytes: Int
        var upstreamTimeoutSeconds: Double
        var maxConcurrentRequests: Int
        var logBodies: Bool
        var moderationFallbackEnabled: Bool
        var moderationModel: String
        var defaultTranscriptionModel: String?
        var nativeTranscriptionLocale: String?
        var nonLoopbackBindAcknowledged: Bool?

        init(_ c: ServerConfig) {
            bindHost = c.bindHost
            bindPort = c.bindPort
            switch c.transcriptionBackend {
            case .proxy(let up):
                transcriptionBackendKind = "proxy"
                transcriptionBase = up.baseURL
            case .nativeMacOS:
                transcriptionBackendKind = "nativeMacOS"
                transcriptionBase = UpstreamConfig.defaultTranscription.baseURL
            case .appleSpeechAnalyzer:
                transcriptionBackendKind = "appleSpeechAnalyzer"
                transcriptionBase = UpstreamConfig.defaultTranscription.baseURL
            }
            // Keys are never serialized to UserDefaults
            transcriptionKey = nil
            moderationBase = c.moderationUpstream.baseURL
            moderationKey = nil
            maxRequestBytes = c.maxRequestBytes
            upstreamTimeoutSeconds = c.upstreamTimeout.seconds
            maxConcurrentRequests = c.maxConcurrentRequests
            logBodies = c.logBodies
            moderationFallbackEnabled = c.moderationFallbackEnabled
            moderationModel = c.moderationModel
            defaultTranscriptionModel = c.defaultTranscriptionModel
            nativeTranscriptionLocale = c.nativeTranscriptionLocale
            nonLoopbackBindAcknowledged = c.nonLoopbackBindAcknowledged
        }

        var asConfig: ServerConfig {
            let backend: TranscriptionBackend
            switch transcriptionBackendKind {
            case "nativeMacOS":
                backend = .nativeMacOS
            case "appleSpeechAnalyzer":
                backend = .appleSpeechAnalyzer
            default:
                backend = .proxy(.init(baseURL: transcriptionBase, apiKey: nil))
            }
            return ServerConfig(
                bindHost: bindHost,
                bindPort: bindPort,
                transcriptionBackend: backend,
                moderationUpstream: .init(baseURL: moderationBase, apiKey: nil),
                maxRequestBytes: maxRequestBytes,
                upstreamTimeout: .seconds(upstreamTimeoutSeconds),
                maxConcurrentRequests: maxConcurrentRequests,
                logBodies: logBodies,
                moderationFallbackEnabled: moderationFallbackEnabled,
                moderationModel: moderationModel,
                defaultTranscriptionModel: defaultTranscriptionModel ?? "",
                nativeTranscriptionLocale: nativeTranscriptionLocale ?? "en-US",
                nonLoopbackBindAcknowledged: nonLoopbackBindAcknowledged ?? false
            )
        }
    }
}
