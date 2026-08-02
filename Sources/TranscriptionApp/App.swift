import SwiftUI
import TranscriptionAuth

@main
struct TelephoneBoothTranscriptionApp: App {
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some Scene {
        WindowGroup("Telephone Booth Transcription") {
            ContentView()
                .task {
                    // Silently exchange the stored refresh token for a fresh
                    // access token. Without this, an expired access token
                    // leaves the app looking signed out until an API call
                    // happens to trigger a refresh.
                    await AuthManager.shared.validateSessionOnLaunch()
                }
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
        #if os(iOS)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await AuthManager.shared.validateSessionOnLaunch() }
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .frame(minWidth: 480, minHeight: 560)
        }
        #endif
    }
}
