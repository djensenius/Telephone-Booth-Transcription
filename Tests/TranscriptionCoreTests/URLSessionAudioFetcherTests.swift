import Crypto
import Foundation
import NIOCore
import Testing
import TranscriptionOperator
import TranscriptionShared

/// Stubs the network for `URLSessionAudioFetcher` so the tests exercise the
/// real fetcher (header, status handling, chunking, staging, cleanup) without
/// opening a socket.
final class StubAudioURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int = 200
        var body: Data = Data()
        /// Set to advertise a Content-Length that differs from `body`, to test
        /// the fail-fast cap independently of the streaming cap.
        var advertisedLength: Int?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub = Stub()
    nonisolated(unsafe) private static var observedAuthorization: String?

    static func install(_ newStub: Stub) {
        lock.lock()
        defer { lock.unlock() }
        stub = newStub
        observedAuthorization = nil
    }

    static func lastAuthorization() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return observedAuthorization
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAudioURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let stub = Self.stub
        Self.observedAuthorization = request.value(forHTTPHeaderField: "Authorization")
        Self.lock.unlock()

        let length = stub.advertisedLength ?? stub.body.count
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(length)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("URLSessionAudioFetcher", .serialized)
struct URLSessionAudioFetcherTests {
    private static let url = "https://operator.test/audio/msg.flac"

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeFetcher() -> URLSessionAudioFetcher {
        URLSessionAudioFetcher(urlSession: StubAudioURLProtocol.makeSession())
    }

    /// The hash is validated before any connection is opened, matching
    /// `HTTPClientAudioFetcher`'s ordering — so a bad hash beats a bad scheme.
    @Test func rejectsInvalidHashBeforeConnecting() async {
        let fetcher = makeFetcher()
        await #expect(throws: AudioFetchError.invalidExpectedHash) {
            _ = try await fetcher.withFetchedAudioFile(
                url: "http://operator.test/a.flac",
                expectedSHA256: "not-a-digest",
                maxBytes: 1_000,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    @Test func rejectsPlaintextHTTP() async {
        let fetcher = makeFetcher()
        await #expect(throws: AudioFetchError.insecureURL) {
            _ = try await fetcher.withFetchedAudioFile(
                url: "http://operator.test/a.flac",
                expectedSHA256: String(repeating: "a", count: 64),
                maxBytes: 1_000,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    @Test func rejectsMalformedURL() async {
        let fetcher = URLSessionAudioFetcher(
            urlSession: StubAudioURLProtocol.makeSession(),
            allowInsecureURLs: true
        )
        await #expect(throws: AudioFetchError.fetchFailed) {
            _ = try await fetcher.withFetchedAudioFile(
                url: "",
                expectedSHA256: String(repeating: "b", count: 64),
                maxBytes: 1_000,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    @Test func fetchesVerifiesAndStagesToTempFile() async throws {
        let payload = Data("on-device audio bytes".utf8)
        StubAudioURLProtocol.install(.init(body: payload))

        var stagedPath: URL?
        let staged: (path: URL, data: Data) = try await makeFetcher().withFetchedAudioFile(
            url: Self.url,
            expectedSHA256: digest(payload),
            maxBytes: 1_000_000,
            suggestedExtension: "flac"
        ) { fileURL in
            (fileURL, try Data(contentsOf: fileURL))
        }
        stagedPath = staged.path

        #expect(staged.path.pathExtension == "flac")
        #expect(staged.data == payload)
        // The staging helper must delete the temp file once the body returns.
        #expect(!FileManager.default.fileExists(atPath: stagedPath!.path))
    }

    /// Exercises `buffered`'s chunk boundary: a payload spanning several 64 KB
    /// chunks plus a partial trailing chunk must reassemble byte-for-byte.
    @Test func reassemblesMultiChunkPayload() async throws {
        // Written out in steps: as a single expression the type checker times
        // out on some toolchains.
        let count: Int = 64 * 1024 * 2 + 517
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for index in 0..<count {
            bytes.append(UInt8(index % 251))
        }
        let payload = Data(bytes)
        StubAudioURLProtocol.install(.init(body: payload))

        let staged: Data = try await makeFetcher().withFetchedAudioFile(
            url: Self.url,
            expectedSHA256: digest(payload),
            maxBytes: 1_000_000,
            suggestedExtension: nil
        ) { try Data(contentsOf: $0) }

        #expect(staged == payload)
    }

    @Test func detectsHashMismatch() async {
        StubAudioURLProtocol.install(.init(body: Data("actual bytes".utf8)))
        let wrong = digest(Data("different bytes".utf8))

        await #expect(throws: AudioFetchError.hashMismatch) {
            _ = try await makeFetcher().withFetchedAudioFile(
                url: Self.url,
                expectedSHA256: wrong,
                maxBytes: 1_000_000,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    /// An honest Content-Length over the cap is rejected before streaming.
    @Test func failsFastOnAdvertisedLengthOverCap() async {
        StubAudioURLProtocol.install(.init(body: Data(repeating: 0x7A, count: 4096)))

        await #expect(throws: AudioFetchError.tooLarge) {
            _ = try await makeFetcher().withFetchedAudioFile(
                url: Self.url,
                expectedSHA256: String(repeating: "c", count: 64),
                maxBytes: 128,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    /// A lying (or absent) Content-Length must still be caught mid-stream by
    /// `AudioFileStaging`.
    @Test func enforcesCapWhenLengthIsUnderstated() async {
        StubAudioURLProtocol.install(
            .init(body: Data(repeating: 0x7A, count: 4096), advertisedLength: 0)
        )

        await #expect(throws: AudioFetchError.tooLarge) {
            _ = try await makeFetcher().withFetchedAudioFile(
                url: Self.url,
                expectedSHA256: String(repeating: "c", count: 64),
                maxBytes: 128,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    @Test func nonSuccessStatusFails() async {
        StubAudioURLProtocol.install(.init(status: 404))

        await #expect(throws: AudioFetchError.fetchFailed) {
            _ = try await makeFetcher().withFetchedAudioFile(
                url: Self.url,
                expectedSHA256: String(repeating: "d", count: 64),
                maxBytes: 1_000,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    /// `message.audio.url` is a pre-signed Azure Blob SAS URL: the credential
    /// is already in the query string and the host is a third party, not the
    /// Operator. Sending the operator's bearer token there would leak it for no
    /// benefit, so the fetcher must never attach one.
    @Test func neverSendsCredentialsToBlobStorage() async throws {
        let payload = Data("pre-signed".utf8)
        StubAudioURLProtocol.install(.init(body: payload))

        _ = try await makeFetcher().withFetchedAudioFile(
            url: Self.url + "?sv=2024-01-01&sig=redacted",
            expectedSHA256: digest(payload),
            maxBytes: 1_000_000,
            suggestedExtension: nil
        ) { _ in 0 }

        #expect(StubAudioURLProtocol.lastAuthorization() == nil)
    }
}
