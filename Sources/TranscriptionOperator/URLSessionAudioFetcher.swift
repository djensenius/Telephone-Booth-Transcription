import Foundation
import Logging
import NIOCore
import TranscriptionShared

/// `AudioFetching` backed by `URLSession` rather than `AsyncHTTPClient`.
///
/// Preferred on iOS: it uses the platform networking stack (ATS, cellular
/// policy, proxy support, background-friendly) and needs no NIO event-loop
/// group to be created and shut down alongside the app. Verification,
/// byte-capping, temp-file staging, and cleanup are all delegated to the shared
/// `AudioFileStaging`, so behavior matches `HTTPClientAudioFetcher` exactly.
///
/// **Privacy:** errors are the same content-free `AudioFetchError` cases used
/// elsewhere. The URL, bytes, and hash never reach a log line.
public final class URLSessionAudioFetcher: AudioFetching {
    /// Supplies an `Authorization` header value for the audio request, or nil
    /// when the audio URL is pre-signed and needs no credential.
    public typealias AuthorizationProvider = @Sendable () async -> String?

    private let urlSession: URLSession
    private let allowInsecureURLs: Bool
    private let authorizationProvider: AuthorizationProvider?
    private let logger: Logger

    public init(
        urlSession: URLSession = .shared,
        allowInsecureURLs: Bool = false,
        authorizationProvider: AuthorizationProvider? = nil,
        logger: Logger = Logger(label: "audio-fetcher-urlsession")
    ) {
        self.urlSession = urlSession
        self.allowInsecureURLs = allowInsecureURLs
        self.authorizationProvider = authorizationProvider
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
        if let authorizationProvider, let header = await authorizationProvider() {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
            logger.debug("audio fetch transport failed: \(type(of: error))")
            throw AudioFetchError.fetchFailed
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw AudioFetchError.fetchFailed
        }

        // Fail fast on an advertised length over the cap so we don't stream a
        // huge body just to reject it. `stage` still enforces the real cap.
        if http.expectedContentLength > 0, http.expectedContentLength > Int64(maxBytes) {
            throw AudioFetchError.tooLarge
        }

        return try await AudioFileStaging.stage(
            chunks: Self.buffered(bytes),
            expectedSHA256: expectedSHA256,
            maxBytes: maxBytes,
            suggestedExtension: suggestedExtension,
            body
        )
    }

    /// Regroups `URLSession`'s byte-at-a-time sequence into `ByteBuffer` chunks
    /// so it can feed `AudioFileStaging.stage`. Chunking keeps the per-element
    /// overhead of the async sequence from dominating large downloads.
    static func buffered(
        _ bytes: URLSession.AsyncBytes,
        chunkSize: Int = 64 * 1024
    ) -> AsyncThrowingStream<ByteBuffer, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var scratch = [UInt8]()
                scratch.reserveCapacity(chunkSize)
                do {
                    for try await byte in bytes {
                        scratch.append(byte)
                        if scratch.count >= chunkSize {
                            continuation.yield(ByteBuffer(bytes: scratch))
                            scratch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !scratch.isEmpty {
                        continuation.yield(ByteBuffer(bytes: scratch))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
