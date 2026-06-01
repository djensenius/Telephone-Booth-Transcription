import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
import TranscriptionShared
@testable import TranscriptionCore

// MARK: - Mocks

private struct MockModerator: TextModerationService {
    let verdict: ModerationVerdict
    func moderate(_ input: String) async throws -> ModerationVerdict { verdict }
}

private struct ThrowingModerator: TextModerationService {
    let error: OnDeviceServiceError
    func moderate(_ input: String) async throws -> ModerationVerdict { throw error }
}

private struct MockTranslator: TextTranslationService {
    let result: TranslationResult
    func translate(_ input: String, sourceLanguage: String?) async throws -> TranslationResult { result }
}

private struct ThrowingTranslator: TextTranslationService {
    let error: OnDeviceServiceError
    func translate(_ input: String, sourceLanguage: String?) async throws -> TranslationResult { throw error }
}

/// Exercises the on-device branches of `ModerationRoute` / `TextTranslationRoute`
/// with injected mock services so the logic is testable without Apple
/// Intelligence (which is unavailable on CI / the simulator).
@Suite("On-device route backends")
struct OnDeviceRouteTests {
    private func makeUpstream() -> (HTTPClient, OpenAIUpstream, ModerationClassifier, TextTranslator) {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        let upstream = OpenAIUpstream(httpClient: httpClient, logger: Logger(label: "test"))
        let classifier = ModerationClassifier(
            upstream: .defaultModeration, httpClient: httpClient, model: "x", logger: Logger(label: "test"))
        let translator = TextTranslator(
            upstream: .defaultTranslation, httpClient: httpClient, model: "", logger: Logger(label: "test"))
        return (httpClient, upstream, classifier, translator)
    }

    private func decode(_ response: TestResponse) -> [String: Any]? {
        let bytes = response.body.getBytes(at: response.body.readerIndex,
                                           length: response.body.readableBytes) ?? []
        return (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
    }

    @Test func moderationOnDeviceFlagsInput() async throws {
        let (httpClient, upstream, classifier, _) = makeUpstream()
        let verdict = ModerationVerdict(flagged: true, recommendation: "reject", maxScore: 0.9,
                                        model: "apple-foundation-models")
        let route = ModerationRoute<BasicRequestContext>(
            upstream: upstream, upstreamConfig: .defaultModeration, classifier: classifier,
            backend: .onDevice, onDeviceModerator: MockModerator(verdict: verdict),
            maxRequestBytes: 1024, fallbackEnabled: true)
        let router = Router(context: BasicRequestContext.self)
        router.post("/v1/moderations", use: route.handle)
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            try await client.execute(uri: "/v1/moderations", method: .post, headers: headers,
                                      body: ByteBuffer(string: #"{"input":"bad text"}"#)) { response in
                #expect(response.status == .ok)
                let json = decode(response)
                #expect(json?["model"] as? String == "apple-foundation-models")
                let results = json?["results"] as? [[String: Any]]
                #expect(results?.count == 1)
                #expect(results?.first?["flagged"] as? Bool == true)
            }
        }
        try await httpClient.shutdown()
    }

    @Test func moderationOnDeviceUnavailableReturns503() async throws {
        let (httpClient, upstream, classifier, _) = makeUpstream()
        let route = ModerationRoute<BasicRequestContext>(
            upstream: upstream, upstreamConfig: .defaultModeration, classifier: classifier,
            backend: .onDevice, onDeviceModerator: nil,
            maxRequestBytes: 1024, fallbackEnabled: true)
        let router = Router(context: BasicRequestContext.self)
        router.post("/v1/moderations", use: route.handle)
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            try await client.execute(uri: "/v1/moderations", method: .post, headers: headers,
                                      body: ByteBuffer(string: #"{"input":"hello"}"#)) { response in
                #expect(response.status == .serviceUnavailable)
                let err = decode(response)?["error"] as? [String: Any]
                #expect(err?["code"] as? String == "on_device_unavailable")
            }
        }
        try await httpClient.shutdown()
    }

    @Test func moderationOnDeviceMapsServiceError() async throws {
        let (httpClient, upstream, classifier, _) = makeUpstream()
        let route = ModerationRoute<BasicRequestContext>(
            upstream: upstream, upstreamConfig: .defaultModeration, classifier: classifier,
            backend: .onDevice, onDeviceModerator: ThrowingModerator(error: .timeout("slow")),
            maxRequestBytes: 1024, fallbackEnabled: true)
        let router = Router(context: BasicRequestContext.self)
        router.post("/v1/moderations", use: route.handle)
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            try await client.execute(uri: "/v1/moderations", method: .post, headers: headers,
                                      body: ByteBuffer(string: #"{"input":"hi"}"#)) { response in
                #expect(response.status == .gatewayTimeout)
                let err = decode(response)?["error"] as? [String: Any]
                #expect(err?["code"] as? String == "on_device_timeout")
            }
        }
        try await httpClient.shutdown()
    }

    @Test func textTranslationOnDeviceTranslates() async throws {
        let (httpClient, _, _, translator) = makeUpstream()
        let result = TranslationResult(translatedText: "hello", sourceLanguage: "fr",
                                       targetLanguage: "en", model: "apple-foundation-models")
        let route = TextTranslationRoute<BasicRequestContext>(
            translator: translator, backend: .onDevice,
            onDeviceTranslator: MockTranslator(result: result), maxRequestBytes: 1024)
        let router = Router(context: BasicRequestContext.self)
        router.post("/v1/translations", use: route.handle)
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            try await client.execute(uri: "/v1/translations", method: .post, headers: headers,
                                      body: ByteBuffer(string: #"{"input":"bonjour","source_language":"fr"}"#)) { response in
                #expect(response.status == .ok)
                let json = decode(response)
                #expect(json?["translated_text"] as? String == "hello")
                #expect(json?["model"] as? String == "apple-foundation-models")
            }
        }
        try await httpClient.shutdown()
    }

    @Test func textTranslationOnDeviceMapsServiceError() async throws {
        let (httpClient, _, _, translator) = makeUpstream()
        let route = TextTranslationRoute<BasicRequestContext>(
            translator: translator, backend: .onDevice,
            onDeviceTranslator: ThrowingTranslator(error: .timeout("slow")), maxRequestBytes: 1024)
        let router = Router(context: BasicRequestContext.self)
        router.post("/v1/translations", use: route.handle)
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            try await client.execute(uri: "/v1/translations", method: .post, headers: headers,
                                      body: ByteBuffer(string: #"{"input":"bonjour"}"#)) { response in
                #expect(response.status == .gatewayTimeout)
                let err = decode(response)?["error"] as? [String: Any]
                #expect(err?["code"] as? String == "on_device_timeout")
            }
        }
        try await httpClient.shutdown()
    }

    @Test func textTranslationOnDeviceUnavailableReturns503() async throws {
        let (httpClient, _, _, translator) = makeUpstream()
        let route = TextTranslationRoute<BasicRequestContext>(
            translator: translator, backend: .onDevice,
            onDeviceTranslator: nil, maxRequestBytes: 1024)
        let router = Router(context: BasicRequestContext.self)
        router.post("/v1/translations", use: route.handle)
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            try await client.execute(uri: "/v1/translations", method: .post, headers: headers,
                                      body: ByteBuffer(string: #"{"input":"bonjour"}"#)) { response in
                #expect(response.status == .serviceUnavailable)
                let err = decode(response)?["error"] as? [String: Any]
                #expect(err?["code"] as? String == "on_device_unavailable")
            }
        }
        try await httpClient.shutdown()
    }
}
