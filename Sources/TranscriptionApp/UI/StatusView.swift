import SwiftUI
import TranscriptionCore

struct StatusView: View {
    @EnvironmentObject var host: ServerHost
    @State private var revealToken = false

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("State", value: host.state.label)
                LabeledContent("Prevent sleep") {
                    Image(systemName: host.sleepAssertionHeld ? "moon.zzz.fill" : "moon.zzz")
                        .foregroundStyle(host.sleepAssertionHeld ? .yellow : .secondary)
                }

                HStack {
                    if host.state.isRunning {
                        Button("Stop") { host.stop() }
                            .keyboardShortcut(".", modifiers: [.command])
                    } else {
                        Button("Start") { host.start() }
                            .keyboardShortcut("r", modifiers: [.command])
                    }
                }
            }

            Section("Bearer token") {
                HStack {
                    if revealToken {
                        TextField("token", text: .constant(host.currentToken()))
                            .textSelection(.enabled)
                            .disabled(true)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text(String(repeating: "•", count: 32))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(host.currentToken(), forType: .string)
                    }
                    Button("Rotate") { host.rotateToken() }
                }
                Text("Send as `Authorization: Bearer <token>` to every endpoint except `/healthz`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
