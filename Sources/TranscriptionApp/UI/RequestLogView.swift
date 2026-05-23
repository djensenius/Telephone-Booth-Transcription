import SwiftUI
import TranscriptionCore

struct RequestLogView: View {
    @EnvironmentObject var host: ServerHost
    @State private var entries: [RequestLogEntry] = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Recent requests").font(.headline)
                Spacer()
                Button("Refresh") { refresh() }
                Button("Purge") {
                    Task { try? await host.logStore.purge(); refresh() }
                }
            }
            Table(entries) {
                TableColumn("When") { e in
                    Text(e.receivedAt.formatted(.dateTime.hour().minute().second()))
                        .font(.system(.body, design: .monospaced))
                }
                TableColumn("Method") { Text($0.method) }
                TableColumn("Path") { Text($0.path) }
                TableColumn("Status") {
                    Text("\($0.status)")
                        .foregroundStyle($0.status >= 400 ? .red : .primary)
                }
                TableColumn("ms") { Text("\($0.durationMs)") }
                TableColumn("Auth") {
                    Image(systemName: $0.authOK ? "checkmark.circle" : "xmark.circle.fill")
                        .foregroundStyle($0.authOK ? .green : .red)
                }
                TableColumn("Flagged") { e in
                    if let f = e.moderationFlagged {
                        Image(systemName: f ? "flag.fill" : "flag.slash")
                            .foregroundStyle(f ? .orange : .secondary)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
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
