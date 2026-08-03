import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import TranscriptionPipeline

/// Legacy `AsyncHTTPClient`-backed audio fetcher used by server integrations.
public final class HTTPClientAudioFetcher: AudioFetching {
    private let httpClient: HTTPClient
    private let timeout: TimeAmount
    private let allowInsecureURLs: Bool
    private let logger: Logger

    public init(
        httpClient: HTTPClient,
        timeout: TimeAmount = .seconds(120),
        allowInsecureURLs: Bool = false,
        logger: Logger = Logger(label: "audio-fetcher")
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
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
        guard AudioFileStaging.normalizedSHA256(expectedSHA256) != nil else {
            throw AudioFetchError.invalidExpectedHash
        }
        if !allowInsecureURLs {
            guard url.lowercased().hasPrefix("https://") else {
                throw AudioFetchError.insecureURL
            }
        }

        var request = HTTPClientRequest(url: url)
        request.method = .GET
        let response: HTTPClientResponse
        do {
            response = try await httpClient.execute(request, deadline: NIODeadline.now() + timeout)
        } catch {
            logger.debug("audio fetch transport failed: \(type(of: error))")
            throw AudioFetchError.fetchFailed
        }
        guard (200..<300).contains(Int(response.status.code)) else {
            throw AudioFetchError.fetchFailed
        }

        return try await AudioFileStaging.stage(
            chunks: response.body,
            expectedSHA256: expectedSHA256,
            maxBytes: maxBytes,
            suggestedExtension: suggestedExtension,
            body
        )
    }
}
