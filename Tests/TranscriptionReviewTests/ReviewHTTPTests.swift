//
//  ReviewHTTPTests.swift
//  TranscriptionReviewTests
//
//  Exercises HTTPOperatorReviewClient request building and response mapping
//  against a stubbed URLProtocol so no real network is touched.
//

import Foundation
import Testing
@testable import TranscriptionReview

/// Captures the last request and returns a scripted response.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int
        var body: Data
    }

    nonisolated(unsafe) static var stub = Stub(statusCode: 200, body: Data("{}".utf8))
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.stub.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private struct FixedToken: BearerTokenProviding {
    let header: String?
    func authorizationHeader() async -> String? { header }
}

@Suite("HTTPOperatorReviewClient", .serialized)
struct ReviewHTTPTests {
    private func client(status: Int, body: String, token: String? = "Bearer abc") -> HTTPOperatorReviewClient {
        StubURLProtocol.stub = .init(statusCode: status, body: Data(body.utf8))
        StubURLProtocol.lastRequest = nil
        return HTTPOperatorReviewClient(
            config: OperatorAPIConfig(baseURL: URL(string: "https://api.example.com")!),
            tokenProvider: FixedToken(header: token),
            urlSession: StubURLProtocol.makeSession()
        )
    }

    @Test("attaches Authorization header and encodes query")
    func attachesHeaderAndQuery() async throws {
        let client = client(status: 200, body: #"{"items":[]}"#)
        _ = try await client.fetchMessages(status: .pending, since: nil, limit: 25)
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("/v1/messages"))
        #expect(url.contains("limit=25"))
        #expect(url.contains("status=pending"))
    }

    @Test("maps 401 to unauthorized")
    func maps401() async {
        let client = client(status: 401, body: "{}")
        await #expect(throws: OperatorReviewError.unauthorized) {
            _ = try await client.fetchMessages(status: nil, since: nil, limit: 10)
        }
    }

    @Test("maps 500 to http(code)")
    func maps500() async {
        let client = client(status: 500, body: "{}")
        await #expect(throws: OperatorReviewError.http(500)) {
            _ = try await client.fetchMessages(status: nil, since: nil, limit: 10)
        }
    }

    @Test("invalid JSON throws")
    func invalidJSON() async {
        let client = client(status: 200, body: "not json")
        await #expect(throws: (any Error).self) {
            _ = try await client.fetchMessages(status: nil, since: nil, limit: 10)
        }
    }

    @Test("decodes the transcriptions endpoint")
    func decodesTranscriptions() async throws {
        let body = """
        {"items":[{"id":"t","messageId":"m","provider":"openai","model":null,
          "status":"succeeded","text":"hi","language":"en","durationMs":null,"latencyMs":null,
          "error":null,"requestedById":null,"createdAt":"2026-01-02T03:04:07Z","completedAt":null,
          "translationStatus":null,"translatedText":null,"translatedLanguage":null,
          "translationProvider":null,"translationModel":null,"translationError":null,
          "translationLatencyMs":null,"translationCompletedAt":null}]}
        """
        let client = client(status: 200, body: body)
        let list = try await client.fetchTranscriptions(messageID: "m")
        #expect(list.items.count == 1)
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/v1/messages/m/transcriptions") == true)
    }
}
