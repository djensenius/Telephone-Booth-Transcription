import Foundation

/// Configuration for the Operator push worker.
///
/// When enabled and valid, the app subscribes to the Operator status WebSocket,
/// reacts to `work` envelopes for enabled kinds, fetches message inputs, runs
/// the work locally, and posts results back. The struct name is retained to
/// avoid app-wide persistence churn.
///
/// The Operator API token is stored in Keychain under a distinct account from
/// the server's own bearer token and is **not** included in this struct.
public struct OperatorPollingConfig: Sendable, Equatable {
    /// Master toggle. The worker only starts when this is true, `baseURL` is a
    /// valid http(s) URL, and a non-empty Operator API token is configured.
    public var enabled: Bool

    /// Operator base URL, e.g. `https://operator.example.com`. The worker
    /// appends `/v1/ws/status` for status events and `/v1/worker/...` paths for
    /// work input/result calls. Trailing slashes are tolerated.
    public var baseURL: String

    /// Base reconnect delay in seconds. Reconnects use capped exponential
    /// backoff from this value up to roughly 30 seconds.
    public var pollIntervalSeconds: Int

    /// Retained for saved-setting compatibility. Push mode has no lease window.
    public var leaseSeconds: Int

    /// Per-kind enables. Incoming `work.needs` are filtered by these toggles.
    public var transcriptionEnabled: Bool
    public var translationEnabled: Bool
    public var moderationEnabled: Bool

    /// User-Agent string sent with every Operator request.
    ///
    /// The Operator records this alongside every write in its audit trail, so
    /// it is worth keeping it honest about which build posted a result.
    public var userAgent: String

    public init(
        enabled: Bool = false,
        baseURL: String = "",
        pollIntervalSeconds: Int = 5,
        leaseSeconds: Int = 60,
        transcriptionEnabled: Bool = true,
        translationEnabled: Bool = true,
        moderationEnabled: Bool = true,
        userAgent: String = OperatorPollingConfig.defaultUserAgent
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.pollIntervalSeconds = pollIntervalSeconds
        self.leaseSeconds = leaseSeconds
        self.transcriptionEnabled = transcriptionEnabled
        self.translationEnabled = translationEnabled
        self.moderationEnabled = moderationEnabled
        self.userAgent = userAgent
    }

    /// Product name reported in the User-Agent, without the version.
    public static let userAgentProduct = "Telephone-Booth-Transcription"

    /// `Telephone-Booth-Transcription/<app version>`, matching what
    /// `docs/operator-push.md` promises. Falls back to `0.0.0` outside an app
    /// bundle (unit tests, `swift run`), where there is no marketing version.
    public static let defaultUserAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(userAgentProduct)/\(trimmed.isEmpty ? "0.0.0" : trimmed)"
    }()

    public static let minPollInterval = 1
    public static let maxPollInterval = 300
    public static let minLease = 10
    public static let maxLease = 3600

    /// Returns `self` with values clamped to safe ranges; **does not** require
    /// any particular field to be present (use `isRunnableWithToken` to decide
    /// whether to actually start the worker).
    public func validated() -> OperatorPollingConfig {
        var copy = self
        copy.pollIntervalSeconds = max(Self.minPollInterval, min(Self.maxPollInterval, copy.pollIntervalSeconds))
        copy.leaseSeconds = max(Self.minLease, min(Self.maxLease, copy.leaseSeconds))
        copy.baseURL = copy.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: copy.baseURL), let scheme = url.scheme?.lowercased() {
            if copy.baseURL.hasSuffix("/") {
                copy.baseURL = String(copy.baseURL.dropLast())
            }
            if scheme != "http" && scheme != "https" {
                copy.baseURL = ""
            } else if scheme == "http" && !Self.isLoopback(url: url) {
                copy.baseURL = ""
            }
        } else if !copy.baseURL.isEmpty {
            copy.baseURL = ""
        }
        return copy
    }

    /// True when the worker has enough config to subscribe. Token presence is
    /// checked separately at start time (kept out of this struct so a
    /// UserDefaults round-trip never includes the token).
    public var isRunnableWithToken: Bool {
        guard enabled, !baseURL.isEmpty else { return false }
        guard transcriptionEnabled || translationEnabled || moderationEnabled else { return false }
        return usesSecureTokenTransport
    }

    /// True when the Operator URL is safe to receive the static API token.
    public var usesSecureTokenTransport: Bool {
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && Self.isLoopback(url: url)
    }

    /// Formats a Keychain token or preformatted header for the Operator API.
    public static func bearerAuthorizationHeader(for value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("bearer ") { return trimmed }
        return "Bearer \(trimmed)"
    }

    /// Whether the parsed Operator host is loopback (safe for plaintext HTTP).
    public var isLoopback: Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return Self.isLoopback(url: url)
    }

    private static func isLoopback(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let stripped = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        return stripped == "127.0.0.1" || stripped == "::1" || stripped == "localhost"
    }

    /// Comma-separated enabled-kind value retained for existing UI/debug use.
    public var requestedKinds: String {
        requestedKindList.map(\.rawValue).joined(separator: ",")
    }

    /// Typed list of work kinds the per-kind toggles enable, in a stable order.
    public var requestedKindList: [OperatorJob.Kind] {
        var kinds: [OperatorJob.Kind] = []
        if transcriptionEnabled { kinds.append(.transcription) }
        if translationEnabled { kinds.append(.translation) }
        if moderationEnabled { kinds.append(.moderation) }
        return kinds
    }
}
