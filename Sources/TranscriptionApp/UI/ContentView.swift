import SwiftUI

struct ContentView: View {
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
        TabView {
            ReviewView()
                .tabItem { Label("Review", systemImage: "checklist") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
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
