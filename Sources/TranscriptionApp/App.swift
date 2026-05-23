import SwiftUI
import TranscriptionCore

@main
struct TelephoneBoothTranscriptionApp: App {
    @StateObject private var host = ServerHost()

    var body: some Scene {
        WindowGroup("Telephone Booth Transcription") {
            ContentView()
                .environmentObject(host)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentSize)
    }
}
