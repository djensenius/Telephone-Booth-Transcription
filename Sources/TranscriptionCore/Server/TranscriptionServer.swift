import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import NIOCore
import TranscriptionOnDevice
import TranscriptionShared

/// Composes the entire HTTP surface — router + middlewares + routes — into a
/// `Hummingbird.Application` ready to run.
public struct TranscriptionServer: Sendable {
    public let config: ServerConfig
    public let tokenStore: any TokenStore
    public let logStore: any RequestLogStoring
    public let logWriter: RequestLogWriter
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
        self.logWriter = RequestLogWriter(store: logStore, logger: logger)
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
        let textTranslator = TextTranslator(
            upstream: config.translationUpstream,
            httpClient: httpClient,
            model: config.defaultTranslationModel,
            timeout: config.upstreamTimeout,
            logger: logger
        )

        router.add(middleware: RequestLogMiddleware(writer: logWriter, logger: logger))
        router.add(middleware: AuthMiddleware(tokenStore: tokenStore, logger: logger))
        if config.maxConcurrentRequests > 0 {
            router.add(middleware: ConcurrencyLimitMiddleware<BasicRequestContext>(
                maxConcurrent: config.maxConcurrentRequests,
                excludedPaths: ["/healthz"],
                logger: logger
            ))
        }

        let backendImpl: any TranscriptionBackendImpl
        switch config.transcriptionBackend {
        case .proxy(let upstreamConfig):
            backendImpl = ProxyTranscriptionBackend(
                upstream: upstream,
                upstreamConfig: upstreamConfig,
                defaultModel: config.defaultTranscriptionModel
            )
        case .nativeMacOS:
            #if canImport(Speech)
            backendImpl = NativeMacOSTranscriptionBackend(
                locale: Locale(identifier: config.nativeTranscriptionLocale),
                logger: logger
            )
            #else
            backendImpl = NativeMacOSTranscriptionBackend()
            #endif
        case .appleSpeechAnalyzer:
            #if canImport(Speech)
            if #available(macOS 26.0, iOS 26.0, *) {
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
        let translationBackend = Self.makeTranslationBackend(
            config: config,
            upstream: upstream,
            logger: logger
        )
        let translation = TranslationRoute<BasicRequestContext>(
            backend: translationBackend,
            maxRequestBytes: config.maxRequestBytes
        )
        let textTranslation = TextTranslationRoute<BasicRequestContext>(
            translator: textTranslator,
            backend: config.textTranslationBackend,
            onDeviceTranslator: Self.makeOnDeviceTranslator(logger: logger),
            maxRequestBytes: config.maxRequestBytes
        )
        let moderation = ModerationRoute<BasicRequestContext>(
            upstream: upstream,
            upstreamConfig: config.moderationUpstream,
            classifier: classifier,
            backend: config.moderationBackend,
            onDeviceModerator: Self.makeOnDeviceModerator(logger: logger),
            maxRequestBytes: config.maxRequestBytes,
            fallbackEnabled: config.moderationFallbackEnabled
        )
        let requests = RequestsRoute<BasicRequestContext>(store: logStore)
        let models = ModelsRoute<BasicRequestContext>(
            upstream: upstream,
            transcriptionUpstream: config.transcriptionUpstream,
            // A realm served on-device has no upstream to enumerate; passing
            // nil keeps `/v1/models` from making a network call in all-local
            // mode.
            translationUpstream: (config.textTranslationBackend == .proxy
                                  || config.audioTranslationBackend == .proxy)
                ? config.translationUpstream : nil,
            moderationUpstream: config.moderationBackend == .proxy
                ? config.moderationUpstream : nil,
            includeNativeMacOS: config.transcriptionBackend.isOnDevice,
            foundationModelsRealms: {
                // "translation" covers both translation routes; only list it
                // once even when text and audio translation are both on-device.
                var realms: [String] = []
                if config.textTranslationBackend == .onDevice
                    || config.audioTranslationBackend == .onDevice {
                    realms.append("translation")
                }
                if config.moderationBackend == .onDevice {
                    realms.append("moderation")
                }
                return realms
            }()
        )
        let health = HealthRoute<BasicRequestContext>()

        router.get("/healthz", use: health.handle)
        router.post("/v1/audio/transcriptions", use: transcription.handle)
        router.post("/v1/audio/translations", use: translation.handle)
        router.post("/v1/translations", use: textTranslation.handle)
        router.post("/v1/moderations", use: moderation.handle)
        router.get("/v1/requests", use: requests.handle)
        router.get("/v1/models", use: models.handle)

        return router
    }

    /// Builds the on-device moderation service when Foundation Models is
    /// available on this platform/OS. Returns `nil` otherwise — the moderation
    /// route then reports `.onDevice` as unavailable instead of silently
    /// falling back to a network upstream.
    static func makeOnDeviceModerator(logger: Logger) -> (any TextModerationService)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return FoundationModelsModerationService(logger: logger)
        }
        #endif
        return nil
    }

    /// Builds the on-device translation service when Foundation Models is
    /// available on this platform/OS. Returns `nil` otherwise.
    static func makeOnDeviceTranslator(logger: Logger) -> (any TextTranslationService)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return FoundationModelsTranslationService(logger: logger)
        }
        #endif
        return nil
    }

    /// Builds the on-device transcriber matching `backend`. Returns `nil` when
    /// the Speech framework is unavailable on this platform.
    ///
    /// A `.proxy` transcription backend maps to the `SpeechAnalyzer` engine
    /// rather than `nil`, so all-local audio translation still works for users
    /// who deliberately keep `/v1/audio/transcriptions` pointed at Whisper.
    static func makeOnDeviceTranscriber(
        backend: TranscriptionBackend,
        locale: Locale,
        logger: Logger
    ) -> (any AudioTranscriber)? {
        #if canImport(Speech)
        if case .nativeMacOS = backend {
            return NativeSpeechTranscriber(locale: locale, logger: logger)
        }
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return SpeechAnalyzerTranscriber(locale: locale, logger: logger)
        }
        return NativeSpeechTranscriber(locale: locale, logger: logger)
        #else
        return nil
        #endif
    }

    /// Chooses the `POST /v1/audio/translations` backend.
    ///
    /// `.onDevice` composes the Speech engine with Foundation Models so no
    /// audio or text leaves the machine. If either half is unavailable, the
    /// route reports `503 on_device_unavailable` rather than falling back to
    /// the proxy: selecting on-device is a privacy boundary, and quietly
    /// shipping the caller's audio to a network upstream because a local engine
    /// was missing would break both `isFullyLocal` and the promise the Settings
    /// UI makes. This matches the text-translation and moderation routes.
    static func makeTranslationBackend(
        config: ServerConfig,
        upstream: OpenAIUpstream,
        logger: Logger
    ) -> any TranslationBackendImpl {
        guard config.audioTranslationBackend == .onDevice else {
            return ProxyTranslationBackend(
                upstream: upstream,
                upstreamConfig: config.translationUpstream,
                defaultModel: config.defaultTranslationModel
            )
        }
        guard let transcriber = makeOnDeviceTranscriber(
            backend: config.transcriptionBackend,
            locale: Locale(identifier: config.nativeTranscriptionLocale),
            logger: logger
        ), let translator = makeOnDeviceTranslator(logger: logger) else {
            logger.warning(
                """
                on-device audio translation selected but unavailable on this OS; \
                /v1/audio/translations will return 503 on_device_unavailable
                """
            )
            return UnavailableTranslationBackend()
        }
        return OnDeviceTranslationBackend(
            transcriber: transcriber,
            translator: translator,
            logger: logger
        )
    }
}

/// Stands in for the on-device audio-translation backend when this device can't
/// run the engines. It always fails closed, so selecting on-device never causes
/// audio to reach a network upstream.
struct UnavailableTranslationBackend: TranslationBackendImpl {
    func handle(body: ByteBuffer, contentType: String) async throws -> Response {
        throw TranslationBackendError.unavailable(
            "on-device audio translation is selected but Apple Intelligence is "
            + "unavailable on this device"
        )
    }
}
