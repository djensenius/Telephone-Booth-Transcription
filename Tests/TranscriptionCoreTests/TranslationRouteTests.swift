import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
@testable import TranscriptionCore

@Suite("TranslationRoute + TextTranslationRoute")
struct TranslationRouteTests {
    /// `POST /v1/audio/translations` without auth must be rejected like any
    /// other authenticated route. Confirms the route is wired into the router
    /// and sits behind `AuthMiddleware`.
    @Test func audioTranslationsRequiresAuth() async throws {
        let tokenStore = InMemoryTokenStore(initial: "valid-token")
        let logStore = InMemoryRequestLogStore()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        let server = TranscriptionServer(
            config: ServerConfig(),
            tokenStore: tokenStore,
            logStore: logStore,
            httpClient: httpClient,
            logger: Logger(label: "test")
        )
        let app = Application(
            router: server.makeRouter(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/audio/translations", method: .post) { response in
                #expect(response.status == .unauthorized)
            }
        }
        try await httpClient.shutdown()
    }

    /// `POST /v1/translations` (custom JSON) without auth must be rejected.
    @Test func textTranslationsRequiresAuth() async throws {
        let tokenStore = InMemoryTokenStore(initial: "valid-token")
        let logStore = InMemoryRequestLogStore()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        let server = TranscriptionServer(
            config: ServerConfig(),
            tokenStore: tokenStore,
            logStore: logStore,
            httpClient: httpClient,
            logger: Logger(label: "test")
        )
        let app = Application(
            router: server.makeRouter(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/translations", method: .post) { response in
                #expect(response.status == .unauthorized)
            }
        }
        try await httpClient.shutdown()
    }

    /// Missing Content-Type on audio translations must produce a 400 with the
    /// standard error envelope.
    @Test func audioTranslationsRejectsMissingContentType() async throws {
        let token = "tok"
        let tokenStore = InMemoryTokenStore(initial: token)
        let logStore = InMemoryRequestLogStore()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        let server = TranscriptionServer(
            config: ServerConfig(),
            tokenStore: tokenStore,
            logStore: logStore,
            httpClient: httpClient,
            logger: Logger(label: "test")
        )
        let app = Application(
            router: server.makeRouter(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            try await client.execute(uri: "/v1/audio/translations", method: .post, headers: headers) { response in
                #expect(response.status == .badRequest)
            }
        }
        try await httpClient.shutdown()
    }

    /// `POST /v1/translations` with malformed JSON returns 400 invalid_json.
    @Test func textTranslationsRejectsInvalidJSON() async throws {
        let token = "tok"
        let tokenStore = InMemoryTokenStore(initial: token)
        let logStore = InMemoryRequestLogStore()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        let server = TranscriptionServer(
            config: ServerConfig(),
            tokenStore: tokenStore,
            logStore: logStore,
            httpClient: httpClient,
            logger: Logger(label: "test")
        )
        let app = Application(
            router: server.makeRouter(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            try await client.execute(
                uri: "/v1/translations",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "not-json")
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
        try await httpClient.shutdown()
    }

    /// `POST /v1/translations` with `{}` (no `input`) returns 400 missing_input.
    @Test func textTranslationsRejectsMissingInput() async throws {
        let token = "tok"
        let tokenStore = InMemoryTokenStore(initial: token)
        let logStore = InMemoryRequestLogStore()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        let server = TranscriptionServer(
            config: ServerConfig(),
            tokenStore: tokenStore,
            logStore: logStore,
            httpClient: httpClient,
            logger: Logger(label: "test")
        )
        let app = Application(
            router: server.makeRouter(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        try await app.test(.live) { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            try await client.execute(
                uri: "/v1/translations",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
        try await httpClient.shutdown()
    }
}

@Suite("TextTranslator response parsing")
struct TextTranslatorParseTests {
    /// Happy path: chat-completion envelope wrapping a translation JSON
    /// object is decoded into a Translation value.
    @Test func parsesValidChatCompletion() throws {
        let body = """
        {
          "choices": [
            { "message": { "content": "{\\"translated_text\\":\\"hello\\",\\"source_language\\":\\"fr\\"}" } }
          ]
        }
        """
        let data = Data(body.utf8)
        let translation = try TextTranslator.parse(chatCompletion: data, fallbackSourceLanguage: nil)
        #expect(translation.translatedText == "hello")
        #expect(translation.sourceLanguage == "fr")
        #expect(translation.targetLanguage == "en")
    }

    /// Models often wrap JSON in markdown fences — the parser must strip them.
    @Test func parsesFencedJSON() throws {
        let fenced = "```json\\n{\\\"translated_text\\\":\\\"bonjour\\\"}\\n```"
        let body = """
        { "choices": [ { "message": { "content": "\(fenced)" } } ] }
        """
        let translation = try TextTranslator.parse(
            chatCompletion: Data(body.utf8),
            fallbackSourceLanguage: "fr"
        )
        #expect(translation.translatedText == "bonjour")
        #expect(translation.sourceLanguage == "fr")  // fallback applied
    }

    /// Empty choices array surfaces a malformedResponse error.
    @Test func emptyChoicesThrows() {
        let body = #"{"choices":[]}"#
        #expect(throws: TextTranslator.TranslatorError.self) {
            try TextTranslator.parse(
                chatCompletion: Data(body.utf8),
                fallbackSourceLanguage: nil
            )
        }
    }

    /// A response whose content is not valid JSON surfaces malformedResponse.
    @Test func contentNotJSONThrows() {
        let body = """
        { "choices": [ { "message": { "content": "this is plain text" } } ] }
        """
        #expect(throws: TextTranslator.TranslatorError.self) {
            try TextTranslator.parse(
                chatCompletion: Data(body.utf8),
                fallbackSourceLanguage: nil
            )
        }
    }
}
