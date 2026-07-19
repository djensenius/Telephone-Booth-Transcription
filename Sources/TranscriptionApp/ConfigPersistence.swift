#if os(macOS)
import Foundation
import TranscriptionCore

/// Persists `ServerConfig` to `UserDefaults` as JSON.
///
/// API keys are stored in the macOS Keychain (via `APIKeyStoring`), **not** in
/// UserDefaults. A one-time migration moves any keys that were previously
/// serialized in the DTO into Keychain.
enum ConfigPersistence {
    private static let key = "serverConfig.v1"

    static func save(_ config: ServerConfig, keyStore: any APIKeyStoring) {
        let dto = ConfigDTO(config)
        if let data = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Persist API keys in Keychain
        if case .proxy(let upstream) = config.transcriptionBackend {
            persistKey(upstream.apiKey, account: APIKeyAccount.transcription, store: keyStore)
        } else {
            persistKey(nil, account: APIKeyAccount.transcription, store: keyStore)
        }
        persistKey(config.translationUpstream.apiKey, account: APIKeyAccount.translation, store: keyStore)
        persistKey(config.moderationUpstream.apiKey, account: APIKeyAccount.moderation, store: keyStore)
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func load(keyStore: any APIKeyStoring) -> ServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard var dto = try? JSONDecoder().decode(ConfigDTO.self, from: data) else { return nil }

        // One-time migration: move keys from DTO into Keychain.
        // Only clear a key from the DTO if the Keychain write succeeds,
        // so a locked Keychain doesn't permanently lose the key.
        var migrated = false
        if let tKey = dto.transcriptionKey, !tKey.isEmpty {
            do {
                try keyStore.write(account: APIKeyAccount.transcription, value: tKey)
                dto.transcriptionKey = nil
                migrated = true
            } catch {
                // Leave in DTO for retry on next launch
            }
        }
        if let mKey = dto.moderationKey, !mKey.isEmpty {
            do {
                try keyStore.write(account: APIKeyAccount.moderation, value: mKey)
                dto.moderationKey = nil
                migrated = true
            } catch {
                // Leave in DTO for retry on next launch
            }
        }
        if let trKey = dto.translationKey, !trKey.isEmpty {
            do {
                try keyStore.write(account: APIKeyAccount.translation, value: trKey)
                dto.translationKey = nil
                migrated = true
            } catch {
                // Leave in DTO for retry on next launch
            }
        }
        if migrated, let cleaned = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(cleaned, forKey: key)
        }

        // Inject keys from Keychain into the in-memory config so Settings can
        // validate and warn about insecure URLs without serializing keys to
        // UserDefaults. Runtime startup still calls validated(), which strips
        // keys before forwarding to insecure upstreams.
        var config = dto.asConfig
        let transcriptionKey = try? keyStore.read(account: APIKeyAccount.transcription)
        let translationKey = try? keyStore.read(account: APIKeyAccount.translation)
        let moderationKey = try? keyStore.read(account: APIKeyAccount.moderation)
        if case .proxy(var upstream) = config.transcriptionBackend {
            upstream.apiKey = transcriptionKey
            config.transcriptionBackend = .proxy(upstream)
        }
        config.translationUpstream.apiKey = translationKey
        config.moderationUpstream.apiKey = moderationKey

        var validated = config.validated()
        if case .proxy(var upstream) = validated.transcriptionBackend {
            upstream.apiKey = transcriptionKey
            validated.transcriptionBackend = .proxy(upstream)
        }
        validated.translationUpstream.apiKey = translationKey
        validated.moderationUpstream.apiKey = moderationKey
        return validated
    }

    private static func persistKey(_ value: String?, account: String, store: any APIKeyStoring) {
        if let key = value, !key.isEmpty {
            try? store.write(account: account, value: key)
        } else {
            try? store.delete(account: account)
        }
    }

    private struct ConfigDTO: Codable {
        var bindHost: String
        var bindPort: Int
        var transcriptionBackendKind: String       // "proxy" | "nativeMacOS" | "appleSpeechAnalyzer"
        var transcriptionBase: String
        // Optional for migration: older saves predate the on-device text
        // services and decode as nil → platform default in `asConfig`.
        var moderationBackendKind: String?          // "proxy" | "onDevice"
        var textTranslationBackendKind: String?     // "proxy" | "onDevice"
        // Retained for migration decoding only — never written to new saves.
        var transcriptionKey: String?
        var moderationBase: String
        // Retained for migration decoding only — never written to new saves.
        var moderationKey: String?
        var translationBase: String?
        var translationKey: String?
        var maxRequestBytes: Int
        var upstreamTimeoutSeconds: Double
        var maxConcurrentRequests: Int
        var logBodies: Bool
        var moderationFallbackEnabled: Bool
        var moderationModel: String
        var defaultTranscriptionModel: String?
        var defaultTranslationModel: String?
        var nativeTranscriptionLocale: String?
        var nonLoopbackBindAcknowledged: Bool?
        var operatorPollingEnabled: Bool?
        var operatorPollingBaseURL: String?
        var operatorPollingIntervalSeconds: Int?
        var operatorPollingLeaseSeconds: Int?
        var operatorPollingTranscription: Bool?
        var operatorPollingTranslation: Bool?
        var operatorPollingModeration: Bool?

        init(_ config: ServerConfig) {
            bindHost = config.bindHost
            bindPort = config.bindPort
            switch config.transcriptionBackend {
            case .proxy(let upstream):
                transcriptionBackendKind = "proxy"
                transcriptionBase = upstream.baseURL
            case .nativeMacOS:
                transcriptionBackendKind = "nativeMacOS"
                transcriptionBase = UpstreamConfig.defaultTranscription.baseURL
            case .appleSpeechAnalyzer:
                transcriptionBackendKind = "appleSpeechAnalyzer"
                transcriptionBase = UpstreamConfig.defaultTranscription.baseURL
            }
            // Keys are never serialized to UserDefaults
            transcriptionKey = nil
            moderationBackendKind = config.moderationBackend.rawValue
            textTranslationBackendKind = config.textTranslationBackend.rawValue
            moderationBase = config.moderationUpstream.baseURL
            moderationKey = nil
            translationBase = config.translationUpstream.baseURL
            // Keys are never serialized to UserDefaults
            translationKey = nil
            maxRequestBytes = config.maxRequestBytes
            upstreamTimeoutSeconds = config.upstreamTimeout.seconds
            maxConcurrentRequests = config.maxConcurrentRequests
            logBodies = config.logBodies
            moderationFallbackEnabled = config.moderationFallbackEnabled
            moderationModel = config.moderationModel
            defaultTranscriptionModel = config.defaultTranscriptionModel
            defaultTranslationModel = config.defaultTranslationModel
            nativeTranscriptionLocale = config.nativeTranscriptionLocale
            nonLoopbackBindAcknowledged = config.nonLoopbackBindAcknowledged
            operatorPollingEnabled = config.operatorPolling.enabled
            operatorPollingBaseURL = config.operatorPolling.baseURL
            operatorPollingIntervalSeconds = config.operatorPolling.pollIntervalSeconds
            operatorPollingLeaseSeconds = config.operatorPolling.leaseSeconds
            operatorPollingTranscription = config.operatorPolling.transcriptionEnabled
            operatorPollingTranslation = config.operatorPolling.translationEnabled
            operatorPollingModeration = config.operatorPolling.moderationEnabled
        }

        var asConfig: ServerConfig {
            let backend: TranscriptionBackend
            switch transcriptionBackendKind {
            case "nativeMacOS":
                backend = .nativeMacOS
            case "appleSpeechAnalyzer":
                backend = .appleSpeechAnalyzer
            default:
                backend = .proxy(.init(baseURL: transcriptionBase, apiKey: nil))
            }
            let translationUpstream: UpstreamConfig
            if let translationBase, !translationBase.isEmpty {
                translationUpstream = .init(baseURL: translationBase, apiKey: nil)
            } else {
                translationUpstream = .defaultTranslation
            }
            return ServerConfig(
                bindHost: bindHost,
                bindPort: bindPort,
                transcriptionBackend: backend,
                moderationBackend: moderationBackendKind
                    .flatMap(TextServiceBackend.init(rawValue:)) ?? ServerConfig.defaultTextServiceBackend,
                textTranslationBackend: textTranslationBackendKind
                    .flatMap(TextServiceBackend.init(rawValue:)) ?? ServerConfig.defaultTextServiceBackend,
                moderationUpstream: .init(baseURL: moderationBase, apiKey: nil),
                translationUpstream: translationUpstream,
                maxRequestBytes: maxRequestBytes,
                upstreamTimeout: .seconds(upstreamTimeoutSeconds),
                maxConcurrentRequests: maxConcurrentRequests,
                logBodies: logBodies,
                moderationFallbackEnabled: moderationFallbackEnabled,
                moderationModel: moderationModel,
                defaultTranscriptionModel: defaultTranscriptionModel ?? "",
                defaultTranslationModel: defaultTranslationModel ?? "",
                nativeTranscriptionLocale: nativeTranscriptionLocale ?? "en-US",
                nonLoopbackBindAcknowledged: nonLoopbackBindAcknowledged ?? false,
                operatorPolling: OperatorPollingConfig(
                    enabled: operatorPollingEnabled ?? false,
                    baseURL: operatorPollingBaseURL ?? "",
                    pollIntervalSeconds: operatorPollingIntervalSeconds ?? 5,
                    leaseSeconds: operatorPollingLeaseSeconds ?? 60,
                    transcriptionEnabled: operatorPollingTranscription ?? true,
                    translationEnabled: operatorPollingTranslation ?? true,
                    moderationEnabled: operatorPollingModeration ?? true
                )
            )
        }
    }
}
#endif
