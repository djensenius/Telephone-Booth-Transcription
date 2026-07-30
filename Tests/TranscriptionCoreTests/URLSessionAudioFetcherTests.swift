import Crypto
import Foundation
import NIOCore
import Testing
@testable import TranscriptionOperator
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
        /// Delivers the body in slices of this size, mimicking the several
        /// `didReceive data:` callbacks a real transfer produces.
        var sliceSize: Int?
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
            let slice = stub.sliceSize ?? stub.body.count
            var offset = 0
            while offset < stub.body.count {
                let end = min(offset + slice, stub.body.count)
                client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
                offset = end
            }
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

    /// Exercises the chunk boundary: a payload spanning several 64 KB
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
        StubAudioURLProtocol.install(.init(body: payload, sliceSize: 16 * 1024))

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

/// Drives `StreamingAudioDownload`'s delegate callbacks directly, which is the
/// only way to observe chunk delivery and the mid-stream cap without a real
/// transfer.
@Suite("StreamingAudioDownload")
struct StreamingAudioDownloadTests {
    private func makeTask() -> (URLSession, URLSessionDataTask) {
        let session = URLSession(configuration: .ephemeral)
        return (session, session.dataTask(with: URL(string: "https://operator.test/a.flac")!))
    }

    /// Chunks arrive as the OS delivered them — one awaited `next()` per
    /// `didReceive data:`, not per byte.
    @Test func deliversOneChunkPerCallback() async throws {
        let (session, task) = makeTask()
        let download = StreamingAudioDownload(maxBytes: 1_000)
        download.urlSession(session, dataTask: task, didReceive: Data([1, 2, 3]))
        download.urlSession(session, dataTask: task, didReceive: Data([4, 5]))
        download.urlSession(session, task: task, didCompleteWithError: nil)

        var iterator = download.chunks.makeAsyncIterator()
        #expect(try await iterator.next()?.readableBytes == 3)
        #expect(try await iterator.next()?.readableBytes == 2)
        #expect(try await iterator.next() == nil)
    }

    /// The cap is enforced as bytes arrive, so a response with a missing or
    /// understated `Content-Length` can't stream far past it.
    @Test func failsAsSoonAsTheCapIsPassed() async {
        let (session, task) = makeTask()
        let download = StreamingAudioDownload(maxBytes: 4)
        download.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x01, count: 3))
        download.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x01, count: 3))

        var iterator = download.chunks.makeAsyncIterator()
        await #expect(throws: AudioFetchError.tooLarge) {
            // The buffered prefix is discarded, so a partial body can't be
            // consumed as if it were whole.
            _ = try await iterator.next()
        }
    }

    /// A consumer waiting on an empty buffer is handed the next chunk directly.
    @Test func handsOffToAWaitingConsumer() async throws {
        let (session, task) = makeTask()
        let download = StreamingAudioDownload(maxBytes: 1_000)
        var iterator = download.chunks.makeAsyncIterator()

        async let first = iterator.next()
        // Give the consumer a chance to park on the empty buffer.
        try await Task.sleep(for: .milliseconds(20))
        download.urlSession(session, dataTask: task, didReceive: Data([7, 7, 7, 7]))

        #expect(try await first?.readableBytes == 4)
    }

    /// A transport failure surfaces as the content-free fetch error rather than
    /// ending the sequence as if the body were complete.
    @Test func transportFailureThrows() async {
        let (session, task) = makeTask()
        let download = StreamingAudioDownload(maxBytes: 1_000)
        download.urlSession(session, dataTask: task, didReceive: Data([1]))
        download.urlSession(
            session, task: task,
            didCompleteWithError: URLError(.networkConnectionLost)
        )

        var iterator = download.chunks.makeAsyncIterator()
        await #expect(throws: AudioFetchError.fetchFailed) {
            _ = try await iterator.next()
        }
    }
}
