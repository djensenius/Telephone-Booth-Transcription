import AppKit
import SwiftUI

/// Handles macOS app termination by performing awaited server shutdown before
/// allowing the process to exit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app on launch so the delegate can trigger graceful shutdown.
    weak var serverHost: ServerHost?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host = serverHost,
              host.state.isRunning || host.state == .starting else {
            return .terminateNow
        }
        Task { @MainActor in
            await host.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
