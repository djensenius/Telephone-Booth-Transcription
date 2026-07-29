import SwiftUI
#if os(macOS)
import TranscriptionAuth
import TranscriptionCore

#if canImport(Speech)
import Speech
#endif

// swiftlint:disable:next type_body_length
struct SettingsView: View {
    @EnvironmentObject var host: ServerHost
    @State private var auth = AuthManager.shared

    @State private var transcriptionModels: [String] = []
    @State private var moderationModels: [String] = []
    @State var translationModels: [String] = []
    @State private var isLoadingTranscriptionModels = false
    @State private var isLoadingModerationModels = false
    @State var isLoadingTranslationModels = false

    private enum BackendKind: String, CaseIterable, Identifiable {
        case proxy
        case appleSpeechAnalyzer
        case nativeMacOS
        var id: String { rawValue }
        var label: String {
            switch self {
            case .proxy: return "Proxy (LM Studio / OpenAI-compatible)"
            #if os(macOS)
            case .appleSpeechAnalyzer: return "macOS 26 Speech Analyzer (Apple Intelligence)"
            case .nativeMacOS: return "macOS legacy Speech Recognizer"
            #else
            case .appleSpeechAnalyzer: return "Speech Analyzer (Apple Intelligence)"
            case .nativeMacOS: return "Legacy Speech Recognizer"
            #endif
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

    /// One-click switch to fully-local operation, plus a live indicator of
    /// whether any route can still reach the network.
    @ViewBuilder
    private var allLocalSection: some View {
        Section("Privacy mode") {
            if host.config.isFullyLocal {
                Label("All local — transcription, translation, and moderation "
                      + "run on this Mac with Apple Intelligence. No request "
                      + "leaves the machine.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("Some routes proxy to a network upstream.",
                      systemImage: "network")
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .font(.caption)
                Button("Switch everything to on-device") {
                    host.config = host.config.withAllLocalBackends()
                }
                Text("Sets transcription to the macOS 26 Speech Analyzer and "
                     + "moderation, text translation, and audio translation to "
                     + "Apple Intelligence. Upstream URLs are kept so you can "
                     + "switch back. Requires Apple Intelligence to be enabled "
                     + "in System Settings.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    var body: some View {
        Form {
            AccountSettingsSection()
            allLocalSection
            Section("Server") {
                TextField("Bind host", text: Binding(
                    get: { host.config.bindHost },
                    set: { host.config.bindHost = $0 }
                ))
                if !host.config.isLoopbackHost
                    && !host.config.bindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Toggle("Allow non-loopback bind (insecure without TLS)", isOn: Binding(
                        get: { host.config.nonLoopbackBindAcknowledged },
                        set: { host.config.nonLoopbackBindAcknowledged = $0 }
                    ))
                    Text("⚠️ Binding to a network address exposes bearer tokens and "
                         + "audio/text payloads in plaintext. Use a TLS reverse proxy "
                         + "if remote clients need access.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Stepper(value: Binding(
                    get: { host.config.bindPort },
                    set: { host.config.bindPort = $0 }
                ), in: 1...65535) {
                    LabeledContent("Bind port", value: "\(host.config.bindPort)")
                }
                #if os(macOS)
                Toggle("Prevent Mac from sleeping while running", isOn: $host.preventSleep)
                #else
                Toggle("Prevent device from sleeping while running", isOn: $host.preventSleep)
                #endif
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
                        get: { host.transcriptionAPIKey() },
                        set: { newValue in host.setTranscriptionAPIKey(newValue) }
                    ))
                    if case .failure = proxyUpstream.validateSecurity() {
                        Label("HTTPS is required for remote upstreams with an API key. "
                              + "The key will not be sent over this connection.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
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

            Section("Text translation") {
                Picker("Text backend (/v1/translations)", selection: Binding(
                    get: { host.config.textTranslationBackend },
                    set: { host.config.textTranslationBackend = $0 }
                )) {
                    Text("On-device (Apple Intelligence)").tag(TextServiceBackend.onDevice)
                    Text("Proxy (chat-completions upstream)").tag(TextServiceBackend.proxy)
                }
                .pickerStyle(.inline)

                Picker("Audio backend (/v1/audio/translations)", selection: Binding(
                    get: { host.config.audioTranslationBackend },
                    set: { host.config.audioTranslationBackend = $0 }
                )) {
                    Text("On-device (transcribe, then translate the text)")
                        .tag(TextServiceBackend.onDevice)
                    Text("Proxy (Whisper-compatible upstream)").tag(TextServiceBackend.proxy)
                }
                .pickerStyle(.inline)

                if host.config.audioTranslationBackend == .onDevice {
                    Text("""
                         Apple ships no direct speech→English model, so audio \
                         translation runs in two on-device steps: the Speech \
                         engine transcribes the audio, then Apple Intelligence \
                         translates that text. Slower than a single Whisper \
                         call, but no audio or text leaves this Mac.
                         """)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                if host.config.textTranslationBackend == .onDevice {
                    Text("""
                         Text→English (`/v1/translations`) runs on-device with \
                         Apple Intelligence — no upstream required. Returns \
                         `503 on_device_unavailable` if Apple Intelligence is \
                         turned off or unsupported on this device.
                         """)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                if host.config.textTranslationBackend == .proxy
                    || host.config.audioTranslationBackend == .proxy {
                    translationUpstreamFields
                } else {
                    DisclosureGroup("Translation upstream (unused in on-device mode)") {
                        translationUpstreamFields
                    }
                }
            }

            Section("Moderation") {
                Picker("Backend", selection: Binding(
                    get: { host.config.moderationBackend },
                    set: { host.config.moderationBackend = $0 }
                )) {
                    Text("On-device (Apple Intelligence)").tag(TextServiceBackend.onDevice)
                    Text("Proxy (LM Studio / OpenAI-compatible)").tag(TextServiceBackend.proxy)
                }
                .pickerStyle(.inline)

                if host.config.moderationBackend == .onDevice {
                    Text("Classifies entirely on-device with Apple Intelligence " +
                         "Foundation Models — no upstream required. Returns a single " +
                         "`flagged` decision with all-zero category scores, and " +
                         "`503 on_device_unavailable` if Apple Intelligence is turned " +
                         "off or unsupported on this device.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else {
                    TextField("Base URL", text: Binding(
                        get: { host.config.moderationUpstream.baseURL },
                        set: { host.config.moderationUpstream.baseURL = $0 }
                    ))
                    SecureField("API key (optional)", text: Binding(
                        get: { host.moderationAPIKey() },
                        set: { newValue in host.setModerationAPIKey(newValue) }
                    ))
                    if case .failure = host.config.moderationUpstream.validateSecurity() {
                        Label("HTTPS is required for remote upstreams with an API key. "
                              + "The key will not be sent over this connection.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
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

            operatorWorkerSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .foregroundStyle(Theme.Colors.textPrimary)
        .task {
            await reloadTranscriptionModels()
            await reloadTranslationModels()
            await reloadModerationModels()
        }
    }

    func reloadTranslationModels() async {
        isLoadingTranslationModels = true
        defer { isLoadingTranslationModels = false }
        translationModels = await host.fetchModels(
            from: host.config.translationUpstream.baseURL,
            apiKey: host.config.translationUpstream.apiKey
        )
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
        guard host.config.moderationBackend == .proxy else {
            moderationModels = []
            return
        }
        isLoadingModerationModels = true
        defer { isLoadingModerationModels = false }
        moderationModels = await host.fetchModels(
            from: host.config.moderationUpstream.baseURL,
            apiKey: host.config.moderationUpstream.apiKey
        )
    }

    private func nativeLocales(for kind: BackendKind) -> [String] {
        #if canImport(Speech) && os(macOS)
        // Note: when `kind == .appleSpeechAnalyzer` we'd ideally surface
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
#Preview {
    SettingsView()
        .environmentObject(ServerHost(demo: true))
        .frame(width: 820, height: 600)
}
#else

/// iOS settings: account-only. The transcription server, upstreams, and the
/// Operator push worker are macOS ("Pro") features, so on iOS the app is a
/// review/translation client that just needs an Operator sign-in to poll.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                AccountSettingsSection()
                Section("About") {
                    Text("This device reviews and translates messages by polling "
                         + "the Operator. The transcription server is a feature of "
                         + "the Mac app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
#endif
