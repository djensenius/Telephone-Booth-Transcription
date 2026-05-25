import Testing
@testable import TranscriptionCore

@Suite("Upstream URL security validation")
struct UpstreamURLSecurityTests {
    // MARK: - isLoopback

    @Test("127.0.0.1 is loopback")
    func ipv4Loopback() {
        let cfg = UpstreamConfig(baseURL: "http://127.0.0.1:8000/v1")
        #expect(cfg.isLoopback)
    }

    @Test("localhost is loopback")
    func localhost() {
        let cfg = UpstreamConfig(baseURL: "http://localhost:1234/v1")
        #expect(cfg.isLoopback)
    }

    @Test("::1 is loopback")
    func ipv6Loopback() {
        let cfg = UpstreamConfig(baseURL: "http://[::1]:8000/v1")
        #expect(cfg.isLoopback)
    }

    @Test("Remote host is not loopback")
    func remoteHost() {
        let cfg = UpstreamConfig(baseURL: "http://api.openai.com/v1")
        #expect(!cfg.isLoopback)
    }

    @Test("Empty URL is not loopback")
    func emptyURL() {
        let cfg = UpstreamConfig(baseURL: "")
        #expect(!cfg.isLoopback)
    }

    // MARK: - requiresSecureTransport

    @Test("Remote with key requires secure transport")
    func remoteWithKey() {
        let cfg = UpstreamConfig(baseURL: "http://api.openai.com/v1", apiKey: "sk-123")
        #expect(cfg.requiresSecureTransport)
    }

    @Test("Remote without key does not require secure transport")
    func remoteNoKey() {
        let cfg = UpstreamConfig(baseURL: "http://api.openai.com/v1")
        #expect(!cfg.requiresSecureTransport)
    }

    @Test("Loopback with key does not require secure transport")
    func loopbackWithKey() {
        let cfg = UpstreamConfig(baseURL: "http://127.0.0.1:1234/v1", apiKey: "sk-123")
        #expect(!cfg.requiresSecureTransport)
    }

    @Test("Empty key does not require secure transport")
    func emptyKey() {
        let cfg = UpstreamConfig(baseURL: "http://api.openai.com/v1", apiKey: "")
        #expect(!cfg.requiresSecureTransport)
    }

    // MARK: - validateSecurity

    @Test("HTTPS remote with key passes validation")
    func httpsRemoteWithKey() {
        let cfg = UpstreamConfig(baseURL: "https://api.openai.com/v1", apiKey: "sk-123")
        #expect(cfg.validateSecurity() == .success(()))
    }

    @Test("HTTP remote with key fails validation")
    func httpRemoteWithKey() {
        let cfg = UpstreamConfig(baseURL: "http://api.openai.com/v1", apiKey: "sk-123")
        if case .failure(let err) = cfg.validateSecurity() {
            #expect(err == .insecureRemoteWithAPIKey(url: "http://api.openai.com/v1"))
        } else {
            Issue.record("Expected failure for insecure remote with key")
        }
    }

    @Test("HTTP loopback with key passes validation")
    func httpLoopbackWithKey() {
        let cfg = UpstreamConfig(baseURL: "http://127.0.0.1:8000/v1", apiKey: "sk-123")
        #expect(cfg.validateSecurity() == .success(()))
    }

    @Test("HTTP remote without key passes validation")
    func httpRemoteNoKey() {
        let cfg = UpstreamConfig(baseURL: "http://api.openai.com/v1")
        #expect(cfg.validateSecurity() == .success(()))
    }

    // MARK: - strippingKeyIfInsecure

    @Test("Insecure remote key is stripped")
    func stripsInsecureKey() {
        let cfg = UpstreamConfig(baseURL: "http://attacker.example/v1", apiKey: "secret")
        let stripped = cfg.strippingKeyIfInsecure()
        #expect(stripped.apiKey == nil)
        #expect(stripped.baseURL == "http://attacker.example/v1")
    }

    @Test("Secure remote key is preserved")
    func preservesSecureKey() {
        let cfg = UpstreamConfig(baseURL: "https://api.openai.com/v1", apiKey: "sk-123")
        let result = cfg.strippingKeyIfInsecure()
        #expect(result.apiKey == "sk-123")
    }

    @Test("Loopback key is preserved regardless of scheme")
    func preservesLoopbackKey() {
        let cfg = UpstreamConfig(baseURL: "http://localhost:1234/v1", apiKey: "my-key")
        let result = cfg.strippingKeyIfInsecure()
        #expect(result.apiKey == "my-key")
    }

    // MARK: - ServerConfig.validated() integration

    @Test("validated() strips key from insecure moderation upstream")
    func validatedStripsModerationKey() {
        var config = ServerConfig()
        config.moderationUpstream = UpstreamConfig(
            baseURL: "http://evil.example/v1", apiKey: "leak-me"
        )
        let validated = config.validated()
        #expect(validated.moderationUpstream.apiKey == nil)
        #expect(validated.moderationUpstream.baseURL == "http://evil.example/v1")
    }

    @Test("validated() strips key from insecure transcription upstream")
    func validatedStripsTranscriptionKey() {
        var config = ServerConfig()
        config.transcriptionBackend = .proxy(
            UpstreamConfig(baseURL: "http://evil.example/v1", apiKey: "leak-me")
        )
        let validated = config.validated()
        if case .proxy(let upstream) = validated.transcriptionBackend {
            #expect(upstream.apiKey == nil)
        } else {
            Issue.record("Expected proxy backend")
        }
    }

    @Test("validated() preserves key for HTTPS remote upstream")
    func validatedPreservesSecureKey() {
        var config = ServerConfig()
        config.moderationUpstream = UpstreamConfig(
            baseURL: "https://api.openai.com/v1", apiKey: "sk-safe"
        )
        let validated = config.validated()
        #expect(validated.moderationUpstream.apiKey == "sk-safe")
    }
}
