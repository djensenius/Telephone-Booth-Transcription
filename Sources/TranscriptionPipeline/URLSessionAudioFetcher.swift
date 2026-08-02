import Foundation
import Logging
import TranscriptionShared

/// `AudioFetching` backed by `URLSession` rather than `AsyncHTTPClient`.
///
/// Preferred on iOS: it uses the platform networking stack (ATS, cellular
/// policy, proxy support, background-friendly) and needs no NIO event-loop
/// group to be created and shut down alongside the app. Verification,
/// byte-capping, temp-file staging, and cleanup are all delegated to the shared
/// `AudioFileStaging`, so behavior matches `HTTPClientAudioFetcher` exactly.
///
/// The body is streamed by `StreamingAudioDownload`, which reads
/// `URLSession`'s delegate-delivered `Data` chunks rather than
/// `URLSession.AsyncBytes` — the latter yields one `UInt8` per awaited
/// `next()`, so a large download costs an async iterator call per byte.
///
/// **Privacy:** errors are the same content-free `AudioFetchError` cases used
/// elsewhere. The URL, bytes, and hash never reach a log line.
///
/// **No credentials are sent.** The Operator returns `message.audio.url` as a
/// pre-signed, short-lived Azure Blob SAS URL — the credential is already in
/// the query string, and the host is blob storage rather than the Operator.
/// Attaching the operator's bearer token would hand it to a third party for no
/// benefit, so this fetcher deliberately sends no `Authorization` header, the
/// same as `HTTPClientAudioFetcher`.
public final class URLSessionAudioFetcher: AudioFetching {
    private let urlSession: URLSession
    private let allowInsecureURLs: Bool
    private let logger: Logger

    /// Total wall-clock budget for one audio fetch, matching
    /// `HTTPClientAudioFetcher`'s deadline so both fetchers bound a run the
    /// same way.
    static let fetchTimeout: TimeInterval = 120

    /// Ephemeral, non-caching, credential-free session.
    ///
    /// `URLSession.shared` keeps a persistent URL cache and shared
    /// cookie/credential storage, so a cacheable audio response could survive on
    /// disk after `AudioFileStaging` deleted its temp file — audio outliving the
    /// staging lifecycle is exactly what that cleanup exists to prevent.
    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // `timeoutIntervalForResource` defaults to seven days, so a response
        // that trickles bytes would otherwise pin a review row (and its staging
        // task) effectively forever.
        configuration.timeoutIntervalForRequest = fetchTimeout
        configuration.timeoutIntervalForResource = fetchTimeout
        return URLSession(configuration: configuration)
    }

    public init(
        urlSession: URLSession? = nil,
        allowInsecureURLs: Bool = false,
        logger: Logger = Logger(label: "audio-fetcher-urlsession")
    ) {
        self.urlSession = urlSession ?? Self.makeDefaultSession()
        self.allowInsecureURLs = allowInsecureURLs
        self.logger = logger
    }

    public func withFetchedAudioFile<T: Sendable>(
        url: String,
        expectedSHA256: String,
        maxBytes: Int,
        suggestedExtension: String?,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        // Validate the hash before opening any connection, matching
        // HTTPClientAudioFetcher's ordering.
        guard AudioFileStaging.normalizedSHA256(expectedSHA256) != nil else {
            throw AudioFetchError.invalidExpectedHash
        }
        if !allowInsecureURLs {
            guard url.lowercased().hasPrefix("https://") else {
                throw AudioFetchError.insecureURL
            }
        }
        guard let requestURL = URL(string: url) else {
            throw AudioFetchError.fetchFailed
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"

        let download = StreamingAudioDownload(maxBytes: maxBytes)
        download.start(request, on: urlSession)
        // Cancels a transfer the consumer walked away from (cap exceeded, hash
        // mismatch, body threw). Cancelling a finished task is a no-op.
        defer { download.cancel() }

        let response: URLResponse
        do {
            response = try await download.awaitResponse()
        } catch {
            logger.debug("audio fetch transport failed: \(type(of: error))")
            throw AudioFetchError.fetchFailed
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw AudioFetchError.fetchFailed
        }

        // Fail fast on an advertised length over the cap so we don't stream a
        // huge body just to reject it. The download and `stage` still enforce
        // the real cap.
        if http.expectedContentLength > 0, http.expectedContentLength > Int64(maxBytes) {
            throw AudioFetchError.tooLarge
        }

        return try await AudioFileStaging.stage(
            chunks: download.chunks,
            expectedSHA256: expectedSHA256,
            maxBytes: maxBytes,
            suggestedExtension: suggestedExtension,
            body
        )
    }
}
