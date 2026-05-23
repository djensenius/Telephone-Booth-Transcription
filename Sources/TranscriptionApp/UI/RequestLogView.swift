import SwiftUI
import TranscriptionCore

struct RequestLogView: View {
    @EnvironmentObject var host: ServerHost
    @State private var entries: [RequestLogEntry] = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack {
                Text("Recent requests")
                    .font(Theme.Fonts.headerLarge())
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                Button("Refresh") { refresh() }
                    .buttonStyle(.tbtGlass)
                Button("Purge") {
                    Task { try? await host.logStore.purge(); refresh() }
                }
                .buttonStyle(.tbtGlass)
            }

            VStack {
                Table(entries) {
                    TableColumn("When") { e in
                        Text(e.receivedAt.formatted(.dateTime.hour().minute().second()))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Theme.Colors.textPrimary)
                    }
                    TableColumn("Method") {
                        Text($0.method).foregroundStyle(Theme.Colors.textPrimary)
                    }
                    TableColumn("Path") {
                        Text($0.path).foregroundStyle(Theme.Colors.textPrimary)
                    }
                    TableColumn("Status") {
                        Text("\($0.status)")
                            .foregroundStyle($0.status >= 400 ? Theme.Colors.error : Theme.Colors.textPrimary)
                    }
                    TableColumn("ms") {
                        Text("\($0.durationMs)").foregroundStyle(Theme.Colors.textSecondary)
                    }
                    TableColumn("Auth") {
                        Image(systemName: $0.authOK ? "checkmark.circle" : "xmark.circle.fill")
                            .foregroundStyle($0.authOK ? Theme.Colors.success : Theme.Colors.error)
                    }
                    TableColumn("Flagged") { e in
                        if let f = e.moderationFlagged {
                            Image(systemName: f ? "flag.fill" : "flag.slash")
                                .foregroundStyle(f ? Theme.Colors.warning : Theme.Colors.textSecondary)
                        } else {
                            Text("—").foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .glassCard()
        }
        .padding(Theme.Spacing.large)
        .onAppear { refresh() }
    }

    private func refresh() {
        loadTask?.cancel()
        loadTask = Task {
            do {
                let recent = try await host.logStore.recent(limit: 200)
                await MainActor.run { self.entries = recent }
            } catch {
                // Silently ignore; UI will reflect previous state.
            }
        }
    }
}
