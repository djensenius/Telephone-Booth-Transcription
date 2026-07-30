import Foundation
#if os(macOS)
import TranscriptionCore
#endif

/// Detects the screenshot/demo launch configuration. Demo mode swaps the live
/// server for deterministic, login-free sample data so the App Store screenshot
/// tooling (and SwiftUI previews) can render a populated UI with no upstreams,
/// no Keychain access, and no network.
///
/// Activated by the `-uiTestDemoMode` launch argument or `TBT_DEMO_MODE=1` in
/// the environment. The initial tab can be pinned with `-uiScreenshotTab
/// <status|settings|requests>` (or `TBT_SCREENSHOT_TAB`).
enum DemoMode {
    static var isActive: Bool {
        // Only available in Debug builds (App Store screenshots are captured
        // from a Debug build). Release/App Store binaries never expose the hook.
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uiTestDemoMode")
            || ProcessInfo.processInfo.environment["TBT_DEMO_MODE"] == "1"
            // Xcode previews have no server, no Keychain token and no Operator,
            // so without this every preview renders the sign-in screen.
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        #else
        return false
        #endif
    }

    static var screenshotTab: String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-uiScreenshotTab"), index + 1 < args.count {
            return args[index + 1]
        }
        return ProcessInfo.processInfo.environment["TBT_SCREENSHOT_TAB"]
    }
}

/// Deterministic sample content used by demo mode and SwiftUI previews. None of
/// this represents real traffic; it exists purely to make the UI legible in
/// screenshots and previews.
#if os(macOS)
enum DemoData {
    /// A stable, obviously-fake bearer token shown on the Status tab.
    static let token = "tbt_demo_3f9c0a7b14d24e6f8a1b5c9d0e2f4a6b"

    static let bindHost = "127.0.0.1"
    static let bindPort = 8089

    /// A configuration that showcases the privacy-first, on-device defaults the
    /// App Store listing describes.
    static var config: ServerConfig {
        var config = ServerConfig()
        config.bindHost = bindHost
        config.bindPort = bindPort
        config.transcriptionBackend = .appleSpeechAnalyzer
        config.moderationBackend = .onDevice
        config.textTranslationBackend = .onDevice
        return config
    }

    /// A spread of recent requests across every endpoint, including a flagged
    /// moderation result, an unauthorized attempt, and an on-device-unavailable
    /// error, so the Requests table looks realistic.
    static var requestLog: [RequestLogEntry] {
        let now = Date()
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

        return [
            RequestLogEntry(
                receivedAt: ago(8),
                method: "POST",
                path: "/v1/audio/transcriptions",
                status: 200,
                durationMs: 412,
                clientIP: "127.0.0.1",
                model: "apple-speech-analyzer",
                requestBytes: 184_320,
                responseBytes: 612,
                authOK: true
            ),
            RequestLogEntry(
                receivedAt: ago(21),
                method: "POST",
                path: "/v1/moderations",
                status: 200,
                durationMs: 38,
                clientIP: "127.0.0.1",
                model: "apple-foundation-models",
                requestBytes: 142,
                responseBytes: 196,
                authOK: true,
                moderationFlagged: false
            ),
            RequestLogEntry(
                receivedAt: ago(54),
                method: "POST",
                path: "/v1/translations",
                status: 200,
                durationMs: 156,
                clientIP: "127.0.0.1",
                model: "apple-foundation-models",
                requestBytes: 311,
                responseBytes: 288,
                authOK: true
            ),
            RequestLogEntry(
                receivedAt: ago(72),
                method: "POST",
                path: "/v1/moderations",
                status: 200,
                durationMs: 44,
                clientIP: "127.0.0.1",
                model: "apple-foundation-models",
                requestBytes: 173,
                responseBytes: 201,
                authOK: true,
                moderationFlagged: true
            ),
            RequestLogEntry(
                receivedAt: ago(96),
                method: "POST",
                path: "/v1/audio/translations",
                status: 200,
                durationMs: 938,
                clientIP: "127.0.0.1",
                model: "whisper-1",
                requestBytes: 240_128,
                responseBytes: 524,
                authOK: true
            ),
            RequestLogEntry(
                receivedAt: ago(140),
                method: "POST",
                path: "/v1/audio/transcriptions",
                status: 401,
                durationMs: 2,
                clientIP: "192.168.1.42",
                model: nil,
                requestBytes: 0,
                responseBytes: 96,
                authOK: false
            ),
            RequestLogEntry(
                receivedAt: ago(205),
                method: "POST",
                path: "/v1/translations",
                status: 503,
                durationMs: 6,
                clientIP: "127.0.0.1",
                model: "apple-foundation-models",
                requestBytes: 268,
                responseBytes: 142,
                authOK: true,
                error: "on_device_unavailable"
            ),
            RequestLogEntry(
                receivedAt: ago(264),
                method: "GET",
                path: "/healthz",
                status: 200,
                durationMs: 1,
                clientIP: "127.0.0.1",
                model: nil,
                requestBytes: 0,
                responseBytes: 27,
                authOK: true
            ),
        ]
    }
}

#endif
