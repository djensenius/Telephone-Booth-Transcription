import SwiftUI

/// Account-only settings shared by the Mac and iOS review clients.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                AccountSettingsSection()
                Section("About") {
                    Text("Transcriber reviews Telephone Booth messages and can "
                         + "draft transcription, translation, and moderation "
                         + "results on-device with Apple Intelligence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
