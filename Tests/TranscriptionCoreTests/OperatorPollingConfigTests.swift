import Foundation
import Testing
@testable import TranscriptionCore

@Suite("OperatorPollingConfig")
struct OperatorPollingConfigTests {
    @Test func defaultsAreReasonable() {
        let cfg = OperatorPollingConfig()
        #expect(cfg.enabled == false)
        #expect(cfg.pollIntervalSeconds == 5)
        #expect(cfg.leaseSeconds == 60)
        #expect(cfg.transcriptionEnabled)
        #expect(cfg.translationEnabled)
        #expect(cfg.moderationEnabled)
    }

    @Test func validatedClampsReconnectDelayAndLegacyLease() {
        var cfg = OperatorPollingConfig(
            enabled: true,
            baseURL: "https://operator.example.com",
            pollIntervalSeconds: 9999,
            leaseSeconds: 1
        )
        let validated = cfg.validated()
        #expect(validated.pollIntervalSeconds == OperatorPollingConfig.maxPollInterval)
        #expect(validated.leaseSeconds == OperatorPollingConfig.minLease)

        cfg.pollIntervalSeconds = 0
        cfg.leaseSeconds = 100_000
        let clamped = cfg.validated()
        #expect(clamped.pollIntervalSeconds == OperatorPollingConfig.minPollInterval)
        #expect(clamped.leaseSeconds == OperatorPollingConfig.maxLease)
    }

    @Test func isRunnableRequiresHTTPBaseURL() {
        var cfg = OperatorPollingConfig(enabled: true, baseURL: "")
        #expect(cfg.isRunnableWithToken == false)
        cfg.baseURL = "ftp://example.com"
        #expect(cfg.isRunnableWithToken == false)
        cfg.baseURL = "http://127.0.0.1:8080"
        #expect(cfg.isRunnableWithToken)
        cfg.baseURL = "https://operator.example.com"
        #expect(cfg.isRunnableWithToken)
        cfg.enabled = false
        #expect(cfg.isRunnableWithToken == false)
    }

    @Test func remoteHTTPIsNotRunnableWithOperatorToken() {
        let remote = OperatorPollingConfig(enabled: true, baseURL: "http://operator.example.com")
        #expect(remote.isRunnableWithToken == false)
        #expect(remote.validated().baseURL == "")

        let loopback = OperatorPollingConfig(enabled: true, baseURL: "http://localhost:8080")
        #expect(loopback.isRunnableWithToken)
        #expect(loopback.validated().baseURL == "http://localhost:8080")

        let ipv6Loopback = OperatorPollingConfig(enabled: true, baseURL: "http://[::1]:8080")
        #expect(ipv6Loopback.isRunnableWithToken)
    }

    @Test func authorizationHeaderUsesBearerSchemeWithoutDoublePrefixing() {
        let tokenHeader = OperatorPollingConfig.bearerAuthorizationHeader(for: "operator-token")
        let existingHeader = OperatorPollingConfig.bearerAuthorizationHeader(for: "  Bearer operator-token  ")
        #expect(tokenHeader == "Bearer operator-token")
        #expect(existingHeader == "Bearer operator-token")
        #expect(OperatorPollingConfig.bearerAuthorizationHeader(for: "") == nil)
    }

    @Test func requestedKindsFollowsToggles() {
        var cfg = OperatorPollingConfig()
        #expect(cfg.requestedKinds.split(separator: ",").sorted()
                == ["moderation", "transcription", "translation"])
        cfg.translationEnabled = false
        cfg.moderationEnabled = false
        #expect(cfg.requestedKinds == "transcription")
        cfg.transcriptionEnabled = false
        #expect(cfg.requestedKinds == "")
    }
}
