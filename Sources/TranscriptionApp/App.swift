import SwiftUI
import TranscriptionCore

@main
struct TelephoneBoothTranscriptionApp: App {
    @StateObject private var host = ServerHost()

    var body: some Scene {
        WindowGroup("Telephone Booth Transcription") {
            ContentView()
                .environmentObject(host)
                .frame(minWidth: 760, minHeight: 520)
                .tint(Theme.Colors.accent)
                .foregroundStyle(Theme.Colors.textPrimary)
                .background(ThemedWindowBackground())
        }
        .windowResizability(.contentSize)
    }
}
