import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import NIOCore

/// Composes the entire HTTP surface — router + middlewares + routes — into a
/// `Hummingbird.Application` ready to run.
public struct TranscriptionServer: Sendable {
    public let config: ServerConfig
    public let tokenStore: any TokenStore
    public let logStore: any RequestLogStoring
    public let httpClient: HTTPClient
    public let logger: Logger

    public init(
        config: ServerConfig,
        tokenStore: any TokenStore,
        logStore: any RequestLogStoring,
        httpClient: HTTPClient,
        logger: Logger = Logger(label: "transcription-server")
    ) {
        self.config = config
        self.tokenStore = tokenStore
        self.logStore = logStore
        self.httpClient = httpClient
        self.logger = logger
    }

    /// Builds a fully wired `Application`. Caller owns the lifecycle (start/stop).
    public func makeApplication() -> some ApplicationProtocol {
        let router = makeRouter()
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(config.bindHost, port: config.bindPort),
                serverName: "telephone-booth-transcription"
            ),
            logger: logger
        )
        return app
    }

    /// Exposed so tests can hit routes directly without binding a socket.
    public func makeRouter() -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)

        let upstream = OpenAIUpstream(
            httpClient: httpClient,
            timeout: config.upstreamTimeout,
            logger: logger
        )
        let classifier = ModerationClassifier(
            upstream: config.moderationUpstream,
            httpClient: httpClient,
            model: config.moderationModel,
            timeout: config.upstreamTimeout,
            logger: logger
        )

        router.add(middleware: RequestLogMiddleware(store: logStore, logger: logger))
        router.add(middleware: AuthMiddleware(tokenStore: tokenStore, logger: logger))

        let backendImpl: any TranscriptionBackendImpl
        switch config.transcriptionBackend {
        case .proxy(let upstreamConfig):
            backendImpl = ProxyTranscriptionBackend(
                upstream: upstream,
                upstreamConfig: upstreamConfig,
                defaultModel: config.defaultTranscriptionModel
            )
        case .nativeMacOS:
            #if canImport(Speech) && os(macOS)
            backendImpl = NativeMacOSTranscriptionBackend(
                locale: Locale(identifier: config.nativeTranscriptionLocale),
                logger: logger
            )
            #else
            backendImpl = NativeMacOSTranscriptionBackend()
            #endif
        case .appleSpeechAnalyzer:
            #if canImport(Speech) && os(macOS)
            if #available(macOS 26.0, *) {
                backendImpl = SpeechAnalyzerBackend(
                    locale: Locale(identifier: config.nativeTranscriptionLocale),
                    logger: logger
                )
            } else {
                backendImpl = NativeMacOSTranscriptionBackend(
                    locale: Locale(identifier: config.nativeTranscriptionLocale),
                    logger: logger
                )
            }
            #else
            backendImpl = SpeechAnalyzerBackend()
            #endif
        }

        let transcription = TranscriptionRoute<BasicRequestContext>(
            backend: backendImpl,
            maxRequestBytes: config.maxRequestBytes
        )
        let moderation = ModerationRoute<BasicRequestContext>(
            upstream: upstream,
            upstreamConfig: config.moderationUpstream,
            classifier: classifier,
            maxRequestBytes: config.maxRequestBytes,
            fallbackEnabled: config.moderationFallbackEnabled
        )
        let requests = RequestsRoute<BasicRequestContext>(store: logStore)
        let models = ModelsRoute<BasicRequestContext>(
            upstream: upstream,
            transcriptionUpstream: config.transcriptionUpstream,
            moderationUpstream: config.moderationUpstream,
            includeNativeMacOS: {
                switch config.transcriptionBackend {
                case .nativeMacOS, .appleSpeechAnalyzer: return true
                case .proxy: return false
                }
            }()
        )
        let health = HealthRoute<BasicRequestContext>()

        router.get("/healthz", use: health.handle)
        router.post("/v1/audio/transcriptions", use: transcription.handle)
        router.post("/v1/moderations", use: moderation.handle)
        router.get("/v1/requests", use: requests.handle)
        router.get("/v1/models", use: models.handle)

        return router
    }
}
