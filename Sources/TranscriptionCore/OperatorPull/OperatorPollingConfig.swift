import Foundation

/// Configuration for the Operator-pull worker.
///
/// When enabled and valid, the app polls `baseURL` every
/// `pollIntervalSeconds` for queued transcription, translation, and
/// moderation jobs, runs them locally against the same backend
/// implementations the HTTP routes use, and submits results back. This is
/// the inverse of the existing push-in mode (Operator → this app's HTTP
/// server): it lets the Operator run anywhere reachable by this Mac without
/// requiring inbound reachability the other direction.
///
/// The Operator's API token is stored in Keychain under a distinct account
/// from the server's own bearer token and is **not** included in this
/// struct.
public struct OperatorPollingConfig: Sendable, Equatable {
    /// Master toggle. The worker only starts when this is true, `baseURL`
    /// is a valid http(s) URL, and a non-empty API token is configured.
    public var enabled: Bool

    /// Operator base URL, e.g. `https://operator.example.com`. The worker
    /// appends `/v1/jobs/...` paths. Trailing slashes are tolerated.
    public var baseURL: String

    /// Poll cadence in seconds. Clamped at runtime to `[1, 300]`.
    public var pollIntervalSeconds: Int

    /// Lease duration the worker asks for when claiming a job, in seconds.
    /// The worker submits the result well before this expires.
    public var leaseSeconds: Int

    /// Per-kind enables. The worker requests
    /// `?kinds=transcription,translation,moderation` filtered by these.
    public var transcriptionEnabled: Bool
    public var translationEnabled: Bool
    public var moderationEnabled: Bool

    /// User-Agent string sent with every Operator request.
    public var userAgent: String

    public init(
        enabled: Bool = false,
        baseURL: String = "",
        pollIntervalSeconds: Int = 5,
        leaseSeconds: Int = 60,
        transcriptionEnabled: Bool = true,
        translationEnabled: Bool = true,
        moderationEnabled: Bool = true,
        userAgent: String = "Telephone-Booth-Transcription/1.0"
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

    public static let minPollInterval = 1
    public static let maxPollInterval = 300
    public static let minLease = 10
    public static let maxLease = 3600

    /// Returns `self` with values clamped to safe ranges; **does not**
    /// require any particular field to be present (use `isRunnable` to
    /// decide whether to actually start the worker).
    public func validated() -> OperatorPollingConfig {
        var copy = self
        copy.pollIntervalSeconds = max(Self.minPollInterval, min(Self.maxPollInterval, copy.pollIntervalSeconds))
        copy.leaseSeconds = max(Self.minLease, min(Self.maxLease, copy.leaseSeconds))
        copy.baseURL = copy.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: copy.baseURL), let scheme = url.scheme {
            // Strip trailing `/` for predictable joining.
            if copy.baseURL.hasSuffix("/") {
                copy.baseURL = String(copy.baseURL.dropLast())
            }
            // Refuse `file:` and other non-http schemes by clearing.
            if scheme != "http" && scheme != "https" {
                copy.baseURL = ""
            }
        } else if !copy.baseURL.isEmpty {
            copy.baseURL = ""
        }
        return copy
    }

    /// True when the worker has enough config to actually start polling.
    /// Token presence is checked separately at start time (kept out of this
    /// struct so a UserDefaults round-trip never includes the token).
    public var isRunnableWithToken: Bool {
        guard enabled, !baseURL.isEmpty else { return false }
        guard transcriptionEnabled || translationEnabled || moderationEnabled else { return false }
        return URL(string: baseURL)?.scheme.flatMap { ["http", "https"].contains($0) } == true
    }

    /// Comma-separated `kinds` query value derived from per-kind enables.
    public var requestedKinds: String {
        var kinds: [String] = []
        if transcriptionEnabled { kinds.append("transcription") }
        if translationEnabled { kinds.append("translation") }
        if moderationEnabled { kinds.append("moderation") }
        return kinds.joined(separator: ",")
    }
}
