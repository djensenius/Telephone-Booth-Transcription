#if os(macOS)
import SwiftUI

extension SettingsView {
    // MARK: - Text translation

    @ViewBuilder
    var translationUpstreamFields: some View {
        TextField("Base URL", text: Binding(
            get: { host.config.translationUpstream.baseURL },
            set: { host.config.translationUpstream.baseURL = $0 }
        ))
        SecureField("API key (optional)", text: Binding(
            get: { host.translationAPIKey() },
            set: { newValue in host.setTranslationAPIKey(newValue) }
        ))
        if case .failure = host.config.translationUpstream.validateSecurity() {
            Label("HTTPS is required for remote upstreams with an API key. "
                  + "The key will not be sent over this connection.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
        }
        HStack {
            Picker("Default model", selection: Binding(
                get: { host.config.defaultTranslationModel },
                set: { host.config.defaultTranslationModel = $0 }
            )) {
                Text("(none — pass `model` per request)").tag("")
                ForEach(translationModels, id: \.self) { Text($0).tag($0) }
                if !host.config.defaultTranslationModel.isEmpty,
                   !translationModels.contains(host.config.defaultTranslationModel) {
                    Text(host.config.defaultTranslationModel)
                        .tag(host.config.defaultTranslationModel)
                }
            }
            Button {
                Task { await reloadTranslationModels() }
            } label: {
                if isLoadingTranslationModels {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Refresh model list from upstream")
        }
        Text("Used by audio→English translation (`/v1/audio/translations`) and " +
             "text translation (`/v1/translations`) whenever those backends are " +
             "set to Proxy. Both can instead run on-device with Apple " +
             "Intelligence. Default points at the same faster-whisper-server " +
             "(`:8000`) as transcription.")
            .font(.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
    }

}
#endif
