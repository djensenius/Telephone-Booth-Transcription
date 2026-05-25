import Testing
@testable import TranscriptionCore

@Suite("ServerConfig validation")
struct ConfigValidationTests {
    @Test("Valid config passes through unchanged")
    func validConfigUnchanged() {
        let config = ServerConfig()
        let validated = config.validated()
        #expect(validated == config)
    }

    @Test("Port below 1 resets to default")
    func portBelowRange() {
        var config = ServerConfig()
        config.bindPort = 0
        let validated = config.validated()
        #expect(validated.bindPort == ServerConfig.defaultPort)
    }

    @Test("Port above 65535 resets to default")
    func portAboveRange() {
        var config = ServerConfig()
        config.bindPort = 70000
        let validated = config.validated()
        #expect(validated.bindPort == ServerConfig.defaultPort)
    }

    @Test("Negative port resets to default")
    func negativePort() {
        var config = ServerConfig()
        config.bindPort = -1
        let validated = config.validated()
        #expect(validated.bindPort == ServerConfig.defaultPort)
    }

    @Test("Empty bindHost falls back to 127.0.0.1")
    func emptyBindHost() {
        var config = ServerConfig()
        config.bindHost = "   "
        let validated = config.validated()
        #expect(validated.bindHost == "127.0.0.1")
    }

    @Test("bindHost is trimmed")
    func bindHostTrimmed() {
        var config = ServerConfig()
        config.bindHost = "  0.0.0.0  "
        config.nonLoopbackBindAcknowledged = true
        let validated = config.validated()
        #expect(validated.bindHost == "0.0.0.0")
    }

    @Test("Non-loopback bindHost is rejected when not acknowledged")
    func nonLoopbackRejected() {
        var config = ServerConfig()
        config.bindHost = "0.0.0.0"
        let validated = config.validated()
        #expect(validated.bindHost == "127.0.0.1")
    }

    @Test("Non-loopback bindHost is allowed when acknowledged")
    func nonLoopbackAllowed() {
        var config = ServerConfig()
        config.bindHost = "192.168.1.50"
        config.nonLoopbackBindAcknowledged = true
        let validated = config.validated()
        #expect(validated.bindHost == "192.168.1.50")
    }

    @Test("Loopback addresses pass without acknowledgement")
    func loopbackAlwaysAllowed() {
        for host in ["127.0.0.1", "::1", "localhost"] {
            var config = ServerConfig()
            config.bindHost = host
            let validated = config.validated()
            #expect(validated.bindHost == host)
        }
    }

    @Test("isLoopbackHost returns correct values")
    func isLoopbackHostCheck() {
        var config = ServerConfig()
        config.bindHost = "127.0.0.1"
        #expect(config.isLoopbackHost == true)
        config.bindHost = "::1"
        #expect(config.isLoopbackHost == true)
        config.bindHost = "localhost"
        #expect(config.isLoopbackHost == true)
        config.bindHost = "0.0.0.0"
        #expect(config.isLoopbackHost == false)
        config.bindHost = "192.168.1.1"
        #expect(config.isLoopbackHost == false)
    }

    @Test("maxRequestBytes below 1 MB is clamped")
    func bodyLimitTooSmall() {
        var config = ServerConfig()
        config.maxRequestBytes = 100
        let validated = config.validated()
        #expect(validated.maxRequestBytes == ServerConfig.maxRequestBytesRange.lowerBound)
    }

    @Test("maxRequestBytes above 500 MB is clamped")
    func bodyLimitTooLarge() {
        var config = ServerConfig()
        config.maxRequestBytes = 1_000_000_000
        let validated = config.validated()
        #expect(validated.maxRequestBytes == ServerConfig.maxRequestBytesRange.upperBound)
    }

    @Test("Timeout below 1s is clamped to 1s")
    func timeoutTooSmall() {
        var config = ServerConfig()
        config.upstreamTimeout = .seconds(0.1)
        let validated = config.validated()
        #expect(validated.upstreamTimeout.seconds == 1.0)
    }

    @Test("Timeout above 600s is clamped to 600s")
    func timeoutTooLarge() {
        var config = ServerConfig()
        config.upstreamTimeout = .seconds(9999)
        let validated = config.validated()
        #expect(validated.upstreamTimeout.seconds == 600.0)
    }

    @Test("Negative concurrency resets to 0")
    func negativeConcurrency() {
        var config = ServerConfig()
        config.maxConcurrentRequests = -5
        let validated = config.validated()
        #expect(validated.maxConcurrentRequests == 0)
    }

    @Test("Concurrency above 256 is clamped")
    func concurrencyTooHigh() {
        var config = ServerConfig()
        config.maxConcurrentRequests = 1000
        let validated = config.validated()
        #expect(validated.maxConcurrentRequests == 256)
    }

    @Test("Empty moderationModel falls back to default")
    func emptyModerationModel() {
        var config = ServerConfig()
        config.moderationModel = ""
        let validated = config.validated()
        #expect(validated.moderationModel == "omni-moderation-latest")
    }

    @Test("Empty nativeTranscriptionLocale falls back to en-US")
    func emptyLocale() {
        var config = ServerConfig()
        config.nativeTranscriptionLocale = "  "
        let validated = config.validated()
        #expect(validated.nativeTranscriptionLocale == "en-US")
    }

    @Test("Invalid moderation upstream URL falls back to default")
    func invalidModerationURL() {
        var config = ServerConfig()
        config.moderationUpstream = .init(baseURL: "")
        let validated = config.validated()
        #expect(validated.moderationUpstream == .defaultModeration)
    }

    @Test("Invalid transcription upstream URL falls back to default")
    func invalidTranscriptionURL() {
        var config = ServerConfig()
        config.transcriptionBackend = .proxy(.init(baseURL: "   "))
        let validated = config.validated()
        if case .proxy(let upstream) = validated.transcriptionBackend {
            #expect(upstream == .defaultTranscription)
        } else {
            Issue.record("Expected proxy backend")
        }
    }

    @Test("Native backend is not affected by URL validation")
    func nativeBackendUnchanged() {
        var config = ServerConfig()
        config.transcriptionBackend = .nativeMacOS
        let validated = config.validated()
        #expect(validated.transcriptionBackend == .nativeMacOS)
    }
}
