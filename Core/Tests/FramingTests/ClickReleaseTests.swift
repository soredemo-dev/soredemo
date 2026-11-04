import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// Which `up` lets a click go — the one pairing both readers of a log use, so the zoom that plays
// and the zoom the review lists cannot disagree. See
// `docs/design/2026-11-04-a-read-is-stale-only-after-the-release.md`.

private let epoch = BootEpoch(id: UUID(uuidString: "C0FFEE00-2222-4222-8333-444455556666")!)
private let otherBoot = BootEpoch(id: UUID(uuidString: "C0FFEE00-3333-4222-8333-444455556666")!)
private let revision = GeometryRevision(id: 7)

private func at(_ ns: Int64, _ boot: BootEpoch = epoch) -> HostInstant {
    HostInstant(epoch: boot, hostTime: Nanoseconds(ns))
}

private func event(_ ns: Int64, _ phase: ButtonPhase, _ button: PointerButton = .left,
                   _ boot: BootEpoch = epoch) -> ButtonEvent {
    ButtonEvent(instant: at(ns, boot), position: NormalizedPoint(x: 0.3, y: 0.6), revision: revision,
                button: button, phase: phase)
}

/// The chain of a click that went down at `ns` — only its instant matters to the pairing.
private func click(at ns: Int64) -> AXChainRecord {
    AXChainRecord(instant: at(ns), clickPosition: NormalizedPoint(x: 0.3, y: 0.6),
                  clickRevision: revision, hitTestGlobalX: 300, hitTestGlobalY: 500,
                  hitTestInterval: HostRange(epoch: epoch, start: Nanoseconds(ns + 400_000),
                                             duration: Nanoseconds(1_000_000)),
                  hit: nil, ancestors: [], children: [], truncation: .hitTestReturnedNothing,
                  axCalls: 1, depthCap: 12, walkBudgetNanos: 8_000_000)
}

/// The first `up` of the same button after the `down` — not an earlier click's, not the next
/// click's, and not another button's that happened to come first.
@Test func theReleaseIsTheFirstUpOfTheSameButtonAfterTheDown() {
    let events = [event(1_000_000, .down), event(90_000_000, .up),            // an earlier click
                  event(500_000_000, .down),
                  event(520_000_000, .up, .right),                              // another button
                  event(583_000_000, .up),                                      // ← this click's
                  event(900_000_000, .down), event(990_000_000, .up)]           // the next click
    #expect(ClickRelease.instant(for: click(at: 500_000_000), in: events) == at(583_000_000))
}

/// The pairing goes by the button the chain's own `down` used, so a right click is let go by a
/// right `up` even when a left one comes first.
@Test func aRightClickIsLetGoByTheRightButton() {
    let events = [event(500_000_000, .down, .right), event(510_000_000, .up, .left),
                  event(600_000_000, .up, .right)]
    #expect(ClickRelease.instant(for: click(at: 500_000_000), in: events) == at(600_000_000))
}

/// No `up` after the `down` — the take ended with the button held — is no release, not the
/// previous click's.
@Test func aClickNeverLetGoHasNoRelease() {
    let events = [event(1_000_000, .down), event(90_000_000, .up), event(500_000_000, .down)]
    #expect(ClickRelease.instant(for: click(at: 500_000_000), in: events) == nil)
}

/// A chain whose own `down` is not in the events cannot say which button to wait for.
@Test func aChainWithNoMatchingDownHasNoRelease() {
    let events = [event(400_000_000, .down), event(480_000_000, .up)]
    #expect(ClickRelease.instant(for: click(at: 500_000_000), in: events) == nil)
}

/// An `up` from another boot is on another clock: its host time says nothing about this one.
@Test func anUpFromAnotherBootIsNotThisClicksRelease() {
    let events = [event(500_000_000, .down), event(580_000_000, .up, .left, otherBoot)]
    #expect(ClickRelease.instant(for: click(at: 500_000_000), in: events) == nil)
}
