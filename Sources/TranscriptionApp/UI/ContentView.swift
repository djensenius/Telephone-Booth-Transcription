import SwiftUI

struct ContentView: View {
    #if os(iOS)
    @State private var selectedTab = DemoMode.screenshotTab?.lowercased() == "settings"
        ? "settings"
        : "review"
    #endif

    var body: some View {
        #if os(macOS)
        Group {
            if DemoMode.screenshotTab?.lowercased() == "settings" {
                SettingsView()
            } else {
                ReviewView()
            }
        }
            .tint(Theme.Colors.accent)
            .foregroundStyle(Theme.Colors.textPrimary)
            .background(ThemedWindowBackground())
        #else
        TabView(selection: $selectedTab) {
            ReviewView()
                .tabItem { Label("Review", systemImage: "checklist") }
                .tag("review")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .tint(Theme.Colors.accent)
        .foregroundStyle(Theme.Colors.textPrimary)
        .background(ThemedWindowBackground())
        #endif
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 620)
}
