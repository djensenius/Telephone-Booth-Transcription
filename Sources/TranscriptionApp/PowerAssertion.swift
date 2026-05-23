import Foundation
import IOKit
import IOKit.pwr_mgt

/// Holds an `IOPMAssertionCreateWithName` assertion to keep the Mac awake
/// while the transcription server is running.
///
/// Lifecycle: `acquire()` / `release()` are idempotent. The struct is
/// thread-safe via an internal lock. On deinit the assertion is released.
public final class PowerAssertion: @unchecked Sendable {
    public enum AssertionKind {
        /// Prevent system idle sleep but allow display sleep. Suitable for a
        /// background HTTP server.
        case preventIdleSystemSleep
        /// Prevent display sleep too. Probably overkill for our case.
        case preventDisplaySleep
    }

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var held = false

    public let reason: String
    public let kind: AssertionKind

    public init(reason: String = "Telephone Booth Transcription server running",
                kind: AssertionKind = .preventIdleSystemSleep) {
        self.reason = reason
        self.kind = kind
    }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    @discardableResult
    public func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if held { return true }
        let typeKey: CFString
        switch kind {
        case .preventIdleSystemSleep:
            typeKey = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        case .preventDisplaySleep:
            typeKey = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        }
        let result = IOPMAssertionCreateWithName(
            typeKey,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            held = true
            return true
        }
        return false
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
        assertionID = IOPMAssertionID(0)
    }

    deinit {
        if held {
            IOPMAssertionRelease(assertionID)
        }
    }
}
