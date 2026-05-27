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

    @Test func validatedClampsPollAndLease() {
        var cfg = OperatorPollingConfig(
            enabled: true,
            baseURL: "https://operator.example.com",
            pollIntervalSeconds: 9999,
            leaseSeconds: 1
        )
        let v = cfg.validated()
        #expect(v.pollIntervalSeconds == OperatorPollingConfig.maxPollInterval)
        #expect(v.leaseSeconds == OperatorPollingConfig.minLease)

        cfg.pollIntervalSeconds = 0
        cfg.leaseSeconds = 100_000
        let v2 = cfg.validated()
        #expect(v2.pollIntervalSeconds == OperatorPollingConfig.minPollInterval)
        #expect(v2.leaseSeconds == OperatorPollingConfig.maxLease)
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
