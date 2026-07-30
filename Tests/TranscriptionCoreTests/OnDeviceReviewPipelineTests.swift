import Foundation
import Testing
import TranscriptionOperator
import TranscriptionShared

/// Covers the on-device review pipeline's orchestration: stage transitions,
/// the advisory-moderation rule, empty-transcript rejection, error copy, and
/// the generation-token guards around `reset` / concurrent runs.
@MainActor
@Suite("OnDeviceReviewPipeline")
struct OnDeviceReviewPipelineTests {
    struct StubAudioFetcher: AudioFetching {
        var failWith: AudioFetchError?

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
            try Data("audio".utf8).write(to: fileURL)
            return try await body(fileURL)
        }
    }

    struct StubTranscriber: AudioTranscriber {
        var text = "bonjour"
        var error: OnDeviceServiceError?
        /// Blocks until resumed, so a test can observe an in-flight run.
        var gate: Gate?

        func transcribe(audioFileURL: URL, language: String?) async throws -> String {
            await gate?.wait()
            if let error { throw error }
            return text
        }
    }

    struct StubTranslator: TextTranslationService {
        var text = "hello"
        var error: OnDeviceServiceError?
        func translate(_ input: String, sourceLanguage: String?) async throws -> TranslationResult {
            if let error { throw error }
            return TranslationResult(translatedText: text, sourceLanguage: "fr",
                                     targetLanguage: "en", model: "apple-foundation-models")
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

    /// Records the source-language hint the pipeline forwards.
    final class SpyTranslator: TextTranslationService, @unchecked Sendable {
        private(set) var receivedSourceLanguage: String?
        func translate(_ input: String, sourceLanguage: String?) async throws -> TranslationResult {
            receivedSourceLanguage = sourceLanguage
            return TranslationResult(translatedText: "hello", sourceLanguage: "fr",
                                     targetLanguage: "en", model: "apple-foundation-models")
        }
    }

    /// A one-shot async gate, so tests can hold a stage open deterministically
    /// instead of sleeping.
    actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in continuations { continuation.resume() }
            continuations.removeAll()
        }
    }

    private func makePipeline(
        transcriber: StubTranscriber = StubTranscriber(),
        translator: StubTranslator? = StubTranslator(),
        moderator: StubModerator? = StubModerator(),
        fetcher: StubAudioFetcher = StubAudioFetcher(),
        transcriptionModel: String? = "apple-speech-analyzer"
    ) -> OnDeviceReviewPipeline {
        OnDeviceReviewPipeline(
            dispatcher: InProcessOperatorJobDispatcher(
                transcriber: transcriber,
                translator: translator,
                moderator: moderator,
                audioFetcher: fetcher
            ),
            transcriptionModel: transcriptionModel
        )
    }

    private func input(_ id: String = "m1") -> OnDeviceReviewPipeline.Input {
        OnDeviceReviewPipeline.Input(
            id: id,
            audioURL: URL(string: "https://example.test/a.flac")!,
            audioSHA256: String(repeating: "a", count: 64),
            audioDurationMs: 1_000,
            language: "fr"
        )
    }

    // MARK: - Happy paths

    @Test func startsIdle() {
        let pipeline = makePipeline()
        #expect(pipeline.stage(for: "m1") == .idle)
        #expect(pipeline.isRunning("m1") == false)
    }

    @Test func runProducesTranslationAndVerdict() async {
        let pipeline = makePipeline()
        let translation = await pipeline.run(for: input())

        #expect(translation == "hello")
        #expect(pipeline.stage(for: "m1") == .finished)
        #expect(pipeline.outputs["m1"] == OnDeviceReviewPipeline.Output(
            transcript: "bonjour",
            language: "fr",
            model: "apple-speech-analyzer",
            translation: "hello",
            recommendation: "block",
            flagged: true
        ))
    }

    @Test func transcribeOnlySkipsTranslationAndModeration() async {
        let pipeline = makePipeline()
        let transcript = await pipeline.transcribeOnly(for: input())

        #expect(transcript == "bonjour")
        #expect(pipeline.stage(for: "m1") == .finished)
        #expect(pipeline.outputs["m1"]?.translation == nil)
        #expect(pipeline.outputs["m1"]?.recommendation == nil)
    }

    /// The submit path attributes a transcript to the local engine, so the
    /// output has to carry the model and language alongside the text.
    @Test func transcribeOnlyCarriesAttribution() async {
        let pipeline = makePipeline()
        _ = await pipeline.transcribeOnly(for: input())
        #expect(pipeline.outputs["m1"]?.model == "apple-speech-analyzer")
        #expect(pipeline.outputs["m1"]?.language == "fr")
    }

    @Test func trimsWhitespaceFromTranscript() async {
        let pipeline = makePipeline(transcriber: StubTranscriber(text: "  bonjour \n"))
        _ = await pipeline.transcribeOnly(for: input())
        #expect(pipeline.outputs["m1"]?.transcript == "bonjour")
    }

    @Test func runsIndependentlyPerMessage() async {
        let pipeline = makePipeline()
        _ = await pipeline.run(for: input("a"))
        #expect(pipeline.stage(for: "a") == .finished)
        #expect(pipeline.stage(for: "b") == .idle)
    }

    @Test func passesTheLanguageHintToTranslation() async {
        let translator = SpyTranslator()
        let pipeline = OnDeviceReviewPipeline(
            dispatcher: InProcessOperatorJobDispatcher(
                transcriber: StubTranscriber(),
                translator: translator,
                moderator: StubModerator(),
                audioFetcher: StubAudioFetcher()
            )
        )
        _ = await pipeline.run(for: input())
        // Dropping it would force Foundation Models to re-detect the language
        // the Operator already knows.
        #expect(translator.receivedSourceLanguage == "fr")
    }

    /// A device that can transcribe but has no language model (Apple
    /// Intelligence off or still downloading) must still be able to serve the
    /// "needs transcription" queues.
    @Test func transcriptionWorksWithoutALanguageModel() async {
        let pipeline = makePipeline(translator: nil, moderator: nil)
        #expect(pipeline.supportsTranslation == false)
        #expect(await pipeline.transcribeOnly(for: input()) == "bonjour")
        #expect(pipeline.stage(for: "m1") == .finished)
    }

    @Test func supportsTranslationWhenTheModelIsPresent() {
        #expect(makePipeline().supportsTranslation)
    }

    // MARK: - Failure handling

    @Test func emptyTranscriptFails() async {
        let pipeline = makePipeline(transcriber: StubTranscriber(text: "   \n "))
        let result = await pipeline.run(for: input())

        #expect(result == nil)
        #expect(pipeline.stage(for: "m1") == .failed("On-device transcription produced no speech."))
        #expect(pipeline.outputs["m1"] == nil)
    }

    /// A silent recording is a real outcome, not a failure: the Operator
    /// accepts empty transcript text, and submitting it is the only way the
    /// "needs transcription" queue ever clears such a message.
    @Test func emptyTranscriptIsSubmittableFromTranscribeOnly() async {
        let pipeline = makePipeline(transcriber: StubTranscriber(text: "   \n "))
        #expect(await pipeline.transcribeOnly(for: input()) == "")
        #expect(pipeline.stage(for: "m1") == .finished)
        #expect(pipeline.outputs["m1"]?.transcript == "")
        // Attribution still travels with it, so the Operator can record which
        // engine heard nothing.
        #expect(pipeline.outputs["m1"]?.model == "apple-speech-analyzer")
    }

    @Test func moderationFailureStillYieldsTranslation() async {
        let pipeline = makePipeline(moderator: StubModerator(error: .timeout("slow")))
        let translation = await pipeline.run(for: input())

        #expect(translation == "hello")
        #expect(pipeline.stage(for: "m1") == .finished)
        #expect(pipeline.outputs["m1"]?.translation == "hello")
        #expect(pipeline.outputs["m1"]?.recommendation == nil)
        #expect(pipeline.outputs["m1"]?.flagged == nil)
    }

    @Test func translationFailureFailsTheRun() async {
        let pipeline = makePipeline(translator: StubTranslator(error: .unavailable("off")))
        let result = await pipeline.run(for: input())

        #expect(result == nil)
        #expect(pipeline.stage(for: "m1") == .failed(
            "Couldn’t translate that transcript: Apple Intelligence isn’t available on this device."
        ))
        #expect(pipeline.outputs["m1"] == nil)
    }

    @Test(arguments: [
        (AudioFetchError.hashMismatch, "the audio failed its integrity check."),
        (AudioFetchError.tooLarge, "the audio is too large to process on this device."),
        (AudioFetchError.insecureURL, "the audio URL wasn’t secure.")
    ])
    func audioFailuresMapToOperatorCopy(error: AudioFetchError, expectedSuffix: String) async {
        let pipeline = makePipeline(fetcher: StubAudioFetcher(failWith: error))
        _ = await pipeline.run(for: input())
        #expect(pipeline.stage(for: "m1") == .failed("Couldn’t transcribe that audio: \(expectedSuffix)"))
    }

    @Test func transcriberUnauthorizedAsksForPermission() async {
        let pipeline = makePipeline(transcriber: StubTranscriber(error: .unauthorized("denied")))
        _ = await pipeline.transcribeOnly(for: input())
        #expect(pipeline.stage(for: "m1") == .failed(
            "Couldn’t transcribe that audio: grant speech recognition permission in Settings."
        ))
    }

    /// The operator-facing copy must never leak transcript or audio content, so
    /// the underlying (content-free) upstream text stays out of it.
    @Test func failureCopyOmitsUpstreamDetail() async {
        let pipeline = makePipeline(transcriber: StubTranscriber(error: .unavailable("SECRET-DETAIL")))
        _ = await pipeline.run(for: input())
        guard case .failed(let message) = pipeline.stage(for: "m1") else {
            Issue.record("expected a failed stage")
            return
        }
        #expect(!message.contains("SECRET-DETAIL"))
    }

    // MARK: - Reset and concurrency

    @Test func pruneDropsStateForMessagesNoLongerInTheQueue() async {
        let pipeline = makePipeline()
        _ = await pipeline.run(for: input("keep"))
        _ = await pipeline.run(for: input("gone"))

        pipeline.prune(keeping: ["keep"])

        // Transcripts must not stay resident once a message leaves the queue.
        #expect(pipeline.outputs["gone"] == nil)
        #expect(pipeline.stage(for: "gone") == .idle)
        #expect(pipeline.outputs["keep"]?.transcript == "bonjour")
        #expect(pipeline.stage(for: "keep") == .finished)
    }

    @Test func pruneSupersedesAnInFlightRun() async {
        let gate = Gate()
        let pipeline = makePipeline(transcriber: StubTranscriber(gate: gate))

        let task = Task { await pipeline.run(for: input("gone")) }
        while !pipeline.isRunning("gone") { await Task.yield() }

        pipeline.prune(keeping: [])
        await gate.open()

        #expect(await task.value == nil)
        #expect(pipeline.outputs["gone"] == nil)
    }

    @Test func resetClearsResult() async {
        let pipeline = makePipeline()
        _ = await pipeline.run(for: input())
        #expect(pipeline.stage(for: "m1") == .finished)

        pipeline.reset("m1")
        #expect(pipeline.stage(for: "m1") == .idle)
        #expect(pipeline.outputs["m1"] == nil)
    }

    @Test func resetSupersedesAnInFlightRun() async {
        let gate = Gate()
        let pipeline = makePipeline(transcriber: StubTranscriber(gate: gate))

        let task = Task { await pipeline.run(for: input()) }
        while !pipeline.isRunning("m1") { await Task.yield() }
        #expect(pipeline.stage(for: "m1") == .fetchingAndTranscribing)

        pipeline.reset("m1")
        await gate.open()

        #expect(await task.value == nil)
        #expect(pipeline.stage(for: "m1") == .idle)
        #expect(pipeline.outputs["m1"] == nil)
    }

    @Test func aSecondRunIsRejectedWhileOneIsInFlight() async {
        let gate = Gate()
        let pipeline = makePipeline(transcriber: StubTranscriber(gate: gate))

        let task = Task { await pipeline.run(for: input()) }
        while !pipeline.isRunning("m1") { await Task.yield() }

        #expect(await pipeline.run(for: input()) == nil)
        await gate.open()
        #expect(await task.value == "hello")
    }

    @Test func isRunningTracksEachStage() async {
        let gate = Gate()
        let pipeline = makePipeline(transcriber: StubTranscriber(gate: gate))

        let task = Task { await pipeline.run(for: input()) }
        while !pipeline.isRunning("m1") { await Task.yield() }
        await gate.open()
        _ = await task.value
        #expect(pipeline.isRunning("m1") == false)
    }
}
