import SwiftUI
import TranscriptionAuth

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
                .task {
                    // Silently exchange the stored refresh token for a fresh
                    // access token. Without this, an expired access token
                    // leaves the app looking signed out until an API call
                    // happens to trigger a refresh.
                    await AuthManager.shared.validateSessionOnLaunch()
                }
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { appDelegate.serverHost = host }
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        .commands { NavigationCommands() }
        #endif
        #if os(iOS)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await host.shutdown() }
            } else if newPhase == .active {
                // Retry a session restore that previously failed while the
                // device was offline.
                Task { await AuthManager.shared.validateSessionOnLaunch() }
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(host)
                .frame(minWidth: 480, minHeight: 560)
        }
        #endif
    }
}

#if os(macOS)
/// Adds ⌘1…⌘3 section navigation to the menu bar, driving the focused
/// window's sidebar selection. (Settings is reached the standard Mac way via
/// the app menu / ⌘,, so it is not part of this list.)
struct NavigationCommands: Commands {
    @FocusedBinding(\.selectedNavigationItem) private var selection: NavigationItem?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            ForEach(NavigationItem.macSidebarItems) { item in
                Button(item.title) { selection = item }
                    .keyboardShortcut(item.shortcut, modifiers: .command)
                    .disabled(selection == nil)
            }
            Divider()
        }
    }
}
#endif
