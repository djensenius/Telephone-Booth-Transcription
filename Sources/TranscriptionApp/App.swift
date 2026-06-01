import SwiftUI
import TranscriptionCore

@main
struct TelephoneBoothTranscriptionApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif
    @StateObject private var host = ServerHost()
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some Scene {
        WindowGroup("Telephone Booth Transcription") {
            ContentView()
                .environmentObject(host)
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 520)
                #endif
                .tint(Theme.Colors.accent)
                .foregroundStyle(Theme.Colors.textPrimary)
                .background(ThemedWindowBackground())
                #if os(macOS)
                .onAppear { appDelegate.serverHost = host }
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
        #if os(iOS)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await host.shutdown() }
            }
        }
        #endif
    }
}
