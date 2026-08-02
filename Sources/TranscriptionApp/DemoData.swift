import Foundation

/// Detects the screenshot/demo launch configuration. Demo mode supplies
/// deterministic, login-free review data so App Store screenshots and SwiftUI
/// previews can render without an Operator session.
///
/// Activated by the `-uiTestDemoMode` launch argument or `TBT_DEMO_MODE=1` in
/// the environment. The initial tab can be pinned with `-uiScreenshotTab
/// <review|settings>` (or `TBT_SCREENSHOT_TAB`).
enum DemoMode {
    static var isActive: Bool {
        // Only available in Debug builds (App Store screenshots are captured
        // from a Debug build). Release/App Store binaries never expose the hook.
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uiTestDemoMode")
            || ProcessInfo.processInfo.environment["TBT_DEMO_MODE"] == "1"
            // Xcode previews have no Operator session, so without this every
            // preview renders the sign-in screen.
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
