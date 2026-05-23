import SwiftUI
import TranscriptionCore

struct ContentView: View {
    @EnvironmentObject var host: ServerHost

    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Status", systemImage: "phone.connection.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
            RequestLogView()
                .tabItem { Label("Requests", systemImage: "list.bullet.rectangle") }
        }
        .padding()
    }
}
