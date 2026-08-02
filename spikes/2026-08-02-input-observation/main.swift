// Spike C — the human half of Task 9, `input-observation`.
//
// Four things about this row cannot be checked without a person at the
// machine, and every one of them is checked HERE and nowhere else:
//
//   1. `CGEvent.tapCreate` succeeding at all. It needs Input Monitoring, and
//      TCC grants that to a signed bundle, not to a `swiftc` output run from a
//      shell — which is why `scripts/cross-boundary-digest-probe.swift` drives
//      `InputObserver.handle(type:event:)` with synthetic events and never
//      touches the tap.
//   2. That a real, tapped `CGEventTimestamp` is on `Minting.hostNow()`'s
//      base. The probe's version of this check uses a stamp this process wrote
//      itself; a constructed `CGEvent` has `timestamp == 0` (measured), so the
//      only source of a genuine one is the window server.
//   3. That the pointer track is dense enough to be a track — the plan's
//      "samples arrive at display rate", which needs a moving mouse.
//   4. That `IsSecureEventInputEnabled()` is ever true. It is true while
//      ANOTHER application's password field has focus, so nothing this process
//      can do makes it true; the probe injects the predicate instead and this
//      step is what checks the real one is wired up.
//
// It records what it sees. It never quotes a window title, an application
// name, or anything typed — `AGENTS.md`: reports quote measurements, never
// captured content. The keyboard step below deliberately prints counts and the
// allow-listed identifier only, and there is nowhere in `InputObserver` for
// anything else to come from.
//
// Identity block, expectation table and positive control come from
// `spikes/shared/VerificationStep.swift` — the harness Tasks 6, 7 and 8 each
// re-derived independently. Read its header before adding a step.

import AppKit
// `IsSecureEventInputEnabled` — HIToolbox, the same import `InputObserver`
// carries. Named here as well because this step asserts on it directly, before
// the observer is started.
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Geometry
import Project
import Timeline

/// Everything the tap delivered, collected off the callback.
///
/// A class with a lock, not a captured `var`: `InputObserver`'s sink is
/// `@Sendable`, which is the same constraint the real callback path lives
/// under.
nonisolated final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InputObserver.Observation] = []
    var all: [InputObserver.Observation] { lock.withLock { storage } }
    func append(_ observation: InputObserver.Observation) { lock.withLock { storage.append(observation) } }

    var pointers: [PointerSample] { all.compactMap { if case .pointer(let s) = $0 { return s } else { return nil } } }
    var buttons: [ButtonEvent] { all.compactMap { if case .button(let e) = $0 { return e } else { return nil } } }
    var keys: [KeySample] { all.compactMap { if case .key(let k) = $0 { return k } else { return nil } } }
    var intervals: [SecureInputInterval] {
        all.compactMap { if case .secureInput(let i) = $0 { return i } else { return nil } }
    }
}

@main
enum SpikeC {

    @MainActor
    static func main() {
        let stepNumber = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 0
        switch stepNumber {
        case 1: pointerTrack()
        case 2: aClick()
        case 3: theKeyboardFilter()
        case 4: secureInput()
        default:
            print("""
            usage: SoredemoSpikeC <step>
              1  pointer track     — move the mouse across the whole screen for 5 s
              2  a click           — click once, anywhere
              3  keyboard filter   — press ⌘C once, then type an ordinary sentence
              4  secure input      — focus a password field, wiggle the mouse, dismiss it

            Run one at a time and record each step's output separately. Step 4
            changes what the system does with keyboard events while it runs.
            """)
            exit(2)
        }
    }

    // MARK: - shared scaffolding

    static let repositoryPath = "~/Documents/Soredemo/soredemo-main"

    /// The arrangement under test, plus the expectation rows derived from it.
    ///
    /// Derived, never typed: `VerificationStep.expect` exists because every
    /// expectation-table error this project has made was a constant written by
    /// the person who knew the implementation, and each one happened to be the
    /// identity element of the transform under test.
    @MainActor
    static func arrangementRows(_ arrangement: DisplayArrangement) -> [(String, String)] {
        var rows: [(String, String)] = [("displays found", "\(arrangement.placements.count)")]
        for (index, placement) in arrangement.placements.enumerated() {
            let geometry = placement.geometry
            let pointWidth = Double(geometry.pixelWidth) / geometry.scale
            let pointHeight = Double(geometry.pixelHeight) / geometry.scale
            rows.append(("display \(index) pixels", "\(geometry.pixelWidth)×\(geometry.pixelHeight)"))
            rows.append(("display \(index) scale", "\(geometry.scale)"))
            rows.append(("display \(index) points", "\(pointWidth)×\(pointHeight)"))
            rows.append(("display \(index) global origin",
                         "(\(placement.globalOriginX), \(placement.globalOriginY))"))
            rows.append(("display \(index) revision", "\(geometry.revision)"))
        }
        rows.append(("every normalised coordinate", "in [0, 1]"))
        rows.append(("event timestamp base", "nanoseconds, same as Minting.hostNow()"))
        return rows
    }

    /// **The positive control: the arrangement, cross-checked against AppKit.**
    ///
    /// Known independently of everything under test. `InputObserver
    /// .currentArrangement()` reads `CGDisplayBounds` and `CGDisplayMode`;
    /// `NSScreen` is a different API over the same window-server state, and
    /// the main screen's frame is in points. If the two disagree, the
    /// arrangement every conversion below is measured against is wrong, and
    /// nothing beneath this line would be about the tap.
    ///
    /// Chosen over "the tap produced some events", which would be a control
    /// whose answer is only known if the thing under test works.
    @MainActor
    static func controlRow(_ step: VerificationStep, _ arrangement: DisplayArrangement) {
        guard let screen = NSScreen.main else {
            step.preconditionFailed("NSScreen.main is nil; there is no independent source to check against")
        }
        let mainID = CGMainDisplayID()
        guard let main = arrangement.placements.first(where: {
            Minting.displayIdentity(of: mainID) == $0.geometry.displayUUID
        }) else {
            step.preconditionFailed("the main display is not in the arrangement under test")
        }
        let observedPoints = "\(Double(main.geometry.pixelWidth) / main.geometry.scale)"
            + "×\(Double(main.geometry.pixelHeight) / main.geometry.scale)"
        step.control("the main display's size in points, from AppKit vs from the arrangement under test",
                     expected: "\(screen.frame.width)×\(screen.frame.height)",
                     observed: observedPoints)
    }

    /// Starts the observer, pumps the main run loop for `seconds`, stops.
    ///
    /// `CFRunLoopRunInMode` on the main thread, because that is the run loop
    /// `InputObserver.start` installs its source on — deliberately
    /// `CFRunLoopGetMain()` rather than `CFRunLoopGetCurrent()`, so a caller
    /// cannot half-work by starting on a thread whose loop later stops.
    @MainActor
    static func observe(for seconds: Double, into collected: Collected,
                        _ step: VerificationStep) -> InputObserver {
        let arrangement = InputObserver.currentArrangement()
        let observer = InputObserver(arrangement: arrangement, epoch: Minting.bootEpoch())
        do {
            try observer.start(onObservation: collected.append)
        } catch CaptureError.inputMonitoringUnavailable {
            step.preconditionFailed("""
            CGEvent.tapCreate returned nil — Input Monitoring is not granted to this bundle \
            (video.soredemo.SpikeC), or it is granted to a previous build with a different \
            signature. System Settings → Privacy & Security → Input Monitoring. \
            CapturePermissions reports: \(CapturePermissions.status(of: .inputMonitoring)). \
            This is NOT 'no events happened'.
            """)
        } catch {
            step.preconditionFailed("InputObserver.start threw \(error)")
        }
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        observer.stop()
        return observer
    }

    @MainActor
    static func countdown(_ seconds: Int, _ instruction: String) {
        print("\n>>> \(instruction)")
        for remaining in stride(from: seconds, to: 0, by: -1) {
            print("    starting in \(remaining)…")
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        print("    GO\n")
    }

    /// Every observation must carry a revision belonging to a display that was
    /// actually attached. A revision from nowhere means the conversion invented
    /// one, which is the failure `GeometryRevision` exists to make impossible.
    @MainActor
    static func revisionsAreKnown(_ collected: Collected, _ arrangement: DisplayArrangement) -> Bool {
        let known = Set(arrangement.placements.map(\.geometry.revision))
        return collected.pointers.allSatisfy { known.contains($0.revision) }
            && collected.buttons.allSatisfy { known.contains($0.revision) }
    }

    // MARK: - step 1: the pointer track

    @MainActor
    static func pointerTrack() {
        var step = VerificationStep(name: "1 — the pointer track, at display rate")
        step.begin(repositoryPath: repositoryPath)
        let arrangement = InputObserver.currentArrangement()
        step.expect(arrangementRows(arrangement) + [
            ("pointer samples in 5 s", "> 300 — the plan's floor is 60 in 1 s"),
            ("suppressed by secure input", "0 — no password field is focused"),
            ("unroutable locations", "0 — the pointer cannot be off every display"),
            ("implausible timestamps", "0 of N — this is the live unit check"),
        ])
        controlRow(step, arrangement)

        let collected = Collected()
        countdown(3, "move the mouse continuously for five seconds, across the WHOLE screen — "
                     + "including into every corner, and onto every attached display.")
        let observer = observe(for: 5, into: collected, step)
        let diagnostics = observer.diagnostics
        let samples = collected.pointers

        guard !samples.isEmpty else {
            step.didNotHappen("no pointer samples arrived — the mouse was not moved, so there is "
                              + "nothing to read. The tap was created, so this is not a permission failure.")
        }

        // The plan's floor is stated per second, so it is measured per second
        // rather than divided out of a five-second total — an average over a
        // window that includes the moment before the mouse started moving is
        // not the quantity the floor is about.
        let firstInstant = samples[0].instant.hostTime.rawValue
        let inFirstSecond = samples.filter { $0.instant.hostTime.rawValue - firstInstant < 1_000_000_000 }.count
        step.check("\(inFirstSecond) pointer samples in the first second of movement "
                   + "(\(samples.count) over the whole 5 s) — the plan's floor is 60 in 1 s",
                   inFirstSecond > 60)
        step.check("every normalised x and y is in [0, 1] — \(samples.count) samples across "
                   + "\(arrangement.placements.count) display(s), so a second display would have "
                   + "failed this if the global point were not routed first",
                   samples.allSatisfy { (0...1).contains($0.position.x) && (0...1).contains($0.position.y) })
        step.check("every sample carries the revision of a display that is actually attached",
                   revisionsAreKnown(collected, arrangement))
        step.check("the track spans more than a single point — min/max x "
                   + String(format: "%.4f/%.4f", samples.map(\.position.x).min()!, samples.map(\.position.x).max()!)
                   + ", y "
                   + String(format: "%.4f/%.4f", samples.map(\.position.y).min()!, samples.map(\.position.y).max()!),
                   (samples.map(\.position.x).max()! - samples.map(\.position.x).min()!) > 0.5)
        step.check("instants are non-decreasing — \(samples.count) samples, taken from the EVENT's "
                   + "own timestamp and not from when the callback ran",
                   zip(samples, samples.dropFirst()).allSatisfy { $0.instant.hostTime <= $1.instant.hostTime })
        step.check("0 implausible timestamps of \(samples.count) — a real tapped CGEventTimestamp is "
                   + "within a second of Minting.hostNow(), i.e. nanoseconds on the same base. "
                   + "Observed: \(diagnostics.implausibleEventTimestampCount)",
                   diagnostics.implausibleEventTimestampCount == 0)
        step.check("0 unroutable locations (observed \(diagnostics.unroutablePointerLocations))",
                   diagnostics.unroutablePointerLocations == 0)
        step.check("0 events suppressed by secure input (observed "
                   + "\(diagnostics.eventsSuppressedBySecureInput))",
                   diagnostics.eventsSuppressedBySecureInput == 0)
        step.finish(remedy: "If the sample count is low but non-zero, the mouse was moved slowly or "
                            + "briefly; re-run before suspecting the code. If it is zero with a created "
                            + "tap, suspect the run-loop source, not the grant.")
    }

    // MARK: - step 2: a click

    @MainActor
    static func aClick() {
        var step = VerificationStep(name: "2 — a click produces a down and an up")
        step.begin(repositoryPath: repositoryPath)
        let arrangement = InputObserver.currentArrangement()
        step.expect(arrangementRows(arrangement) + [
            ("button events", "2 per click — one .down, one .up"),
            ("order", ".down strictly before .up, by instant"),
            ("positions", "both inside [0, 1], and close to each other"),
        ])
        controlRow(step, arrangement)

        let collected = Collected()
        countdown(3, "click ONCE with the left button, on empty desktop — not on a control, "
                     + "so nothing else on the machine changes state.")
        _ = observe(for: 5, into: collected, step)
        let buttons = collected.buttons

        guard !buttons.isEmpty else {
            step.didNotHappen("no button events arrived — nothing was clicked.")
        }
        step.check("\(buttons.count) button events for one click — exactly two",
                   buttons.count == 2)
        step.check("the first is .down and the second is .up (observed "
                   + "\(buttons.map { "\($0.button.rawValue).\($0.phase.rawValue)" }.joined(separator: ", ")))",
                   buttons.first?.phase == .down && buttons.last?.phase == .up)
        step.check("the down is strictly before the up on the host clock",
                   (buttons.first?.instant.hostTime.rawValue ?? 0) < (buttons.last?.instant.hostTime.rawValue ?? 0))
        step.check("both carry a normalised position in [0, 1]",
                   buttons.allSatisfy { (0...1).contains($0.position.x) && (0...1).contains($0.position.y) })
        step.check("both carry the revision of an attached display",
                   revisionsAreKnown(collected, arrangement))
        step.finish(remedy: "More than two button events means the click was a double-click, or the "
                            + "mouse was clicked twice. Re-run.")
    }

    // MARK: - step 3: the keyboard filter

    @MainActor
    static func theKeyboardFilter() {
        var step = VerificationStep(name: "3 — keyboard is filtered to approved shortcuts")
        step.begin(repositoryPath: repositoryPath)
        let arrangement = InputObserver.currentArrangement()
        step.expect(arrangementRows(arrangement) + [
            ("allow-list size", "\(InputObserver.approvedShortcuts.count) entries"),
            ("KeySamples expected", "exactly 1, with shortcut \"cmd+c\""),
            ("KeySamples for the typing", "0 — every ordinary key is refused"),
            ("keyDown accounting", "seen == recorded + refused, with no tolerance"),
        ])
        controlRow(step, arrangement)

        let collected = Collected()
        countdown(5, """
        do these two things, in this order, inside a plain text editor:
              (a) press ⌘C exactly once;
              (b) type an ordinary sentence — at least twenty characters, \
        including capitals, so the shift-held path is exercised too.
            Do NOT type anything you would not want in a report. Nothing typed \
        can reach this process's output — that is what is being checked — but \
        do not make the check the only thing standing between you and a mistake.
        """)
        let observer = observe(for: 12, into: collected, step)
        let diagnostics = observer.diagnostics

        guard diagnostics.keyDownsSeen > 0 else {
            step.didNotHappen("no keyDown events arrived — nothing was typed.")
        }
        guard diagnostics.keyDownsSeen >= 20 else {
            step.preconditionFailed("only \(diagnostics.keyDownsSeen) keyDown events — fewer than the "
                                    + "twenty asked for. 'Nothing was recorded' is nearly true of an "
                                    + "empty input as well, so this cannot be read.")
        }

        step.check("\(diagnostics.keyDownsSeen) keyDown events were seen — the filter was given "
                   + "real input, so a zero result below is not vacuous",
                   diagnostics.keyDownsSeen >= 20)
        step.check("exactly 1 KeySample from \(diagnostics.keyDownsSeen) keystrokes (observed "
                   + "\(collected.keys.count))",
                   collected.keys.count == 1)
        step.check("the one recorded identifier is \"cmd+c\" — a name from the table in "
                   + "InputObserver.swift, not a rendering of anything pressed (observed "
                   + "\(collected.keys.map(\.shortcut)))",
                   collected.keys.map(\.shortcut) == ["cmd+c"])
        step.check("keyDown accounting balances: \(diagnostics.keyAccounting)",
                   diagnostics.everyKeyDownIsAccountedFor)
        step.check("\(diagnostics.keyDownsRefused) keystrokes were refused and left no trace of any "
                   + "kind — the count is a number, and there is no field anywhere holding what they were",
                   diagnostics.keyDownsRefused == diagnostics.keyDownsSeen - 1)
        step.finish(remedy: "If more than one KeySample appeared, the typing contained another "
                            + "allow-listed chord — check InputObserver.approvedShortcuts against what "
                            + "was pressed before suspecting the filter.")
    }

    // MARK: - step 4: secure input

    @MainActor
    static func secureInput() {
        var step = VerificationStep(name: "4 — secure input produces an interval, not silence")
        step.begin(repositoryPath: repositoryPath)
        let arrangement = InputObserver.currentArrangement()
        step.expect(arrangementRows(arrangement) + [
            ("IsSecureEventInputEnabled now", "\(IsSecureEventInputEnabled()) — must be false before the step"),
            ("observations while it is true", "0 — nothing at all, not a redacted sample"),
            ("SecureInputInterval records", "exactly 1, endedBy .secureInputDisabled"),
            ("interval width", "> 0 — it spans the seconds the field had focus"),
        ])
        controlRow(step, arrangement)

        guard !IsSecureEventInputEnabled() else {
            step.preconditionFailed("secure input is ALREADY enabled before the step starts — some "
                                    + "other window holds a password field. Dismiss it; otherwise the "
                                    + "interval's start is not the moment being measured.")
        }

        let collected = Collected()
        countdown(5, """
        do these three things, in this order:
              (a) move the mouse for two seconds — ordinary samples;
              (b) focus a password field (a `sudo` prompt in Terminal, or the \
        unlock sheet in System Settings) and keep moving the mouse for four seconds;
              (c) dismiss it WITHOUT typing a password, and keep moving the mouse \
        for two more seconds.
            Do not type into the field. The interval is about focus, not about typing.
        """)
        let observer = observe(for: 14, into: collected, step)
        let diagnostics = observer.diagnostics

        guard diagnostics.eventsSuppressedBySecureInput > 0 else {
            step.didNotHappen("""
            no event was ever observed while secure input was enabled. Either the password field \
            never took focus, or the mouse was not moving while it did — with no event arriving, \
            this observer has nothing to ask the question on. It is not a failure of the code and \
            must not be recorded as one; it is also a real, known limitation, and the report says so.
            """)
        }

        let intervals = collected.intervals
        step.check("\(diagnostics.eventsSuppressedBySecureInput) events arrived while secure input "
                   + "was enabled, and NONE of them produced an observation of any kind",
                   diagnostics.eventsSuppressedBySecureInput > 0)
        step.check("exactly 1 SecureInputInterval record (observed \(intervals.count))",
                   intervals.count == 1)
        step.check("it is marked .secureInputDisabled — a measured interval, not the "
                   + ".observationStopped lower bound (observed \(intervals.map { $0.endedBy.rawValue }))",
                   intervals.first?.endedBy == .secureInputDisabled)
        step.check("the interval has positive width: "
                   + String(format: "%.3f s", Double(intervals.first?.interval.duration.rawValue ?? 0) / 1e9),
                   (intervals.first?.interval.duration.rawValue ?? 0) > 0)
        step.check("pointer samples exist on BOTH sides of the interval — the gap is bounded by "
                   + "real motion, so it is a gap and not the end of the recording",
                   collected.pointers.contains { $0.instant.hostTime < (intervals.first?.interval.start ?? Nanoseconds(0)) }
                   && collected.pointers.contains { $0.instant.hostTime >= (intervals.first?.interval.end ?? Nanoseconds(0)) })
        step.check("no pointer sample falls inside the interval — \(collected.pointers.count) samples "
                   + "checked",
                   !collected.pointers.contains { sample in
                       guard let interval = intervals.first?.interval else { return false }
                       return interval.contains(sample.instant)
                   })
        step.finish(remedy: "If the interval is missing but events were suppressed, the close path "
                            + "did not run — check that the mouse was still moving after the field was "
                            + "dismissed, since the interval closes on the first event observed with "
                            + "secure input off.")
    }
}
