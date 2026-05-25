import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
@testable import TranscriptionCore

@Suite("TranscriptionServer end-to-end (against stub upstream)")
struct TranscriptionServerTests {
    /// Smoke test: `/healthz` is reachable without auth.
    @Test func healthEndpointIsUnauthenticated() async throws {
        let tokenStore = InMemoryTokenStore()
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
            try await client.execute(uri: "/healthz", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
        try await httpClient.shutdown()
    }

    @Test func protectedRouteRejectsMissingToken() async throws {
        let tokenStore = InMemoryTokenStore()
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
            try await client.execute(uri: "/v1/requests", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
        try await httpClient.shutdown()
    }

    @Test func protectedRouteRejectsBadToken() async throws {
        let tokenStore = InMemoryTokenStore(initial: "real-token")
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
            headers[.authorization] = "Bearer wrong-token"
            try await client.execute(uri: "/v1/requests", method: .get, headers: headers) { response in
                #expect(response.status == .unauthorized)
            }
        }
        try await httpClient.shutdown()
    }

    @Test func protectedRouteAcceptsValidToken() async throws {
        let token = "valid-token-abc"
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
            try await client.execute(uri: "/v1/requests", method: .get, headers: headers) { response in
                #expect(response.status == .ok)
            }
        }
        try await httpClient.shutdown()
    }
}
