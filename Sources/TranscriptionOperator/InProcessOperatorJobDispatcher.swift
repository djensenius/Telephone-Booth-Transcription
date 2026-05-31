import Foundation
import Logging
import TranscriptionShared

/// `OperatorJobDispatcher` that runs jobs entirely in-process against injected
/// on-device services — no loopback HTTP. Used by pull/sync clients (and usable
/// on macOS). For transcription it streams the audio to a verified temp file
/// first; translation and moderation operate on the inline payload text.
///
/// **Privacy:** every failure is mapped to a fixed code/message. No audio
/// bytes, transcript/translation text, moderation input, URL, filename, or hash
/// is ever placed in an `OperatorJobError` or log line.
public final class InProcessOperatorJobDispatcher: OperatorJobDispatcher {
    private let transcriber: (any AudioTranscriber)?
    private let translator: (any TextTranslationService)?
    private let moderator: (any TextModerationService)?
    private let audioFetcher: any AudioFetching
    private let maxAudioBytes: Int
    private let logger: Logger

    public init(
        transcriber: (any AudioTranscriber)? = nil,
        translator: (any TextTranslationService)? = nil,
        moderator: (any TextModerationService)? = nil,
        audioFetcher: any AudioFetching,
        maxAudioBytes: Int = 100 * 1024 * 1024,
        logger: Logger = Logger(label: "inprocess-dispatcher")
    ) {
        self.transcriber = transcriber
        self.translator = translator
        self.moderator = moderator
        self.audioFetcher = audioFetcher
        self.maxAudioBytes = maxAudioBytes
        self.logger = logger
    }

    /// The job kinds this dispatcher can actually run, derived from which
    /// services were injected. Callers use this to compute the worker's
    /// leasing capabilities.
    public var supportedKinds: Set<OperatorJob.Kind> {
        var kinds: Set<OperatorJob.Kind> = []
        if transcriber != nil { kinds.insert(.transcription) }
        if translator != nil { kinds.insert(.translation) }
        if moderator != nil { kinds.insert(.moderation) }
        return kinds
    }

    public func execute(job: OperatorJob) async throws -> OperatorJobResult {
        switch job.payload {
        case .transcription(let payload):
            return try await runTranscription(payload)
        case .translation(let payload):
            return try await runTranslation(payload)
        case .moderation(let payload):
            return try await runModeration(payload)
        }
    }

    private func runTranscription(_ payload: OperatorJob.TranscriptionPayload) async throws -> OperatorJobResult {
        guard let transcriber else {
            throw OperatorJobError(code: "transcription_unsupported",
                                   message: "device cannot perform transcription")
        }
        do {
            let text = try await audioFetcher.withFetchedAudioFile(
                url: payload.audioURL,
                expectedSHA256: payload.sha256,
                maxBytes: maxAudioBytes,
                suggestedExtension: Self.extensionHint(filename: payload.filename, contentType: payload.contentType)
            ) { fileURL in
                try await transcriber.transcribe(audioFileURL: fileURL, language: payload.language)
            }
            return .transcription(text: text, language: payload.language, model: payload.model)
        } catch let error as AudioFetchError {
            throw Self.map(error)
        } catch let error as OnDeviceServiceError {
            throw Self.sanitize(error, kind: "transcription")
        } catch let error as OperatorJobError {
            throw error
        } catch {
            logger.debug("transcription failed: \(type(of: error))")
            throw OperatorJobError(code: "transcription_failed", message: "local transcription failed")
        }
    }

    private func runTranslation(_ payload: OperatorJob.TranslationPayload) async throws -> OperatorJobResult {
        guard let translator else {
            throw OperatorJobError(code: "translation_unsupported",
                                   message: "device cannot perform translation")
        }
        do {
            let result = try await translator.translate(payload.input, sourceLanguage: payload.sourceLanguage)
            return .translation(
                translatedText: result.translatedText,
                sourceLanguage: result.sourceLanguage,
                targetLanguage: result.targetLanguage,
                model: result.model
            )
        } catch let error as OnDeviceServiceError {
            throw Self.sanitize(error, kind: "translation")
        } catch let error as OperatorJobError {
            throw error
        } catch {
            logger.debug("translation failed: \(type(of: error))")
            throw OperatorJobError(code: "translation_failed", message: "local translation failed")
        }
    }

    private func runModeration(_ payload: OperatorJob.ModerationPayload) async throws -> OperatorJobResult {
        guard let moderator else {
            throw OperatorJobError(code: "moderation_unsupported",
                                   message: "device cannot perform moderation")
        }
        do {
            let verdict = try await moderator.moderate(payload.input)
            return .moderation(
                flagged: verdict.flagged,
                recommendation: verdict.recommendation,
                maxScore: verdict.maxScore,
                model: verdict.model
            )
        } catch let error as OnDeviceServiceError {
            throw Self.sanitize(error, kind: "moderation")
        } catch let error as OperatorJobError {
            throw error
        } catch {
            logger.debug("moderation failed: \(type(of: error))")
            throw OperatorJobError(code: "moderation_failed", message: "local moderation failed")
        }
    }

    // MARK: - Error sanitization

    static func sanitize(_ error: OnDeviceServiceError, kind: String) -> OperatorJobError {
        let code: String
        switch error {
        case .badRequest:
            code = "\(kind)_bad_input"
        case .unauthorized:
            code = "\(kind)_unauthorized"
        case .timeout:
            code = "\(kind)_timeout"
        case .unavailable:
            code = "\(kind)_unavailable"
        }
        return OperatorJobError(code: code, message: "local \(kind) failed")
    }

    static func map(_ error: AudioFetchError) -> OperatorJobError {
        switch error {
        case .invalidExpectedHash:
            return OperatorJobError(code: "audio_sha256_invalid", message: "audio hash was not valid")
        case .tooLarge:
            return OperatorJobError(code: "audio_too_large", message: "audio exceeded size limit")
        case .hashMismatch:
            return OperatorJobError(code: "audio_sha256_mismatch", message: "audio failed integrity check")
        case .insecureURL:
            return OperatorJobError(code: "audio_insecure_url", message: "audio URL was not https")
        case .fetchFailed:
            return OperatorJobError(code: "audio_fetch_failed", message: "failed to fetch audio")
        }
    }

    private static func extensionHint(filename: String?, contentType: String?) -> String? {
        if let filename, let dot = filename.lastIndex(of: "."), dot < filename.endIndex {
            let ext = String(filename[filename.index(after: dot)...])
            if !ext.isEmpty { return ext }
        }
        switch contentType?.lowercased() {
        case "audio/flac": return "flac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/ogg": return "ogg"
        default: return nil
        }
    }
}
