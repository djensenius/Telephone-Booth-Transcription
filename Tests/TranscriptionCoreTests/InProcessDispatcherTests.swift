import Foundation
import Logging
import Testing
import TranscriptionOperator
import TranscriptionShared

@Suite("InProcessOperatorJobDispatcher")
struct InProcessDispatcherTests {
    /// Writes fixed contents to a temp file and hands it to `body`, ignoring the
    /// URL/hash (verification is covered by AudioFileStaging tests). Can be made
    /// to fail with a specific `AudioFetchError`.
    struct StubAudioFetcher: AudioFetching {
        var failWith: AudioFetchError?
        var contents = Data("audio".utf8)

        func withFetchedAudioFile<T: Sendable>(
            url: String,
            expectedSHA256: String,
            maxBytes: Int,
            suggestedExtension: String?,
            _ body: @Sendable (URL) async throws -> T
        ) async throws -> T {
            if let failWith { throw failWith }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let fileURL = dir.appendingPathComponent("audio")
            try contents.write(to: fileURL)
            return try await body(fileURL)
        }
    }

    struct StubTranscriber: AudioTranscriber {
        var text: String = "transcribed"
        var error: OnDeviceServiceError?
        func transcribe(audioFileURL: URL, language: String?) async throws -> String {
            if let error { throw error }
            return text
        }
    }

    struct StubTranslator: TextTranslationService {
        var result = TranslationResult(translatedText: "hi", sourceLanguage: "fr",
                                       targetLanguage: "en", model: "apple-foundation-models")
        var error: OnDeviceServiceError?
        func translate(_ input: String, sourceLanguage: String?) async throws -> TranslationResult {
            if let error { throw error }
            return result
        }
    }

    struct StubModerator: TextModerationService {
        var verdict = ModerationVerdict(flagged: true, recommendation: "block",
                                        maxScore: 0.9, model: "apple-foundation-models")
        var error: OnDeviceServiceError?
        func moderate(_ input: String) async throws -> ModerationVerdict {
            if let error { throw error }
            return verdict
        }
    }

    private func transcriptionJob() -> OperatorJob {
        OperatorJob(id: "t", leaseToken: "lt", kind: .transcription,
                    payload: .transcription(.init(audioURL: "https://x/a.flac",
                                                  sha256: String(repeating: "a", count: 64),
                                                  model: "whisper-1", language: "en")))
    }

    private func translationJob() -> OperatorJob {
        OperatorJob(id: "x", leaseToken: "lt", kind: .translation,
                    payload: .translation(.init(input: "bonjour", sourceLanguage: "fr")))
    }

    private func moderationJob() -> OperatorJob {
        OperatorJob(id: "m", leaseToken: "lt", kind: .moderation,
                    payload: .moderation(.init(input: "text")))
    }

    @Test func supportedKindsReflectsInjectedServices() {
        let d = InProcessOperatorJobDispatcher(
            transcriber: StubTranscriber(),
            moderator: StubModerator(),
            audioFetcher: StubAudioFetcher()
        )
        #expect(d.supportedKinds == [.transcription, .moderation])
    }

    @Test func runsTranscription() async throws {
        let d = InProcessOperatorJobDispatcher(
            transcriber: StubTranscriber(text: "hello"),
            audioFetcher: StubAudioFetcher()
        )
        let result = try await d.execute(job: transcriptionJob())
        #expect(result == .transcription(text: "hello", language: "en", model: "whisper-1"))
    }

    @Test func runsTranslation() async throws {
        let d = InProcessOperatorJobDispatcher(
            translator: StubTranslator(),
            audioFetcher: StubAudioFetcher()
        )
        let result = try await d.execute(job: translationJob())
        #expect(result == .translation(translatedText: "hi", sourceLanguage: "fr",
                                       targetLanguage: "en", model: "apple-foundation-models"))
    }

    @Test func runsModeration() async throws {
        let d = InProcessOperatorJobDispatcher(
            moderator: StubModerator(),
            audioFetcher: StubAudioFetcher()
        )
        let result = try await d.execute(job: moderationJob())
        #expect(result == .moderation(flagged: true, recommendation: "block",
                                      maxScore: 0.9, model: "apple-foundation-models"))
    }

    @Test func missingServiceIsUnsupported() async {
        let d = InProcessOperatorJobDispatcher(audioFetcher: StubAudioFetcher())
        await #expect(throws: OperatorJobError(code: "translation_unsupported",
                                               message: "device cannot perform translation")) {
            _ = try await d.execute(job: translationJob())
        }
    }

    @Test func sanitizesServiceErrorWithoutLeakingContent() async throws {
        let d = InProcessOperatorJobDispatcher(
            translator: StubTranslator(error: .badRequest("input was 'secret transcript'")),
            audioFetcher: StubAudioFetcher()
        )
        do {
            _ = try await d.execute(job: translationJob())
            Issue.record("expected throw")
        } catch let error as OperatorJobError {
            #expect(error.code == "translation_bad_input")
            #expect(error.message == "local translation failed")
            #expect(!error.message.contains("secret"))
        }
    }

    @Test func mapsAudioFetchErrors() async throws {
        let d = InProcessOperatorJobDispatcher(
            transcriber: StubTranscriber(),
            audioFetcher: StubAudioFetcher(failWith: .hashMismatch)
        )
        do {
            _ = try await d.execute(job: transcriptionJob())
            Issue.record("expected throw")
        } catch let error as OperatorJobError {
            #expect(error.code == "audio_sha256_mismatch")
        }
    }
}
