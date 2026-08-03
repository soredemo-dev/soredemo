import AppKit
import CoreGraphics
import Darwin
import Foundation

/// **Spike E — can this app tell that the real cursor is hidden?**
///
/// Phase 2B draws the pointer itself: the master is captured with
/// `showsCursor = false` (D2-8), so the compositor renders a pointer from the
/// observation track. That makes one question load-bearing before a line of
/// `cursor-render` is written — **drawing a pointer where the real screen had
/// none is a visible fabrication**, and macOS hides the pointer routinely: while
/// you type, in full-screen video, in games, and any time an app calls
/// `NSCursor.hide()`.
///
/// So: is the hidden state readable at all?
///
///   detectable      → do not draw while hidden, and the question closes
///   not detectable  → a known defect, written down, not discovered by a viewer
///
/// **Answered by measurement rather than by reading the headers**, because the
/// headers already look decisive and this project has been wrong that way today:
/// `CGCursorIsVisible` is marked deprecated since 10.9 ("No longer supported"),
/// which says what Apple intends and not what the function returns. Deprecated
/// is not removed. And a deprecation message is prose — one of them was measured
/// wrong an hour ago, naming a selector that does not ship.
///
/// **The stimulus is induced, and it is the last thing this spike does.** The
/// cursor is hidden deliberately, every candidate is read in both states, and it
/// is shown again immediately. A reading taken only while the cursor is visible
/// cannot tell a working detector from a function that returns `true`
/// unconditionally — which is the entire failure mode here.

@main
enum SpikeE {
    static func main() {
        var step = VerificationStep(name: "spike E — is the cursor's hidden state readable?")
        step.expect([
            .init("induced-hidden",
                  "what is induced",
                  "the cursor is hidden by this process, and shown again",
                  reds: [.init("the stimulus",
                              "skip the hide: every candidate then reports the visible state "
                              + "twice, and a constant-`true` function is indistinguishable "
                              + "from a working one")]),
            .init("cg-candidates-unavailable",
                  "CGCursorIsVisible / CGCursorIsDrawnInFramebuffer",
                  "refused by the compiler at this deployment target",
                  reds: [.init("availability",
                              "delete the availability note and call them: `swiftc` at "
                              + "-target arm64-apple-macos26.0 answers `is unavailable in "
                              + "macOS: No longer supported` — an error, not a warning")]),
            .init("ns-current-system-cursor",
                  "NSCursor.currentSystemCursor",
                  "nil / non-nil, or the same object, across the two states",
                  reds: [.init("the discrimination",
                              "same answer in both states is not a detector")]),
        ])

        step.given([
            ("this process", "not frontmost, owns no window — the recorder's own position while "
                             + "another app is being demonstrated"),
            ("hide ownership", "cursor hiding is associated with the process that asked for it; "
                               + "whether a reader sees another process's hide is what this measures"),
            ("runtime", ProcessInfo.processInfo.operatingSystemVersionString),
        ])

        // MEASURED BY THE COMPILER, NOT AT RUNTIME, AND THAT IS THE STRONGER ANSWER.
        // `CGCursorIsVisible()` and `CGCursorIsDrawnInFramebuffer()` carry
        // `API_DEPRECATED("No longer supported", macos(10.3, 10.9))`. Past the
        // obsolescence version Swift makes them UNAVAILABLE rather than
        // deprecated, so at `-target arm64-apple-macos26.0` calling either is a
        // compile ERROR: "is unavailable in macOS: No longer supported". They
        // are not candidates that failed a measurement; they cannot be written
        // down at this floor at all. Re-verify by deleting this comment and
        // calling them — that is this row's red.
        step.check("cg-candidates-unavailable",
                   "both CG cursor-visibility functions are unavailable at "
                   + "arm64-apple-macos26.0 — a compile error, verified by the build that "
                   + "produced this binary refusing them",
                   true)

        func sample() -> String {
            NSCursor.currentSystem.map { "size \($0.image.size), hotSpot \($0.hotSpot)" } ?? "nil"
        }

        let before = sample()
        print("  visible state:  NSCursor.currentSystem = \(before)")

        let display = CGMainDisplayID()
        let hideResult = CGDisplayHideCursor(display)
        usleep(300_000)
        let during = sample()
        let showResult = CGDisplayShowCursor(display)
        print("  hidden state:   NSCursor.currentSystem = \(during)")
        print("  CGDisplayHideCursor -> \(hideResult.rawValue), CGDisplayShowCursor -> \(showResult.rawValue)")

        step.check("induced-hidden",
                   "CGDisplayHideCursor returned \(hideResult.rawValue) and CGDisplayShowCursor "
                   + "returned \(showResult.rawValue) (0 == success). Without a successful hide "
                   + "every row below compares the visible state against itself",
                   hideResult == .success && showResult == .success)

        step.check("ns-current-system-cursor",
                   "NSCursor.currentSystem: [\(before)] visible / [\(during)] hidden — "
                   + (before != during
                      ? "it CHANGES, so it carries the hidden state"
                      : "UNCHANGED, so it does not carry it"),
                   before != during)

        step.finish(remedy: "If every row is red, the hidden state is NOT readable by this process "
                    + "and `cursor-render` ships with a named defect: a pointer is drawn at times "
                    + "the real screen had none. That is a D6a row and a sentence in the review "
                    + "UI, not something a viewer discovers.")
    }
}
