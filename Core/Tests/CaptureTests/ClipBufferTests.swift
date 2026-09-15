import Foundation
import Testing
@testable import Capture

/// The rolling clip buffer's refusals, decided without a stream.
///
/// **What can be tested here and what cannot, stated rather than blurred.** Attaching to a live
/// `SCStream` and exporting from it needs a real display and a real capture, which is the
/// probe's tier. What is checkable at this level is the part that decides: whether a request is
/// answerable at all, and whether a refusal says something a person can act on.
/// **`@available` per test rather than on a suite**: `@Suite` cannot be applied to a type that
/// is version-gated, and gating each test is what lets the package keep its macOS 26 floor.
enum ClipBufferTests {}

/// **The ceiling is the system's, not this project's**, and a caller asking for more is
/// told the number rather than silently given less. A clip quietly shortened is a clip that
/// starts after the thing somebody wanted.
@available(macOS 27.0, *)
@Test func askingForLongerThanTheBufferIsRefusedWithTheCeiling() async {
    let buffer = ClipBuffer()
    let outcome = await buffer.save(lastSeconds: 60,
                                    to: URL(fileURLWithPath: "/dev/null"))
    #expect(outcome == .refused(.longerThanTheBuffer(
        ceilingSeconds: ClipBuffer.ceilingSeconds)))
}

/// **Never attached is not the same as attached and empty**, and this is the one a person
/// meets by pressing the button before a recording starts.
@available(macOS 27.0, *)
@Test func savingWithNothingBufferedSaysSo() async {
    let buffer = ClipBuffer()
    let outcome = await buffer.save(lastSeconds: 5, to: URL(fileURLWithPath: "/dev/null"))
    #expect(outcome == .refused(.nothingHasBeenBuffered))
}

/// A fresh buffer has nothing in it, and says so rather than claiming readiness.
@available(macOS 27.0, *)
@Test func aFreshBufferIsNotBuffering() {
    #expect(!ClipBuffer().isBuffering)
}

/// The ceiling is the value the system documents, written once so the interface and the
/// refusal cannot disagree about it.
@available(macOS 27.0, *)
@Test func theCeilingIsFifteenSeconds() {
    #expect(ClipBuffer.ceilingSeconds == 15)
}

/// **A refusal carries what the system said.** The alternative — a bare case — turns "the
/// disk is full" and "the codec refused" into the same sentence, which is the shape this
/// project keeps finding and naming.
@available(macOS 27.0, *)
@Test func aSystemFailureCarriesItsReason() {
    let refusal = ClipBuffer.Refusal.theSystemCouldNotWriteIt("no space left on device")
    #expect(String(describing: refusal).contains("no space left"))
}

/// **Every public type in `Capture` is named by a `CaptureTests` test** — a scan enforces it, so
/// that a type can never be added to the package's surface without something having asked a
/// question about it. `ClipReadiness` and `ClipOutcome` are `CaptureSession`'s answers about the
/// buffer, and both distinguish three situations that a boolean would flatten.
@available(macOS 27.0, *)
@Test func theReadinessCasesAreDistinct() {
    let none = CaptureSession.ClipReadiness.thisSystemHasNoClipBuffer
    let failed = CaptureSession.ClipReadiness.itCouldNotStart("no space")
    let ready = CaptureSession.ClipReadiness.ready(ceilingSeconds: 15)
    #expect(none != failed)
    #expect(failed != ready)
    // The reason travels: "it could not start" with no reason is not something to act on.
    #expect(String(describing: failed).contains("no space"))
}

@available(macOS 27.0, *)
@Test func aClipOutcomeCarriesEitherTheFileOrTheReason() {
    let wrote = CaptureSession.ClipOutcome.wrote(URL(fileURLWithPath: "/tmp/clip.mov"))
    let refused = CaptureSession.ClipOutcome.refused("the disk is full")
    #expect(wrote != refused)
    #expect(String(describing: refused).contains("disk is full"))
}
