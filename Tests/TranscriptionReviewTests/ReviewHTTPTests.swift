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
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = Self.readBody(from: request)
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

    /// URLSession moves a request's `httpBody` into `httpBodyStream` before it
    /// reaches the protocol, so read the stream to recover the posted bytes.
    static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

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
        StubURLProtocol.lastBody = nil
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

    @Test("submitDecision POSTs the decision and decodes the message")
    func submitDecision() async throws {
        let messageBody = """
        {"id":"m","status":"approved","questionId":null,"notes":"looks good",
         "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
         "audio":{"url":"https://e.com/m.flac","sha256":"a","durationMs":null},
         "latestTranscription":null,"latestModeration":null}
        """
        let client = client(status: 200, body: messageBody)
        let message = try await client.submitDecision(messageID: "m", decision: .approve, notes: "looks good")
        #expect(message.status == .approved)

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.hasSuffix("/v1/messages/m/decision") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let sent = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(json["decision"] as? String == "approve")
        #expect(json["notes"] as? String == "looks good")
    }

    @Test("submitDecision omits blank notes")
    func submitDecisionBlankNotes() async throws {
        let messageBody = """
        {"id":"m","status":"rejected","questionId":null,"notes":null,
         "createdAt":"2026-01-02T03:04:05Z","receivedAt":null,
         "audio":{"url":"https://e.com/m.flac","sha256":"a","durationMs":null},
         "latestTranscription":null,"latestModeration":null}
        """
        let client = client(status: 200, body: messageBody)
        _ = try await client.submitDecision(messageID: "m", decision: .reject, notes: "   ")
        let sent = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(json["notes"] == nil || json["notes"] is NSNull)
    }

    @Test("submitTranslation POSTs the text and decodes the transcription")
    func submitTranslation() async throws {
        let body = """
        {"id":"t","messageId":"m","provider":"openai","model":null,
         "status":"succeeded","text":"hola","language":"es","durationMs":null,"latencyMs":null,
         "error":null,"requestedById":null,"createdAt":"2026-01-02T03:04:07Z","completedAt":null,
         "translationStatus":"succeeded","translatedText":"hello","translatedLanguage":"en",
         "translationProvider":null,"translationModel":null,"translationError":null,
         "translationLatencyMs":null,"translationCompletedAt":"2026-01-02T03:05:00Z"}
        """
        let client = client(status: 200, body: body)
        let transcription = try await client.submitTranslation(
            messageID: "m", translatedText: "hello", translatedLanguage: "en"
        )
        #expect(transcription.translatedText == "hello")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.hasSuffix("/v1/messages/m/translation") == true)

        let sent = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(json["translatedText"] as? String == "hello")
        #expect(json["translatedLanguage"] as? String == "en")
    }

    @Test("decodes the Operator error envelope into .api")
    func decodesErrorEnvelope() async {
        let client = client(status: 409, body: #"{"error":"message_not_decidable"}"#)
        await #expect(throws: OperatorReviewError.api(status: 409, code: "message_not_decidable")) {
            _ = try await client.submitDecision(messageID: "m", decision: .approve, notes: nil)
        }
    }

    @Test("falls back to .http when the body has no error code")
    func errorWithoutEnvelope() async {
        let client = client(status: 500, body: "boom")
        await #expect(throws: OperatorReviewError.http(500)) {
            _ = try await client.submitTranslation(messageID: "m", translatedText: "x", translatedLanguage: nil)
        }
    }
}
