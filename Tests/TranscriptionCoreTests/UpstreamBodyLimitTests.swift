import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOHTTP1
import Testing
@testable import TranscriptionCore

@Suite("OpenAIUpstream response body limits")
struct UpstreamBodyLimitTests {
    /// Upstream returning a body larger than the cap throws `.responseTooLarge`.
    @Test func oversizedResponseThrowsResponseTooLarge() async throws {
        // Start a stub HTTP server that returns a body larger than the cap.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let server = try await startStubServer(group: group) { _, _ in
            // Return 200 with a 2 MB body (exceeds 1 MB cap we'll use)
            let body = ByteBuffer(repeating: 0x41, count: 2 * 1024 * 1024)
            return StubResponse(status: .ok, body: body)
        }
        defer { try? server.close().wait() }

        let port = server.localAddress!.port!
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        let upstream = OpenAIUpstream(
            httpClient: httpClient,
            timeout: .seconds(10),
            logger: Logger(label: "test")
        )
        let config = UpstreamConfig(baseURL: "http://127.0.0.1:\(port)", apiKey: nil)

        do {
            _ = try await upstream.proxy(
                upstream: config,
                method: .GET,
                pathSuffix: "/test",
                contentType: nil,
                body: nil,
                maxResponseBytes: 1 * 1024 * 1024
            )
            Issue.record("Expected UpstreamError.responseTooLarge")
        } catch let error as UpstreamError {
            #expect(error == .responseTooLarge(maxBytes: 1 * 1024 * 1024))
        }
    }

    /// Upstream that responds within the cap succeeds normally.
    @Test func responseWithinCapSucceeds() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let server = try await startStubServer(group: group) { _, _ in
            let body = ByteBuffer(string: "{\"ok\":true}")
            return StubResponse(status: .ok, body: body)
        }
        defer { try? server.close().wait() }

        let port = server.localAddress!.port!
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        let upstream = OpenAIUpstream(
            httpClient: httpClient,
            timeout: .seconds(10),
            logger: Logger(label: "test")
        )
        let config = UpstreamConfig(baseURL: "http://127.0.0.1:\(port)", apiKey: nil)

        let result = try await upstream.proxy(
            upstream: config,
            method: .GET,
            pathSuffix: "/test",
            contentType: nil,
            body: nil,
            maxResponseBytes: 1 * 1024 * 1024
        )
        #expect(result.status == 200)
        let bodyStr = String(buffer: result.body)
        #expect(bodyStr == "{\"ok\":true}")
    }

    /// Upstream that exceeds the deadline throws a timeout error (connection timeout).
    @Test func stalledResponseThrowsTimeout() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        // Server that never sends a response (stalls indefinitely).
        let server = try await startStubServer(group: group) { ctx, _ in
            // Schedule response after a long delay (longer than our timeout)
            _ = ctx.eventLoop.scheduleTask(in: .seconds(30)) {
                // This will never execute within the test timeout
            }
            return nil // signal: don't respond immediately
        }
        defer { try? server.close().wait() }

        let port = server.localAddress!.port!
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        let upstream = OpenAIUpstream(
            httpClient: httpClient,
            timeout: .milliseconds(200),
            logger: Logger(label: "test")
        )
        let config = UpstreamConfig(baseURL: "http://127.0.0.1:\(port)", apiKey: nil)

        do {
            _ = try await upstream.proxy(
                upstream: config,
                method: .GET,
                pathSuffix: "/test",
                contentType: nil,
                body: nil,
                maxResponseBytes: 1 * 1024 * 1024
            )
            Issue.record("Expected UpstreamError.deadlineExceeded")
        } catch let error as UpstreamError {
            #expect(error == .deadlineExceeded)
        }
    }

    /// The endpoint-specific constants have the expected values.
    @Test func endpointCapConstants() {
        #expect(OpenAIUpstream.transcriptionMaxResponseBytes == 10 * 1024 * 1024)
        #expect(OpenAIUpstream.moderationMaxResponseBytes == 1 * 1024 * 1024)
        #expect(OpenAIUpstream.modelsMaxResponseBytes == 256 * 1024)
    }
}

// MARK: - Stub HTTP Server

private struct StubResponse {
    let status: HTTPResponseStatus
    let body: ByteBuffer
}

private func startStubServer(
    group: EventLoopGroup,
    handler: @escaping @Sendable (ChannelHandlerContext, HTTPRequestHead) -> StubResponse?
) async throws -> Channel {
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(.backlog, value: 256)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(StubHTTPHandler(handler: handler))
            }
        }
        .childChannelOption(.socketOption(.so_reuseaddr), value: 1)

    return try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
}

private final class StubHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let handler: @Sendable (ChannelHandlerContext, HTTPRequestHead) -> StubResponse?

    init(handler: @escaping @Sendable (ChannelHandlerContext, HTTPRequestHead) -> StubResponse?) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            guard let response = handler(context, head) else {
                // nil means "don't respond" (stall test)
                return
            }
            let responseHead = HTTPResponseHead(
                version: .http1_1,
                status: response.status,
                headers: HTTPHeaders([
                    ("Content-Length", "\(response.body.readableBytes)"),
                    ("Content-Type", "application/json")
                ])
            )
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(response.body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        case .body, .end:
            break
        }
    }
}
