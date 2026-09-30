import Testing
import Foundation
import IOKit.pwr_mgt
@testable import Soredemo

/// **Asked of the power manager, not of the lock.** A lock that says it is held while the system
/// holds nothing is the failure this exists to catch, so the answer comes from
/// `IOPMCopyAssertionsByProcess` for this process. `docs/design/2026-09-30-before-and-during-a-take.md`.
@MainActor @Suite(.serialized) struct TakeWakeLockTests {
    private func assertionsHeldByThisProcess() throws -> [String] {
        var out: Unmanaged<CFDictionary>?
        try #require(IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
                     "the power manager did not answer — nothing below would mean anything")
        let byProcess = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
        return (byProcess[NSNumber(value: getpid())] ?? []).compactMap { $0["AssertType"] as? String }
    }

    @Test func holdingKeepsTheDisplayAwakeAndReleasingLetsItSleep() throws {
        let lock = TakeWakeLock()
        // Positive control: this process holds no display assertion to begin with, so the one
        // below is the lock's and not something else's.
        #expect(!(try assertionsHeldByThisProcess()).contains("PreventUserIdleDisplaySleep"))
        lock.hold()
        #expect((try assertionsHeldByThisProcess()).contains("PreventUserIdleDisplaySleep"))
        lock.release()
        #expect(!(try assertionsHeldByThisProcess()).contains("PreventUserIdleDisplaySleep"))
    }

    /// Held once however often it is asked, so one release is always enough — a take that starts
    /// twice must not leave the display on for good.
    @Test func holdingTwiceNeedsOneRelease() throws {
        let lock = TakeWakeLock()
        lock.hold()
        lock.hold()
        lock.release()
        #expect(!(try assertionsHeldByThisProcess()).contains("PreventUserIdleDisplaySleep"))
        lock.release()
    }
}
