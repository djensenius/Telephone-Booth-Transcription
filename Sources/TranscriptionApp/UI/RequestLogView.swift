import SwiftUI
import TranscriptionCore

struct RequestLogView: View {
    @EnvironmentObject var host: ServerHost
    @State private var entries: [RequestLogEntry] = []
    @State private var loadTask: Task<Void, Never>?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var useCompactLayout: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

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
                if useCompactLayout {
                    compactList
                } else {
                    table
                }
            }
            .glassCard()
        }
        .padding(Theme.Spacing.large)
        .onAppear { refresh() }
    }

    private var table: some View {
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

    private var compactList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    RequestRow(entry: entry)
                    if entry.id != entries.last?.id {
                        Divider().overlay(Theme.Colors.textSecondary.opacity(0.2))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
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

private struct RequestRow: View {
    let entry: RequestLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Text(entry.method)
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(entry.path)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.small)
                Text("\(entry.status)")
                    .font(Theme.Fonts.bodyMedium.weight(.semibold))
                    .foregroundStyle(entry.status >= 400 ? Theme.Colors.error : Theme.Colors.success)
            }

            HStack(spacing: Theme.Spacing.medium) {
                Label(
                    entry.receivedAt.formatted(.dateTime.hour().minute().second()),
                    systemImage: "clock"
                )
                Label("\(entry.durationMs) ms", systemImage: "timer")
                if let model = entry.model, !model.isEmpty {
                    Label(model, systemImage: "cpu")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if let flagged = entry.moderationFlagged {
                    Image(systemName: flagged ? "flag.fill" : "flag.slash")
                        .foregroundStyle(flagged ? Theme.Colors.warning : Theme.Colors.textSecondary)
                }
                Image(systemName: entry.authOK ? "checkmark.circle" : "xmark.circle.fill")
                    .foregroundStyle(entry.authOK ? Theme.Colors.success : Theme.Colors.error)
            }
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.vertical, Theme.Spacing.medium)
        .padding(.horizontal, Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    RequestLogView()
        .environmentObject(ServerHost(demo: true))
        .frame(width: 820, height: 600)
}
