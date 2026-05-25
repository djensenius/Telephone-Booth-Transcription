import Foundation

/// Runtime configuration for the transcription server.
///
/// The server proxies OpenAI-compatible endpoints to user-configured upstreams.
/// Two upstreams are independent because LM Studio (the moderation/chat default)
/// does not implement `/v1/audio/transcriptions`, so the transcription default
/// points at a separate local Whisper-compatible server (e.g.
/// `faster-whisper-server` on :8000) that ships an OpenAI-compatible surface.
public struct ServerConfig: Sendable, Equatable {
    public var bindHost: String
    public var bindPort: Int

    /// Backend used for `POST /v1/audio/transcriptions`.
    public var transcriptionBackend: TranscriptionBackend
    /// Moderation upstream. Always a proxy — moderation classification needs
    /// an LLM, which the macOS Speech framework does not provide.
    public var moderationUpstream: UpstreamConfig

    /// Maximum request body the server will accept (bytes). Default 100 MB.
    public var maxRequestBytes: Int
    /// Upstream request timeout (seconds). Default 5 minutes.
    public var upstreamTimeout: TimeAmount
    /// Maximum concurrent in-flight proxied requests. 0 = unlimited.
    public var maxConcurrentRequests: Int

    /// When true, store request/response bodies in the request log.
    /// **Off by default** for privacy; the UI shows a warning when enabled.
    public var logBodies: Bool

    /// When true and the configured moderation upstream does not implement
    /// `/v1/moderations`, the server falls back to a chat-completion based
    /// classifier that returns a best-effort OpenAI-shaped moderation result.
    public var moderationFallbackEnabled: Bool

    /// Model name to pass to the moderation upstream / fallback classifier.
    /// Populated from the user's Settings picker (filled from
    /// `<moderationUpstream>/v1/models`).
    public var moderationModel: String

    /// Default `model` to inject into transcription requests that don't
    /// specify one. Empty string disables injection. Populated from the
    /// user's Settings picker (filled from `<transcriptionUpstream>/v1/models`
    /// for the proxy backend; ignored for the native macOS backend).
    public var defaultTranscriptionModel: String

    /// BCP-47 locale used by the native macOS transcriber (e.g. "en-US").
    public var nativeTranscriptionLocale: String

    /// When true, the server is allowed to bind to non-loopback addresses.
    /// **Off by default** — binding to a LAN/public IP without TLS exposes
    /// bearer tokens and payloads in plaintext. Users must explicitly
    /// acknowledge the risk in Settings before non-loopback binds take effect.
    public var nonLoopbackBindAcknowledged: Bool

    // MARK: - Validation constants

    public static let portRange = 1...65535
    public static let defaultPort = 8089
    public static let maxRequestBytesRange = (1 * 1024 * 1024)...(500 * 1024 * 1024)
    public static let defaultMaxRequestBytes = 100 * 1024 * 1024
    public static let upstreamTimeoutRange = 1.0...600.0
    public static let defaultUpstreamTimeout: Double = 300
    public static let maxConcurrentRequestsRange = 0...256
    public static let defaultMaxConcurrentRequests = 8

    /// Loopback addresses that are considered safe for plaintext HTTP.
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    /// Whether `bindHost` resolves to a loopback-only address.
    public var isLoopbackHost: Bool {
        Self.loopbackHosts.contains(bindHost.lowercased())
    }

    /// Returns a copy with all fields clamped to safe ranges.
    /// Invalid strings fall back to their respective defaults.
    public func validated() -> ServerConfig {
        var copy = self

        // Port
        if !Self.portRange.contains(copy.bindPort) {
            copy.bindPort = Self.defaultPort
        }

        // Bind host
        let trimmedHost = copy.bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            copy.bindHost = "127.0.0.1"
        } else {
            copy.bindHost = trimmedHost
        }

        // Enforce loopback-only unless the user has explicitly acknowledged
        // the security implications of binding to a network-reachable address.
        if !copy.isLoopbackHost && !copy.nonLoopbackBindAcknowledged {
            copy.bindHost = "127.0.0.1"
        }

        // Body limit
        copy.maxRequestBytes = copy.maxRequestBytes.clamped(to: Self.maxRequestBytesRange)

        // Timeout
        copy.upstreamTimeout = .seconds(
            copy.upstreamTimeout.seconds.clamped(to: Self.upstreamTimeoutRange)
        )

        // Concurrency
        copy.maxConcurrentRequests = copy.maxConcurrentRequests.clamped(to: Self.maxConcurrentRequestsRange)

        // Moderation model
        if copy.moderationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.moderationModel = "omni-moderation-latest"
        }

        // Native locale
        if copy.nativeTranscriptionLocale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.nativeTranscriptionLocale = "en-US"
        }

        // Upstream URLs
        copy.moderationUpstream = copy.moderationUpstream.validatedOrDefault(.defaultModeration)
        if case .proxy(let upstream) = copy.transcriptionBackend {
            copy.transcriptionBackend = .proxy(
                upstream.validatedOrDefault(.defaultTranscription)
            )
        }

        // Security: strip API keys from insecure non-loopback upstreams
        copy.moderationUpstream = copy.moderationUpstream.strippingKeyIfInsecure()
        if case .proxy(let upstream) = copy.transcriptionBackend {
            copy.transcriptionBackend = .proxy(upstream.strippingKeyIfInsecure())
        }

        return copy
    }

    public init(
        bindHost: String = "127.0.0.1",
        bindPort: Int = 8089,
        transcriptionBackend: TranscriptionBackend = .proxy(.defaultTranscription),
        moderationUpstream: UpstreamConfig = .defaultModeration,
        maxRequestBytes: Int = 100 * 1024 * 1024,
        upstreamTimeout: TimeAmount = .seconds(300),
        maxConcurrentRequests: Int = 8,
        logBodies: Bool = false,
        moderationFallbackEnabled: Bool = true,
        moderationModel: String = "omni-moderation-latest",
        defaultTranscriptionModel: String = "",
        nativeTranscriptionLocale: String = "en-US",
        nonLoopbackBindAcknowledged: Bool = false
    ) {
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.transcriptionBackend = transcriptionBackend
        self.moderationUpstream = moderationUpstream
        self.maxRequestBytes = maxRequestBytes
        self.upstreamTimeout = upstreamTimeout
        self.maxConcurrentRequests = maxConcurrentRequests
        self.logBodies = logBodies
        self.moderationFallbackEnabled = moderationFallbackEnabled
        self.moderationModel = moderationModel
        self.defaultTranscriptionModel = defaultTranscriptionModel
        self.nativeTranscriptionLocale = nativeTranscriptionLocale
        self.nonLoopbackBindAcknowledged = nonLoopbackBindAcknowledged
    }

    /// The transcription upstream config, when the backend is a proxy. Returns
    /// nil for the native macOS backend.
    public var transcriptionUpstream: UpstreamConfig? {
        if case .proxy(let cfg) = transcriptionBackend { return cfg }
        return nil
    }
}

/// Which engine handles `POST /v1/audio/transcriptions`.
public enum TranscriptionBackend: Sendable, Equatable {
    /// Proxy to an OpenAI-compatible upstream (faster-whisper-server,
    /// OpenAI, any other Whisper-compatible server).
    case proxy(UpstreamConfig)
    /// Use macOS's legacy `SFSpeechRecognizer` for on-device transcription.
    /// Widely supported (50+ locales, no separate asset download) but less
    /// accurate than the macOS 26 `SpeechAnalyzer`. Requires
    /// `NSSpeechRecognitionUsageDescription` and user approval at first use.
    case nativeMacOS
    /// Use macOS 26's `SpeechAnalyzer` + `SpeechTranscriber` (the same engine
    /// behind Apple Intelligence transcription in Notes/Voice Memos). Higher
    /// accuracy, handles long-form audio, fully on-device. Requires per-locale
    /// model assets to be downloaded the first time a given locale is used.
    case appleSpeechAnalyzer
}

public struct UpstreamConfig: Sendable, Equatable {
    /// OpenAI-compatible base URL, e.g. `http://localhost:1234/v1`.
    public var baseURL: String
    /// Optional API key forwarded as `Authorization: Bearer …` to the upstream.
    /// Many local servers (LM Studio, faster-whisper-server) ignore this; OpenAI
    /// requires it.
    public var apiKey: String?

    public init(baseURL: String, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public static let defaultTranscription = UpstreamConfig(
        baseURL: "http://127.0.0.1:8000/v1"
    )

    public static let defaultModeration = UpstreamConfig(
        baseURL: "http://127.0.0.1:1234/v1"
    )

    /// Returns self if baseURL is non-empty and parseable, otherwise `fallback`.
    public func validatedOrDefault(_ fallback: UpstreamConfig) -> UpstreamConfig {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            return fallback
        }
        return UpstreamConfig(baseURL: trimmed, apiKey: apiKey)
    }

    // MARK: - Security validation

    /// Whether the parsed host is a loopback address (safe for plaintext HTTP).
    public var isLoopback: Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else {
            return false
        }
        let stripped = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        return stripped == "127.0.0.1" || stripped == "::1" || stripped == "localhost"
    }

    /// True when an API key is configured and the target is not loopback,
    /// meaning HTTPS is required to protect the key in transit.
    public var requiresSecureTransport: Bool {
        guard let key = apiKey, !key.isEmpty else { return false }
        return !isLoopback
    }

    /// Validates that the upstream URL is safe to receive the configured API key.
    /// Returns `.insecureRemoteWithAPIKey` when a non-loopback URL uses a scheme
    /// other than HTTPS while an API key is present.
    public func validateSecurity() -> Result<Void, UpstreamURLSecurityError> {
        guard requiresSecureTransport else { return .success(()) }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https" else {
            return .failure(.insecureRemoteWithAPIKey(url: trimmed))
        }
        return .success(())
    }

    /// Returns a copy with the API key stripped if security validation fails.
    public func strippingKeyIfInsecure() -> UpstreamConfig {
        switch validateSecurity() {
        case .success:
            return self
        case .failure:
            return UpstreamConfig(baseURL: baseURL, apiKey: nil)
        }
    }
}

/// Security error raised when an upstream URL is not safe for key transmission.
public enum UpstreamURLSecurityError: Error, Sendable, Equatable {
    /// A non-loopback upstream URL does not use HTTPS but has an API key configured.
    case insecureRemoteWithAPIKey(url: String)
}

/// Small Sendable wrapper around a TimeInterval-in-seconds.
public struct TimeAmount: Sendable, Equatable {
    public let seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
    public static func seconds(_ s: Double) -> TimeAmount { .init(seconds: s) }
    public var asNanoseconds: Int64 { Int64(seconds * 1_000_000_000) }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
