import SwiftUI

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
            }
        }
        #endif
    }
}

#if os(macOS)
/// Adds ⌘1…⌘4 section navigation to the menu bar, driving the focused
/// window's sidebar selection.
struct NavigationCommands: Commands {
    @FocusedBinding(\.selectedNavigationItem) private var selection: NavigationItem?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            ForEach(NavigationItem.allCases) { item in
                Button(item.title) { selection = item }
                    .keyboardShortcut(item.shortcut, modifiers: .command)
                    .disabled(selection == nil)
            }
            Divider()
        }
    }
}
#endif
