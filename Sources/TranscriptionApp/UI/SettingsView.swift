import SwiftUI
import TranscriptionCore

#if canImport(Speech) && os(macOS)
import Speech
#endif

struct SettingsView: View {
    @EnvironmentObject var host: ServerHost

    @State private var transcriptionModels: [String] = []
    @State private var moderationModels: [String] = []
    @State private var isLoadingTranscriptionModels = false
    @State private var isLoadingModerationModels = false

    private enum BackendKind: String, CaseIterable, Identifiable {
        case proxy
        case appleSpeechAnalyzer
        case nativeMacOS
        var id: String { rawValue }
        var label: String {
            switch self {
            case .proxy: return "Proxy (LM Studio / OpenAI-compatible)"
            case .appleSpeechAnalyzer: return "macOS 26 Speech Analyzer (Apple Intelligence)"
            case .nativeMacOS: return "macOS legacy Speech Recognizer"
            }
        }
    }

    private var currentBackendKind: BackendKind {
        switch host.config.transcriptionBackend {
        case .nativeMacOS: return .nativeMacOS
        case .appleSpeechAnalyzer: return .appleSpeechAnalyzer
        case .proxy: return .proxy
        }
    }

    private var proxyUpstream: UpstreamConfig {
        if case .proxy(let cfg) = host.config.transcriptionBackend { return cfg }
        return .defaultTranscription
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Bind host", text: Binding(
                    get: { host.config.bindHost },
                    set: { host.config.bindHost = $0 }
                ))
                Stepper(value: Binding(
                    get: { host.config.bindPort },
                    set: { host.config.bindPort = $0 }
                ), in: 1...65535) {
                    LabeledContent("Bind port", value: "\(host.config.bindPort)")
                }
                Toggle("Prevent Mac from sleeping while running", isOn: $host.preventSleep)
            }

            Section("Transcription backend") {
                Picker("Backend", selection: Binding(
                    get: { currentBackendKind },
                    set: { newValue in
                        switch newValue {
                        case .proxy:
                            host.config.transcriptionBackend = .proxy(proxyUpstream)
                        case .nativeMacOS:
                            host.config.transcriptionBackend = .nativeMacOS
                        case .appleSpeechAnalyzer:
                            host.config.transcriptionBackend = .appleSpeechAnalyzer
                        }
                    }
                )) {
                    ForEach(BackendKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.inline)

                if currentBackendKind == .proxy {
                    TextField("Base URL", text: Binding(
                        get: { proxyUpstream.baseURL },
                        set: { newValue in
                            var cfg = proxyUpstream
                            cfg.baseURL = newValue
                            host.config.transcriptionBackend = .proxy(cfg)
                        }
                    ))
                    SecureField("API key (optional)", text: Binding(
                        get: { proxyUpstream.apiKey ?? "" },
                        set: { newValue in
                            var cfg = proxyUpstream
                            cfg.apiKey = newValue.isEmpty ? nil : newValue
                            host.config.transcriptionBackend = .proxy(cfg)
                        }
                    ))
                    HStack {
                        Picker("Default model", selection: Binding(
                            get: { host.config.defaultTranscriptionModel },
                            set: { host.config.defaultTranscriptionModel = $0 }
                        )) {
                            Text("— let client choose —").tag("")
                            ForEach(transcriptionModels, id: \.self) { Text($0).tag($0) }
                            if !host.config.defaultTranscriptionModel.isEmpty,
                               !transcriptionModels.contains(host.config.defaultTranscriptionModel) {
                                Text(host.config.defaultTranscriptionModel)
                                    .tag(host.config.defaultTranscriptionModel)
                            }
                        }
                        Button {
                            Task { await reloadTranscriptionModels() }
                        } label: {
                            if isLoadingTranscriptionModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .help("Refresh model list from upstream")
                    }
                    Text("Models are fetched from `<base URL>/models`. Default upstream " +
                         "is faster-whisper-server (`http://127.0.0.1:8000/v1`).")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else {
                    Picker("Locale", selection: Binding(
                        get: { host.config.nativeTranscriptionLocale },
                        set: { host.config.nativeTranscriptionLocale = $0 }
                    )) {
                        ForEach(nativeLocales(for: currentBackendKind), id: \.self) { id in
                            Text(displayName(for: id)).tag(id)
                        }
                        if !nativeLocales(for: currentBackendKind).contains(host.config.nativeTranscriptionLocale) {
                            Text(host.config.nativeTranscriptionLocale)
                                .tag(host.config.nativeTranscriptionLocale)
                        }
                    }
                    if currentBackendKind == .appleSpeechAnalyzer {
                        Text("Uses macOS 26's SpeechAnalyzer — the engine behind Apple " +
                             "Intelligence transcription. First use of a new locale may " +
                             "trigger a one-time on-device model download.")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    } else {
                        Text("Uses macOS's legacy SFSpeechRecognizer. Wider locale coverage " +
                             "than the SpeechAnalyzer engine and no model download, but " +
                             "lower accuracy. First use will prompt for permission.")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }

            Section("Moderation upstream") {
                TextField("Base URL", text: Binding(
                    get: { host.config.moderationUpstream.baseURL },
                    set: { host.config.moderationUpstream.baseURL = $0 }
                ))
                SecureField("API key (optional)", text: Binding(
                    get: { host.config.moderationUpstream.apiKey ?? "" },
                    set: { host.config.moderationUpstream.apiKey = $0.isEmpty ? nil : $0 }
                ))
                HStack {
                    Picker("Model", selection: Binding(
                        get: { host.config.moderationModel },
                        set: { host.config.moderationModel = $0 }
                    )) {
                        ForEach(moderationModels, id: \.self) { Text($0).tag($0) }
                        if !moderationModels.contains(host.config.moderationModel) {
                            Text(host.config.moderationModel).tag(host.config.moderationModel)
                        }
                    }
                    Button {
                        Task { await reloadModerationModels() }
                    } label: {
                        if isLoadingModerationModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("Refresh model list from upstream")
                }
                Toggle("Use chat-completion fallback when /v1/moderations is unavailable",
                       isOn: Binding(
                        get: { host.config.moderationFallbackEnabled },
                        set: { host.config.moderationFallbackEnabled = $0 }
                       ))
                Text("Default points at LM Studio (`http://127.0.0.1:1234/v1`). LM Studio " +
                     "does not implement `/v1/moderations`; the fallback uses chat-completions.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Section("Limits") {
                Stepper(value: Binding(
                    get: { host.config.maxRequestBytes },
                    set: { host.config.maxRequestBytes = $0 }
                ), in: 1_048_576...(1 * 1024 * 1024 * 1024), step: 1_048_576) {
                    LabeledContent("Max request size",
                                   value: "\(host.config.maxRequestBytes / 1_048_576) MB")
                }
                Stepper(value: Binding(
                    get: { host.config.maxConcurrentRequests },
                    set: { host.config.maxConcurrentRequests = $0 }
                ), in: 1...64) {
                    LabeledContent("Max concurrent requests",
                                   value: "\(host.config.maxConcurrentRequests)")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .foregroundStyle(Theme.Colors.textPrimary)
        .task {
            await reloadTranscriptionModels()
            await reloadModerationModels()
        }
    }

    private func reloadTranscriptionModels() async {
        guard case .proxy(let cfg) = host.config.transcriptionBackend else {
            transcriptionModels = []
            return
        }
        isLoadingTranscriptionModels = true
        defer { isLoadingTranscriptionModels = false }
        transcriptionModels = await host.fetchModels(from: cfg.baseURL, apiKey: cfg.apiKey)
    }

    private func reloadModerationModels() async {
        isLoadingModerationModels = true
        defer { isLoadingModerationModels = false }
        moderationModels = await host.fetchModels(
            from: host.config.moderationUpstream.baseURL,
            apiKey: host.config.moderationUpstream.apiKey
        )
    }

    private func nativeLocales(for kind: BackendKind) -> [String] {
        #if canImport(Speech) && os(macOS)
        // TODO: When `kind == .appleSpeechAnalyzer` we'd ideally surface
        // `SpeechTranscriber.supportedLocales` here, but that API is async
        // and the picker is built synchronously. As a pragmatic interim we
        // use `SFSpeechRecognizer.supportedLocales()` for both engines —
        // any locale not actually supported by `SpeechTranscriber` will be
        // rejected at runtime by `supportedLocale(equivalentTo:)`.
        _ = kind
        return SFSpeechRecognizer.supportedLocales()
            .map { $0.identifier }
            .sorted()
        #else
        _ = kind
        return ["en-US"]
        #endif
    }

    private func displayName(for identifier: String) -> String {
        let loc = Locale(identifier: identifier)
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        return "\(name) (\(loc.identifier))"
    }
}
