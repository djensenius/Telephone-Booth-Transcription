import SwiftUI
import TranscriptionCore

@main
struct TelephoneBoothTranscriptionApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var host = ServerHost()

    var body: some Scene {
        WindowGroup("Telephone Booth Transcription") {
            ContentView()
                .environmentObject(host)
                .frame(minWidth: 760, minHeight: 520)
                .tint(Theme.Colors.accent)
                .foregroundStyle(Theme.Colors.textPrimary)
                .background(ThemedWindowBackground())
                .onAppear { appDelegate.serverHost = host }
        }
        .windowResizability(.contentSize)
    }
}
