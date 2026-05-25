import SwiftUI
import TranscriptionCore

struct StatusView: View {
    @EnvironmentObject var host: ServerHost
    @State private var revealToken = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Text("Telephone Booth Transcription")
                    .font(Theme.Fonts.headerXL())
                    .foregroundStyle(Theme.Colors.textPrimary)

                serverCard
                tokenCard
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Server")
                .font(Theme.Fonts.headerLarge())
                .foregroundStyle(Theme.Colors.textPrimary)

            HStack(spacing: Theme.Spacing.medium) {
                statePill
                Spacer()
                sleepIndicator
            }

            HStack(spacing: Theme.Spacing.medium) {
                if host.state.isActive {
                    Button("Stop") { Task { await host.stop() } }
                        .keyboardShortcut(".", modifiers: [.command])
                        .buttonStyle(.tbtPrimary)
                        .disabled(host.state == .stopping)
                } else {
                    Button("Start") { Task { await host.start() } }
                        .keyboardShortcut("r", modifiers: [.command])
                        .buttonStyle(.tbtPrimary)
                        .disabled(host.state == .starting)
                }
            }
        }
        .glassCard()
    }

    private var statePill: some View {
        HStack(spacing: Theme.Spacing.small) {
            Circle()
                .fill(host.state.isRunning ? Theme.Colors.success : Theme.Colors.textSecondary)
                .frame(width: 10, height: 10)
            Text(host.state.label)
                .font(Theme.Fonts.bodyMedium.weight(.medium))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Colors.tertiaryBackground.opacity(0.4))
        .clipShape(Capsule())
    }

    private var sleepIndicator: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: host.sleepAssertionHeld ? "moon.zzz.fill" : "moon.zzz")
                .foregroundStyle(host.sleepAssertionHeld
                                 ? Theme.Colors.warning
                                 : Theme.Colors.textSecondary)
            Text(host.sleepAssertionHeld ? "Sleep prevented" : "Sleep allowed")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Bearer token")
                .font(Theme.Fonts.headerLarge())
                .foregroundStyle(Theme.Colors.textPrimary)

            HStack(spacing: Theme.Spacing.medium) {
                if revealToken {
                    TextField("token", text: .constant(host.currentToken()))
                        .textSelection(.enabled)
                        .disabled(true)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Theme.Colors.textPrimary)
                } else {
                    Text(String(repeating: "•", count: 32))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                    .buttonStyle(.tbtGlass)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(host.currentToken(), forType: .string)
                }
                .buttonStyle(.tbtGlass)
                Button("Rotate") { host.rotateToken() }
                    .buttonStyle(.tbtGlass)
            }

            Text("Send as `Authorization: Bearer <token>` to every endpoint except `/healthz`.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .glassCard()
    }
}
