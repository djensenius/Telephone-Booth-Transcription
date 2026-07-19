#if os(macOS)
import Foundation
import Logging
import TranscriptionCore

extension ServerHost {
    func currentToken() -> String {
        (try? tokenStore.current()) ?? ""
    }

    /// Returns the transcription upstream API key from Keychain, or empty string.
    func transcriptionAPIKey() -> String {
        (try? apiKeyStore.read(account: APIKeyAccount.transcription)) ?? ""
    }

    /// Returns the moderation upstream API key from Keychain, or empty string.
    func moderationAPIKey() -> String {
        (try? apiKeyStore.read(account: APIKeyAccount.moderation)) ?? ""
    }

    /// Returns the translation upstream API key from Keychain, or empty string.
    func translationAPIKey() -> String {
        (try? apiKeyStore.read(account: APIKeyAccount.translation)) ?? ""
    }

    /// Persists the transcription API key to Keychain and updates the in-memory config.
    func setTranscriptionAPIKey(_ value: String) {
        let key = value.isEmpty ? nil : value
        if case .proxy(var upstream) = config.transcriptionBackend {
            upstream.apiKey = key
            config.transcriptionBackend = .proxy(upstream)
        }
    }

    /// Persists the moderation API key to Keychain and updates the in-memory config.
    func setModerationAPIKey(_ value: String) {
        config.moderationUpstream.apiKey = value.isEmpty ? nil : value
    }

    /// Persists the translation API key to Keychain and updates the in-memory config.
    func setTranslationAPIKey(_ value: String) {
        config.translationUpstream.apiKey = value.isEmpty ? nil : value
    }

    /// Returns the Operator push API token from Keychain, or empty string.
    func operatorAPIKey() -> String {
        (try? apiKeyStore.read(account: APIKeyAccount.operatorPull)) ?? ""
    }

    /// Persists the Operator push API token to Keychain.
    func setOperatorAPIKey(_ value: String) {
        do {
            if value.isEmpty {
                try apiKeyStore.delete(account: APIKeyAccount.operatorPull)
            } else {
                try apiKeyStore.write(account: APIKeyAccount.operatorPull, value: value)
            }
            Task { await self.reconcileOperatorWorker() }
        } catch {
            Logger(label: "server-host").error("operator token save failed: \(error)")
        }
    }

    // MARK: - Model discovery

    /// Fetches `/v1/models` from one of the user's configured upstreams (or
    /// from this server itself once it's running) so the UI can populate
    /// model pickers. Returns an empty list on any failure.
    func fetchModels(from baseURL: String, apiKey: String?) async -> [String] {
        if isDemo { return [] }
        guard !baseURL.isEmpty,
              let url = URL(string: baseURL.hasSuffix("/")
                            ? "\(baseURL)models"
                            : "\(baseURL)/models") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let upstream = UpstreamConfig(baseURL: baseURL, apiKey: apiKey).strippingKeyIfInsecure()
        if let key = upstream.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["data"] as? [[String: Any]] else {
                return []
            }
            return list.compactMap { $0["id"] as? String }.sorted()
        } catch {
            return []
        }
    }
}
#endif
