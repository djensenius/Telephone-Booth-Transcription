#if os(macOS)
import SwiftUI
import TranscriptionCore

extension SettingsView {
    // MARK: - Operator push worker

    @ViewBuilder
    var operatorWorkerSection: some View {
        Section("Operator push worker") {
            Toggle("Enable worker", isOn: Binding(
                get: { host.config.operatorPolling.enabled },
                set: { host.config.operatorPolling.enabled = $0 }
            ))
            Text("When on, this app subscribes to the Operator status WebSocket, "
                 + "runs requested translation and moderation work locally, and "
                 + "polls the Operator for messages that still need a "
                 + "transcription. Results are posted back as they finish.")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

            TextField("Operator base URL", text: Binding(
                get: { host.config.operatorPolling.baseURL },
                set: { host.config.operatorPolling.baseURL = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            SecureField("Operator API token", text: Binding(
                get: { host.operatorAPIKey() },
                set: { host.setOperatorAPIKey($0) }
            ))
            .textFieldStyle(.roundedBorder)

            Stepper(value: Binding(
                get: { host.config.operatorPolling.pollIntervalSeconds },
                set: { host.config.operatorPolling.pollIntervalSeconds = $0 }
            ), in: OperatorPollingConfig.minPollInterval...OperatorPollingConfig.maxPollInterval) {
                LabeledContent("Reconnect / discovery delay",
                               value: "\(host.config.operatorPolling.pollIntervalSeconds) s")
            }

            Toggle("Handle transcription work", isOn: Binding(
                get: { host.config.operatorPolling.transcriptionEnabled },
                set: { host.config.operatorPolling.transcriptionEnabled = $0 }
            ))
            Toggle("Handle translation work", isOn: Binding(
                get: { host.config.operatorPolling.translationEnabled },
                set: { host.config.operatorPolling.translationEnabled = $0 }
            ))
            Toggle("Handle moderation work", isOn: Binding(
                get: { host.config.operatorPolling.moderationEnabled },
                set: { host.config.operatorPolling.moderationEnabled = $0 }
            ))

            workerStatusRow
        }
    }

    @ViewBuilder
    private var workerStatusRow: some View {
        if let status = host.operatorWorkerStatus {
            LabeledContent("Worker status", value: statusDescription(status))
            if let code = status.lastErrorCode {
                LabeledContent("Last error", value: code)
                    .foregroundStyle(.red)
            }
            if let jobID = status.lastJobID {
                LabeledContent("Last job",
                               value: "\(status.lastJobKind?.rawValue ?? "?") · \(jobID)")
            }
            if let discoveredAt = status.lastDiscoveryAt {
                LabeledContent(
                    "Last discovery",
                    value: "\(discoveredAt.formatted(date: .omitted, time: .standard))"
                        + " · \(status.lastDiscoveredCount ?? 0) queued"
                )
            }
            if let code = status.lastDiscoveryErrorCode {
                LabeledContent(
                    "Discovery error",
                    value: status.lastDiscoveryErrorAt.map {
                        "\(code) · \($0.formatted(date: .omitted, time: .standard))"
                    } ?? code
                )
                .foregroundStyle(Theme.Colors.error)
            }
        } else {
            LabeledContent("Worker status", value: "stopped")
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func statusDescription(_ status: OperatorWorker.Status) -> String {
        switch status.phase {
        case .stopped: return "stopped"
        case .connecting: return "connecting"
        case .subscribed: return "subscribed"
        case .running: return "running"
        case .error: return "error"
        }
    }
}
#endif
