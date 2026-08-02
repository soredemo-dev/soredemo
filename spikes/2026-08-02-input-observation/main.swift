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


// ------------------------------------------------- Step 5: the timeout threshold

/// Where a `.listenOnly` tap's callback budget actually is, in milliseconds.
///
/// **Why this is a spike and not a production observation.** `AXObserver.chain`
/// runs inside `InputObserver`'s tap callback, and Spike A measured the worst
/// hit-test at **125.47 ms**, with 14 of 118 exceeding one 60 fps frame. If the
/// system's callback budget is below that, the OS disables the tap
/// (`kCGEventTapDisabledByTimeout`) and every event until it is re-armed is
/// gone. The shipped design defers that question to "observe it in the field" —
/// and the field is the middle of a real recording, where what is lost is real
/// evidence.
///
/// **The header does not settle it.** `CGEvent.h:322` says only "If a tap
/// becomes unresponsive or a user requests taps be disabled, an appropriate
/// `kCGEventTapDisabled...` event is passed to the registered callback", with
/// no exemption for `.listenOnly`, and `kCGEventTapOptionListenOnly` is
/// documented only as "a passive listener". Checked before writing this: it is
/// neither confirmed nor excluded, so it is a measurement.
///
/// **The threshold decides the design, and the three outcomes are not close.**
///
///     ~1 s      the concern disappears quantitatively; AX stays in the callback
///     ~200 ms   the 12% tail clips it occasionally; "observe it" is defensible
///     ~100 ms   it must move off the callback thread NOW, not later
///
/// It also measures the second thing the count cannot: **how long the tap stays
/// disabled**. If the disable-to-re-arm interval is milliseconds, recording it
/// as an interval is enough. If it is hundreds of milliseconds, the events lost
/// inside it are numerous enough that a segment spanning one may have to be
/// refused outright rather than annotated — and that too is decided by a
/// number, not by judgement.
///
/// Costs nothing to be wrong about: no permission beyond the pointer tap this
/// spike already has, a throwaway process, and the worst failure is this
/// spike's own tap being disabled.
nonisolated(unsafe) var stallMilliseconds = 0
nonisolated(unsafe) var tapOptionUnderTest: CGEventTapOptions = .listenOnly
/// When true, `stallingTapCallback` stalls only on `.leftMouseDown`.
///
/// **Step 5's sweep stalls on every `mouseMoved`, and that is the wrong
/// distribution.** Pointer motion arrives at 60–120 Hz — one event every 8–16
/// ms — so stalling 20 ms on each of them cannot keep up by construction: the
/// queue grows without bound and the system disables a tap that is
/// persistently overloaded. That is a different mechanism from "one callback
/// took too long", and step 5 measured the first while its conclusion was
/// written about the second.
///
/// Real AX work happens on **clicks**, one to three seconds apart. Spike A's
/// worst hit-test of 125.47 ms at one click every two seconds is a 6% duty
/// cycle. Whether that survives is the question this task's design actually
/// turns on, and step 5 never asked it.
nonisolated(unsafe) var stallOnlyOnClicks = false
nonisolated(unsafe) var timeoutDisableInstants: [(disabled: Int64, reArmed: Int64)] = []
nonisolated(unsafe) var pendingDisableAt: Int64?
nonisolated(unsafe) var callbacksSeen = 0
/// Stalls actually performed — NOT callbacks seen.
///
/// Part A's guard used to be `callbacks > 0`, and `callbacksSeen` counts every
/// callback including `mouseMoved`, which the mask includes. So a run where the
/// operator moved the mouse and clicked ZERO times performed zero stalls,
/// recorded ~1900 callbacks, and passed with the message "a 125 ms stall on
/// CLICKS ONLY left the tap ENABLED". The number that came out of that run is
/// now quoted as a design fact in five files. An anti-vacuity guard that reads
/// a proxy for its subject is the ninth instance of that shape in this project
/// and the first one inside a guard written to prevent it.
nonisolated(unsafe) var stallsPerformed = 0
nonisolated(unsafe) var unexpectedCallbackTypes: [UInt32] = []
nonisolated(unsafe) var activeTap: CFMachPort?

/// The tap callback under test. Stalls for `stallMilliseconds`, exactly as an
/// AX hit-test inside `InputObserver`'s callback would.
nonisolated func stallingTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                      _ event: CGEvent,
                                      _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout {
        pendingDisableAt = Minting.hostNow().rawValue
        if let tap = activeTap { CGEvent.tapEnable(tap: tap, enable: true) }
        // The re-arm instant is taken immediately AFTER tapEnable returns, so
        // the recorded interval is the window this process could not observe,
        // not the time it took to notice.
        if let disabled = pendingDisableAt {
            timeoutDisableInstants.append((disabled: disabled, reArmed: Minting.hostNow().rawValue))
            pendingDisableAt = nil
        }
        return nil
    }
    if type == .tapDisabledByUserInput {
        unexpectedCallbackTypes.append(type.rawValue)
        return nil
    }
    if type != .mouseMoved { unexpectedCallbackTypes.append(type.rawValue) }
    if stallMilliseconds > 0 && (!stallOnlyOnClicks || type == .leftMouseDown) {
        stallsPerformed += 1
        usleep(UInt32(stallMilliseconds) * 1000)
    }
    return Unmanaged.passUnretained(event)
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
        case 5: tapTimeoutThreshold()
        case 6: clickRateStallAndReArm()
        default:
            // The harness's own regression case — no permission, no hardware,
            // no operator, so it runs on every build rather than only when
            // someone is at the machine.
            if CommandLine.arguments.dropFirst().first == "--self-test" {
                VerificationStep.selfTest()
            }
            print("""
            usage: SoredemoSpikeC <step>
              1  pointer track     — move the mouse across the whole screen for 5 s
              2  a click           — click once, anywhere
              3  keyboard filter   — press ⌘C once, then type an ordinary sentence
              4  secure input      — focus a password field, wiggle the mouse, dismiss it
              5  tap timeout       — how long may a callback take before the OS
                                    disables the tap? Move the mouse continuously.
              6  click-rate stall  — the SAME stall, but only on clicks, at the
                                    rate AX work actually happens. Then: does a
                                    re-armed tap survive? Click ~12 times.

            Run one at a time and record each step's output separately. Step 4
            changes what the system does with keyboard events while it runs.
            """)
            exit(2)
        }
    }

    /// Step 5 — see `stallingTapCallback` for why this is a spike.
    @MainActor
    static func tapTimeoutThreshold() {
        var step = VerificationStep(name: "5 — the tap callback's timeout budget")
        step.begin(repositoryPath: repositoryPath)

        // A ladder, not an interactive binary search: the operator does one
        // thing — keep the mouse moving — for the whole sweep. Each rung is
        // three seconds, which at the ~79 samples/second measured in step 1 is
        // hundreds of callbacks per rung, so a rung that does not trip did not
        // merely go unsampled.
        // Overridable so the 10–50 ms band can be narrowed without a rebuild:
        //   SoredemoSpikeC 5 10,20,30,40,50
        let ladder = CommandLine.arguments.dropFirst(2).first
            .map { $0.split(separator: ",").compactMap { Int($0) } }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? [10, 50, 100, 200, 400, 800, 1600]
        step.given([
            ("stall values swept (ms)", ladder.map(String.init).joined(separator: ", ")),
            ("seconds per rung", "3"),
            ("Spike A's worst hit-test", "125.47 ms — the number this budget has to be compared to"),
        ])
        // `every-rung-sampled` and `notification-silent` are new, and both were
        // already assertions here. The second is the step's most reused
        // finding — "a re-arm that waits for kCGEventTapDisabledByTimeout will
        // never run for a .listenOnly tap" — and it was checked without ever
        // being declared.
        step.expect([
            .init("positive-control", "positive control",
                  "the SAME ladder with .default (an active filter), which SHOULD "
                  + "trip — without it, \"listenOnly never tripped\" is "
                  + "indistinguishable from \"this experiment cannot detect a trip\""),
            .init("induced-every-rung-sampled", "every rung was sampled",
                  "≥ 1 callback on each of the \(ladder.count) rungs — a rung with zero "
                  + "callbacks did not fail to trip, it was not tested"),
            .init("notification-silent", "the callback channel",
                  "SILENT for .listenOnly: no kCGEventTapDisabled… type reaches the "
                  + "callback, so polling CGEvent.tapIsEnabled is the only detection left"),
            .init("threshold", "what is being found",
                  "the largest stall that does NOT disable the tap per the OS, and the "
                  + "smallest that does"),
            .init("rearm-interval", "also measured",
                  "the disable-to-re-arm interval, which is what a bare count cannot say. "
                  + "It has a source only when the notification arrives, so on a "
                  + ".listenOnly sweep it is expected to be UNMEASURABLE — and that has to "
                  + "be asserted rather than left as an empty line"),
        ])

        var tripped: [Int: Int] = [:]
        // Accumulated across rungs, because `timeoutDisableInstants` is cleared
        // at the top of each one. Without this the disable-to-re-arm interval
        // was printed per rung and then discarded, which is why the row that
        // declared it had nothing to be discharged by.
        var reArmGapsMs: [Double] = []
        var callbacksPerRung: [Int: Int] = [:]
        var controlTripped: [Int: Int] = [:]
        var controlSampled = 0
        var enabledPerOS: [Int: Bool] = [:]
        var controlDisabledPerOS = false

        print("\n>>> keep the mouse moving CONTINUOUSLY for the whole sweep — "
              + "\(ladder.count * 3) seconds. One beep starts it, two end it.")
        for remaining in stride(from: 3, to: 0, by: -1) {
            print("    starting in \(remaining)…")
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        VerificationStep.beepStart()
        // The spike times itself. "How long does this step take?" was estimated
        // by adding the rung durations — 21 s, then 27 s — and both were wrong,
        // because a callback that sleeps overruns the run loop's own timeout by
        // up to one stall, and the `.defaultTap` rungs stall the whole machine
        // so the operator's sense of it stretches further still. A duration a
        // person has to plan around is a number, and this project's rule for
        // numbers is that something computes them.
        let sweepStart = Minting.hostNow().rawValue

        for stall in ladder {
            stallMilliseconds = stall
            timeoutDisableInstants.removeAll()
            var callbacks = 0

            let mask = (1 << CGEventType.mouseMoved.rawValue)
            var tapBox: CFMachPort?
            // `userInfo` must be the tap itself so the callback can re-arm it.
            // Two-phase: create with nil, then patch is impossible, so the
            // callback reads a global instead — set below, before the loop.
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: tapOptionUnderTest, eventsOfInterest: CGEventMask(mask),
                                               callback: { proxy, type, event, info in
                                                   callbacksSeen += 1
                                                   return stallingTapCallback(proxy, type, event, info)
                                               },
                                               userInfo: nil) else {
                step.preconditionFailed("CGEvent.tapCreate returned nil at stall \(stall) ms — "
                                        + "Input Monitoring is not granted to video.soredemo.SpikeC.")
            }
            tapBox = tap
            activeTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            callbacksSeen = 0

            CFRunLoopRunInMode(.defaultMode, 3, false)
            callbacks = callbacksSeen
            // Asked of the OS, not of our own callback. "The tap was never
            // disabled" and "the tap was disabled and our notification path
            // missed it" are the same output from the callback's point of
            // view; this is a second, independent source for the same fact.
            let stillEnabledPerOS = CGEvent.tapIsEnabled(tap: tap)

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
            _ = tapBox
            activeTap = nil

            tripped[stall] = timeoutDisableInstants.count
            callbacksPerRung[stall] = callbacks
            let gaps = timeoutDisableInstants.map {
                Double($0.reArmed - $0.disabled) / 1_000_000
            }
            reArmGapsMs += gaps
            enabledPerOS[stall] = stillEnabledPerOS
            print(String(format: "    stall %5d ms  callbacks %5d  disabled %d time(s)  OS says enabled: %@%@",
                         stall, callbacks, timeoutDisableInstants.count,
                         stillEnabledPerOS ? "yes" : "NO  <- disabled without our callback seeing it",
                         gaps.isEmpty ? "" : "  disable→re-arm: "
                            + gaps.map { String(format: "%.2f ms", $0) }.joined(separator: ", ")))
        }
        // ---- POSITIVE CONTROL ----
        //
        // The same ladder with `.default`. A `.listenOnly` tap does not block
        // event delivery, so there may be nothing for the system to time out;
        // an active filter does block, and is the case the timeout exists for.
        // Without this, "no rung tripped" and "this experiment cannot detect a
        // trip" are the same output — and the whole point of the sweep is a
        // number someone will design against.
        print("\n    --- positive control: the same ladder with .default (an ACTIVE filter) ---")
        tapOptionUnderTest = .defaultTap
        for stall in [400, 1600] {
            stallMilliseconds = stall
            timeoutDisableInstants.removeAll()
            let mask = (1 << CGEventType.mouseMoved.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                               callback: { proxy, type, event, info in
                                                   callbacksSeen += 1
                                                   return stallingTapCallback(proxy, type, event, info)
                                               },
                                               userInfo: nil) else {
                print("    control: tapCreate returned nil for .default — cannot run the control")
                break
            }
            activeTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            callbacksSeen = 0
            CFRunLoopRunInMode(.defaultMode, 3, false)
            let controlStillEnabled = CGEvent.tapIsEnabled(tap: tap)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
            activeTap = nil
            controlTripped[stall] = timeoutDisableInstants.count
            if !controlStillEnabled { controlDisabledPerOS = true }
            if callbacksSeen > 0 { controlSampled += 1 }
            let gaps = timeoutDisableInstants.map { Double($0.reArmed - $0.disabled) / 1_000_000 }
            print(String(format: "    .default  stall %5d ms  callbacks %5d  disabled %d time(s)  OS says enabled: %@%@",
                         stall, callbacksSeen, timeoutDisableInstants.count,
                         controlStillEnabled ? "yes" : "NO",
                         gaps.isEmpty ? "" : "  disable→re-arm: "
                            + gaps.map { String(format: "%.2f ms", $0) }.joined(separator: ", ")))
        }
        tapOptionUnderTest = .listenOnly

        VerificationStep.beepStop()
        stallMilliseconds = 0
        let sweepSeconds = Double(Minting.hostNow().rawValue - sweepStart) / 1_000_000_000
        print(String(format: "\n    the sweep took %.1f s wall clock (the sum of the rung "
                             + "durations alone is %.1f s — a stalling callback overruns the run "
                             + "loop's timeout by up to one stall, and the .defaultTap rungs stall "
                             + "the machine)",
                     sweepSeconds,
                     Double(ladder.count * 3 + 6)))

        let sampled = ladder.filter { (callbacksPerRung[$0] ?? 0) > 0 }
        guard !sampled.isEmpty else {
            step.didNotHappen("no callback fired at any stall value — the mouse was not moving, "
                              + "so no rung was sampled and no rung's result means anything.")
        }

        // **The subject is the OS, not our callback.** The first two runs of
        // this step asserted on `tripped[stall]`, which counts
        // `kCGEventTapDisabledByTimeout` notifications received — and for a
        // `.listenOnly` tap that notification never arrives at all. Both runs
        // therefore reported "no rung tripped, the concern disappears", while
        // `CGEvent.tapIsEnabled` on the same taps in the same runs said the tap
        // had been disabled from 50 ms upward. Two sources, one question,
        // opposite answers; only the second is about the question.
        let notDisabled = sampled.filter { enabledPerOS[$0] == true }
        let disabled = sampled.filter { enabledPerOS[$0] == false }
        print("\n    PER THE OS (CGEvent.tapIsEnabled), which is the subject:")
        print("      largest stall still ENABLED after the rung: "
              + "\(notDisabled.max().map { "\($0) ms" } ?? "none — even the smallest was disabled")")
        print("      smallest stall found DISABLED after the rung: "
              + "\(disabled.min().map { "\($0) ms" } ?? "none — no rung was disabled")")

        step.check("induced-every-rung-sampled",
                   "every rung was sampled — \(sampled.count) of \(ladder.count) saw at least one "
                   + "callback. A rung with zero callbacks did not fail to trip; it was not tested",
                   sampled.count == ladder.count)

        let controlEverTripped = controlTripped.values.contains { $0 > 0 }
        // The message names WHICH channel carried the control's evidence. An
        // earlier version printed the notification counts and passed on the OS
        // signal, so it read "did trip (400ms:0)" — zero, while passing. Same
        // subject error as the assertion it exists to validate, one level up.
        let controlEvidence = controlEverTripped
            ? "the callback channel (notifications "
              + "\(controlTripped.map { "\($0.key)ms:\($0.value)" }.sorted().joined(separator: " ")) )"
            : controlDisabledPerOS
              ? "the OS only (CGEvent.tapIsEnabled reported it disabled; the notification did NOT "
                + "arrive even for an ACTIVE tap this run — so the notification channel is "
                + "unreliable in general, not merely absent for .listenOnly)"
              : "NOTHING"
        step.check("positive-control",
                   "POSITIVE CONTROL: an ACTIVE (.defaultTap) tap stalling for the same durations "
                   + "WAS disabled, detected via \(controlEvidence) — so a disable is detectable, "
                   + "and \"listenOnly was never disabled\" would be a finding rather than a blind "
                   + "instrument",
                   controlSampled > 0 && (controlEverTripped || controlDisabledPerOS))

        // Recorded as its own finding, not as noise. For a `.listenOnly` tap
        // the OS disables the tap and does NOT deliver the notification —
        // confirmed in the same run by the control, which DID receive it for an
        // active tap. Anything that re-arms on the notification is dead code
        // for a listen-only tap, and the only detection left is polling.
        step.check("notification-silent",
                   "the callback channel is SILENT for .listenOnly — non-mouseMoved types seen: "
                   + (unexpectedCallbackTypes.isEmpty ? "NONE"
                      : Set(unexpectedCallbackTypes).map { String(format: "0x%X", $0) }.sorted().joined(separator: ", "))
                   + ". A re-arm that waits for kCGEventTapDisabledByTimeout will never run for this "
                   + "tap kind; polling CGEvent.tapIsEnabled is the only detection",
                   unexpectedCallbackTypes.isEmpty)

        if let smallestDisabled = disabled.min() {
            let largestSafe = notDisabled.max()
            // **This says what the sweep measured, and nothing about AX.**
            // The previous wording concluded "so AX work inside this callback
            // WILL disable the tap" — falsified by STEP 6, which stalls at the
            // rate clicks actually arrive and finds the tap survives. This
            // sweep stalls on every mouseMoved at 60–120 Hz, which is roughly
            // 100x the real duty cycle, so what it measures is the point at
            // which SUSTAINED OVERLOAD disables a tap. That is a real number
            // about a real regime; it is not the budget for a per-click cost,
            // and the assertion must not smuggle a conclusion the experiment
            // cannot reach. Run step 6 for that question.
            step.check("threshold",
                       "under SUSTAINED overload — a stall on every pointer event at 60–120 Hz — "
                       + "the tap survives \(largestSafe.map { "\($0) ms" } ?? "0 ms") and is "
                       + "disabled by \(smallestDisabled) ms. This is NOT the budget for a "
                       + "per-click cost: step 6 stalls 125 ms on clicks only and the tap survives. "
                       + "Read this number as the overload threshold and nothing else",
                       true)
        } else {
            step.check("threshold",
                       "no rung was disabled per the OS up to \(ladder.max()!) ms — the budget is "
                       + "above that and Spike A's 125.47 ms worst hit-test is inside it", true)
        }

        // **The row that had no assertion, discharged by one that states the
        // limitation rather than by one that quietly skips it.**
        //
        // The interval can only be measured from the notification pair, and
        // the assertion above establishes that no notification arrives for a
        // `.listenOnly` tap at all. So on this sweep the quantity has no
        // source — which is a finding about the tap kind, not an omission, and
        // it is asserted here rather than left as a blank line in the log. The
        // predicate is not `true`: it passes when an interval was measured, or
        // when the notification channel is provably silent, and fails if
        // notifications arrived and no interval came out of them.
        let notificationsArrived = tripped.values.contains { $0 > 0 }
        step.check("rearm-interval",
                   reArmGapsMs.isEmpty
                       ? "VACUOUS ON THIS RUN — 0 disable→re-arm intervals were measurable across "
                         + "\(ladder.count) rungs, because the interval is derived from the "
                         + "kCGEventTapDisabledByTimeout notification and that notification never "
                         + "arrives for a .listenOnly tap (asserted above). NOTHING WAS LOOKING is "
                         + "not the reason; there was nothing to look at. The OS still disabled the "
                         + "tap — CGEvent.tapIsEnabled says so — it simply does not say when it "
                         + "re-armed"
                       : String(format: "%d disable→re-arm intervals measured, %.2f–%.2f ms. This is "
                                + "the quantity a bare count of disables cannot say, and it decides "
                                + "whether a segment spanning one can be annotated or has to be "
                                + "refused",
                                reArmGapsMs.count, reArmGapsMs.min() ?? 0, reArmGapsMs.max() ?? 0),
                   !reArmGapsMs.isEmpty || !notificationsArrived)

        step.finish(remedy: "If a rung shows zero callbacks the mouse stopped moving there; "
                            + "re-run before reading the threshold.")
    }

    /// Step 6 — the two questions step 5 could not answer, and one it answered
    /// about the wrong mechanism.
    ///
    /// **Part A: the click-rate stall.** Step 5 found the tap disabled at a
    /// 20 ms stall and the design conclusion "AX must leave the callback
    /// thread" was drawn from it. But step 5 stalls on every `mouseMoved` at
    /// 60–120 Hz, which cannot keep up at 20 ms by construction — that is
    /// sustained overload, not a single slow callback, and real taps
    /// (Karabiner, BetterTouchTool) do far more than 20 ms of work per event
    /// and run fine. This part stalls **only on `.leftMouseDown`**, at 125 ms,
    /// which is Spike A's measured worst hit-test at the rate clicks actually
    /// arrive. If the tap survives, the conclusion drawn from step 5 was drawn
    /// from the wrong distribution.
    ///
    /// **Part B: does a re-armed tap stay armed?** The only question that
    /// genuinely requires a real timeout-induced disable, because it is the
    /// only one whose answer could depend on *why* the tap was disabled — a
    /// backlog may still be queued, or the system may hold a record. It
    /// decides whether "re-arm" is a sufficient strategy or has to become
    /// "re-arm with backoff". Induced with the every-event stall, which step 5
    /// showed reliably produces a disable.
    ///
    /// **What this step deliberately does NOT test:** whether the product's
    /// polling detects a real disable through a real `CFMachPort`. That needs
    /// no timeout at all — `CGEventTapEnable(tap, false)` disables through the
    /// same mechanism and the detector reads the same flag off the same port.
    /// Keeping it out of here is what lets the product ship with no stall seam,
    /// and a seam is an opportunity to verify the wrong implementation.
    @MainActor
    static func clickRateStallAndReArm() {
        var step = VerificationStep(name: "6 — a click-rate stall, and whether a re-arm survives")
        step.begin(repositoryPath: repositoryPath)
        step.given([
            ("part A duration", "30 s; click about a dozen times, keep the mouse moving between"),
            ("part B decides", "whether 're-arm' suffices or must become 're-arm with backoff' — "
                               + "a consequence of the rows below, not a claim about this run"),
        ])
        step.expect([
            .init("induced-part-a-stall", "part A stall",
                  "125 ms, on .leftMouseDown ONLY — Spike A's worst hit-test. The subject "
                  + "is STALLS PERFORMED, not callbacks: the mask includes mouseMoved, so a "
                  + "run with zero clicks records ~1900 callbacks and takes no stall at all"),
            .init("part-a-verdict", "part A asks",
                  "does a 6% duty cycle disable the tap, or was step 5's 20 ms a "
                  + "sustained-overload artefact of stalling every pointer event?"),
            .init("part-b-verdict", "part B",
                  "induce a disable with an every-event stall, re-arm it, then poll: "
                  + "does it STAY armed, or die again immediately?"),
        ])

        let mask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        func runTap(seconds: Int, stall: Int, clicksOnly: Bool,
                    poll: (CFMachPort, Int) -> Void) -> (callbacks: Int, enabledAtEnd: Bool)? {
            stallMilliseconds = stall
            stallOnlyOnClicks = clicksOnly
            timeoutDisableInstants.removeAll()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                               callback: { proxy, type, event, info in
                                                   callbacksSeen += 1
                                                   return stallingTapCallback(proxy, type, event, info)
                                               },
                                               userInfo: nil) else { return nil }
            activeTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            callbacksSeen = 0
            stallsPerformed = 0
            for elapsed in 0..<seconds {
                CFRunLoopRunInMode(.defaultMode, 1, false)
                poll(tap, elapsed)
            }
            let enabled = CGEvent.tapIsEnabled(tap: tap)
            let calls = stallsPerformed
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
            activeTap = nil
            stallMilliseconds = 0
            stallOnlyOnClicks = false
            return (calls, enabled)
        }

        // ---- part A ----
        print("\n>>> PART A — click about a DOZEN times over 30 seconds, and keep the mouse moving "
              + "between clicks. One beep starts, two end.")
        for remaining in stride(from: 3, to: 0, by: -1) {
            print("    starting in \(remaining)…")
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        VerificationStep.beepStart()
        var firstDisabledSecondA: Int?
        let a = runTap(seconds: 30, stall: 125, clicksOnly: true) { tap, elapsed in
            if firstDisabledSecondA == nil, !CGEvent.tapIsEnabled(tap: tap) {
                firstDisabledSecondA = elapsed
            }
        }
        VerificationStep.beepStop()
        guard let a else {
            step.preconditionFailed("tapCreate returned nil — Input Monitoring is not granted to "
                                    + "video.soredemo.SpikeC.")
        }
        print(String(format: "    part A: %d stalls performed, enabled at end: %@, first seen disabled at: %@",
                     a.callbacks, a.enabledAtEnd ? "yes" : "NO",
                     firstDisabledSecondA.map { "t+\($0)s" } ?? "never"))

        // ---- part B ----
        print("\n>>> PART B — keep the mouse moving for 20 more seconds. No clicking needed.")
        VerificationStep.beepStart()
        var reArmSurvivedSeconds = 0
        var reArmedAt: Int?
        let b = runTap(seconds: 20, stall: 50, clicksOnly: false) { tap, elapsed in
            if CGEvent.tapIsEnabled(tap: tap) {
                if reArmedAt != nil { reArmSurvivedSeconds += 1 }
            } else if reArmedAt == nil {
                // Induced disable observed. Re-arm once, then stop stalling so
                // the question is "does a re-armed tap stay armed", not "does
                // it survive continued overload" — a different question, and
                // the strategy under test is re-arm, not re-arm-and-keep-abusing.
                CGEvent.tapEnable(tap: tap, enable: true)
                stallMilliseconds = 0
                reArmedAt = elapsed
            }
        }
        VerificationStep.beepStop()

        guard a.callbacks > 0 else {
            step.didNotHappen("part A performed ZERO stalls — nothing was clicked. The mouse may "
                              + "well have been moved; that is not what this part stalls on.")
        }
        print(String(format: "    part B: re-armed at %@, then stayed enabled for %d of the "
                             + "remaining seconds, enabled at end: %@",
                     reArmedAt.map { "t+\($0)s" } ?? "never — no disable was induced",
                     reArmSurvivedSeconds, (b?.enabledAtEnd ?? false) ? "yes" : "NO"))

        // The subject is STALLS, not callbacks. Eight is a floor for "about a
        // dozen clicks" that still leaves room for a miscount, and any number
        // below it means part A's verdict is about a run that barely stalled.
        step.check("induced-part-a-stall",
                   "part A performed \(a.callbacks) stalls of 125 ms — the path under test was "
                   + "exercised. Callbacks are NOT the subject: the mask includes mouseMoved, so a "
                   + "run with zero clicks records ~1900 callbacks, performs no stall at all, and "
                   + "would otherwise pass claiming the tap survived a stall it never took",
                   a.callbacks >= 8)
        step.check("part-a-verdict",
                   "PART A: a 125 ms stall on CLICKS ONLY — Spike A's worst hit-test at the rate "
                   + "clicks actually arrive — left the tap "
                   + (a.enabledAtEnd ? "ENABLED. Step 5's 20 ms figure was a sustained-overload "
                                       + "artefact of stalling every pointer event at 60–120 Hz, and "
                                       + "the budget for a per-click cost is larger than it"
                                     : "DISABLED at \(firstDisabledSecondA.map { "t+\($0)s" } ?? "?"). "
                                       + "A single slow callback is enough, so AX must leave the "
                                       + "callback thread and step 5's conclusion holds for the "
                                       + "right reason"),
                   a.enabledAtEnd)
        if let reArmedAt {
            // **Two things this cannot say, and used to.**
            //
            // `reArmSurvivedSeconds` can only increment on polls AFTER
            // `reArmedAt`, so with a disable at t+0 its ceiling is 19 — the
            // reading is the instrument's saturated maximum, not a 95% result
            // with a one-second shortfall, and it was quoted as the latter.
            //
            // And the stall is switched OFF at the moment of re-arm (see the
            // poll closure above), deliberately, so what is measured is "a tap
            // re-armed and then LEFT ALONE stays enabled". Nothing was trying
            // to disable it. Backoff exists for a PERSISTENT cause — which is
            // the premise of `AXObserver`'s whole asymmetry argument, a hung
            // target — and under one, a 10 Hz poll becomes a 10 Hz re-arm loop.
            // That may well be right; it is not what this measured. Same shape
            // as step 5: a measurement taken at a duty cycle the real case does
            // not have.
            let ceiling = 19 - reArmedAt
            step.check("part-b-verdict",
                       "PART B: after a timeout-induced disable at t+\(reArmedAt)s, one "
                       + "CGEventTapEnable(true) with the stall REMOVED left the tap enabled for "
                       + "\(reArmSurvivedSeconds) of \(ceiling) further polls — the instrument's "
                       + "maximum. So a re-arm sticks when nothing is still trying to disable the "
                       + "tap. Behaviour under a PERSISTENT cause is UNMEASURED, and that is the "
                       + "case backoff would exist for",
                       reArmSurvivedSeconds == ceiling && (b?.enabledAtEnd ?? false))
        } else {
            step.check("part-b-verdict",
                       "PART B did not run: no disable was induced in 20 s of every-event stalling, "
                       + "so whether a re-armed tap survives is UNMEASURED. Not a pass",
                       false)
        }
        step.finish(remedy: "If part A shows few callbacks, click more and re-run before reading it.")
    }

    // MARK: - shared scaffolding

    static let repositoryPath = "~/Documents/Soredemo/soredemo-main"

    /// The arrangement under test, as `given` rows.
    ///
    /// Derived, never typed: every expectation-table error this project has
    /// made was a constant written by the person who knew the implementation,
    /// and each one happened to be the identity element of the transform under
    /// test.
    ///
    /// **Two rows left this function when the guard's output became a
    /// correspondence table.** It used to append "every normalised coordinate
    /// in [0, 1]" and "event timestamp base: nanoseconds, same as
    /// Minting.hostNow()", and it was called by all four of steps 1–4 — but
    /// only steps 1 and 2 check the coordinate range and only step 1 checks the
    /// timestamp base. A shared helper appending a claim to steps that never
    /// intended it is the mirror image of the failure this change is about:
    /// there, an expectation nobody checked; here, an expectation nobody meant
    /// to make. Each step now declares those rows itself, where it checks them.
    ///
    /// What remains is the arrangement, which is read off the configuration at
    /// the moment it is printed and has nothing about the run's outcome to be
    /// right or wrong about.
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
                        _ step: VerificationStep,
                        eachSecond: (Int) -> Void = { _ in }) -> InputObserver {
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
        // The observation window itself is bracketed by the audible signal, so
        // the person at the machine knows when it is open. The tap is created
        // BEFORE the beep — a tap that takes a moment to arm must not eat the
        // first thing the operator does.
        VerificationStep.beepStart()
        // One-second slices rather than one long run, so a caller can sample
        // ambient state through the window instead of only at its ends.
        for elapsed in 0..<Int(seconds.rounded(.up)) {
            CFRunLoopRunInMode(.defaultMode, 1, false)
            eachSecond(elapsed)
        }
        VerificationStep.beepStop()
        observer.stop()
        return observer
    }

    @MainActor
    /// Kept as a thin wrapper so every call site reads the same, but the
    /// signalling now belongs to `VerificationStep.humanWindow` — the
    /// operator never sees this stdout, so a printed countdown was an
    /// instruction delivered to the only party that cannot act on it. Three
    /// consecutive click-window runs failed on timing alone before that was
    /// noticed, and each looked like it might be a defect in the tap.
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
        step.given(arrangementRows(arrangement))
        // Three rows are new, and every one of them already had an assertion:
        // known revisions, the spatial extent of the track, and monotonic
        // instants were checked and never declared. The old table's two
        // duplicate statements of the timestamp base ("event timestamp base"
        // from the shared helper, and "implausible timestamps" here) are now
        // one row — two rows saying one thing means an assertion discharges
        // both, which is the count problem at a smaller scale.
        step.expect([
            .init("induced-sample-rate", "pointer samples in 5 s",
                  "> 300 — the plan's floor is 60 in 1 s, measured IN the first second "
                  + "rather than divided out of the total"),
            .init("normalised-range", "every normalised coordinate", "in [0, 1]"),
            .init("known-revisions", "revisions belong to attached displays",
                  "every sample's revision is one the arrangement contains. A revision "
                  + "from nowhere means the conversion invented one, which is the failure "
                  + "GeometryRevision exists to make impossible"),
            .init("track-spans", "the track is a track",
                  "max x − min x > 0.5 — a stationary pointer sampled 400 times satisfies "
                  + "the rate row above and is not a track across the whole screen"),
            .init("monotonic-instants", "instants are non-decreasing",
                  "taken from the EVENT's own timestamp, not from when the callback ran"),
            .init("timestamp-base", "event timestamp base",
                  "nanoseconds on Minting.hostNow()'s base — 0 implausible timestamps of "
                  + "N. This is the live unit check: a constructed CGEvent has "
                  + "timestamp == 0, so only the window server can supply a genuine one"),
            .init("no-unroutable", "unroutable locations",
                  "0 — the pointer cannot be off every display"),
            .init("no-secure-suppression", "suppressed by secure input",
                  "0 — no password field is focused"),
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
        step.check("induced-sample-rate",
                   "\(inFirstSecond) pointer samples in the first second of movement "
                   + "(\(samples.count) over the whole 5 s) — the plan's floor is 60 in 1 s",
                   inFirstSecond > 60)
        step.check("normalised-range",
                   "every normalised x and y is in [0, 1] — \(samples.count) samples across "
                   + "\(arrangement.placements.count) display(s), so a second display would have "
                   + "failed this if the global point were not routed first",
                   samples.allSatisfy { (0...1).contains($0.position.x) && (0...1).contains($0.position.y) })
        step.check("known-revisions",
                   "every sample carries the revision of a display that is actually attached",
                   revisionsAreKnown(collected, arrangement))
        step.check("track-spans",
                   "the track spans more than a single point — min/max x "
                   + String(format: "%.4f/%.4f", samples.map(\.position.x).min()!, samples.map(\.position.x).max()!)
                   + ", y "
                   + String(format: "%.4f/%.4f", samples.map(\.position.y).min()!, samples.map(\.position.y).max()!),
                   (samples.map(\.position.x).max()! - samples.map(\.position.x).min()!) > 0.5)
        step.check("monotonic-instants",
                   "instants are non-decreasing — \(samples.count) samples, taken from the EVENT's "
                   + "own timestamp and not from when the callback ran",
                   zip(samples, samples.dropFirst()).allSatisfy { $0.instant.hostTime <= $1.instant.hostTime })
        step.check("timestamp-base",
                   "0 implausible timestamps of \(samples.count) — a real tapped CGEventTimestamp is "
                   + "within a second of Minting.hostNow(), i.e. nanoseconds on the same base. "
                   + "Observed: \(diagnostics.implausibleEventTimestampCount)",
                   diagnostics.implausibleEventTimestampCount == 0)
        step.check("no-unroutable",
                   "0 unroutable locations (observed \(diagnostics.unroutablePointerLocations))",
                   diagnostics.unroutablePointerLocations == 0)
        step.check("no-secure-suppression",
                   "0 events suppressed by secure input (observed "
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
        step.given(arrangementRows(arrangement))
        // `known-revisions` is new: "both carry the revision of an attached
        // display" was asserted here and never declared.
        //
        // "positions" said "both inside [0, 1], **and close to each other**",
        // and nothing checked the second half. It is NARROWED rather than
        // deleted, and the reason is recorded here rather than in a report:
        // "close" needs a threshold, and there is no derivation for one on this
        // step — a slightly dragged click is still one click, and a guessed
        // tolerance would fail a correct run. A number this project cannot
        // derive is a number it does not assert.
        step.expect([
            .init("induced-two-events", "button events", "2 per click — one .down, one .up"),
            .init("down-before-up", "order", ".down strictly before .up, by instant"),
            .init("normalised-range", "positions", "both inside [0, 1]"),
            .init("known-revisions", "revisions belong to attached displays",
                  "both events carry a revision the arrangement contains"),
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
        // Printed unconditionally, because "8 events" has two indistinguishable
        // causes — eight real clicks, or one click delivered four times — and
        // the run that produced 8 and then 10 could be either. The gaps
        // separate them: duplicates of one press sit within a frame of each
        // other, four presses by a hand are tens of milliseconds apart at the
        // very least. Measure to discriminate before diagnosing.
        let firstInstant = buttons.first?.instant.hostTime.rawValue ?? 0
        print("        button events, ms since the first, in arrival order:")
        for b in buttons {
            let msSinceFirst = Double(b.instant.hostTime.rawValue - firstInstant) / 1_000_000
            print(String(format: "          %-12s %8.2f ms   at (%.4f, %.4f)",
                         ("\(b.button).\(b.phase)" as NSString).utf8String!, msSinceFirst,
                         b.position.x, b.position.y))
        }
        step.check("induced-two-events",
                   "\(buttons.count) button events for one click — exactly two",
                   buttons.count == 2)
        step.check("induced-two-events",
                   "the first is .down and the second is .up (observed "
                   + "\(buttons.map { "\($0.button.rawValue).\($0.phase.rawValue)" }.joined(separator: ", ")))",
                   buttons.first?.phase == .down && buttons.last?.phase == .up)
        step.check("down-before-up",
                   "the down is strictly before the up on the host clock",
                   (buttons.first?.instant.hostTime.rawValue ?? 0) < (buttons.last?.instant.hostTime.rawValue ?? 0))
        step.check("normalised-range",
                   "both carry a normalised position in [0, 1]",
                   buttons.allSatisfy { (0...1).contains($0.position.x) && (0...1).contains($0.position.y) })
        step.check("known-revisions",
                   "both carry the revision of an attached display",
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
        step.given(arrangementRows(arrangement) + [
            ("allow-list size", "\(InputObserver.approvedShortcuts.count) entries"),
        ])
        // `non-vacuous-input` is new, and it is the row this step most needed:
        // "20 keyDowns were seen, so a zero result below is not vacuous" was
        // asserted and never declared, which means the step's own defence
        // against a vacuous pass was the one thing outside the table.
        //
        // "KeySamples expected: exactly 1, with shortcut cmd+c" was one row
        // making two claims — a count and an identity — with two assertions
        // under it. Split.
        step.expect([
            .init("induced-non-vacuous-input", "the filter was given real input",
                  "≥ 20 keyDown events seen — 'nothing was recorded' is nearly true of an "
                  + "empty input as well, so the rows below cannot be read without this"),
            .init("one-keysample", "KeySamples recorded", "exactly 1"),
            .init("shortcut-identity", "and its identifier",
                  "\"cmd+c\" — a name from the table in InputObserver.swift, not a "
                  + "rendering of anything pressed"),
            .init("ordinary-keys-refused", "KeySamples for the typing",
                  "0 — every ordinary key is refused, so refused == seen − 1"),
            .init("key-accounting", "keyDown accounting",
                  "seen == recorded + refused, with no tolerance"),
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
            // The refusal states MEASUREMENTS, not the inference "nothing was
            // typed". Zero keyDowns has two causes that look identical from
            // here — nobody typed, or keyboard events do not reach this tap
            // because Input Monitoring is not granted — and the second is the
            // interesting one. A pointer tap needs no grant and a keyboard tap
            // does, so this step is the first place the two diverge, and the
            // run that found this had 395 pointer samples and 2 button events
            // from the same tap minutes earlier.
            let monitoring = CapturePermissions.status(of: .inputMonitoring)
            let pointerEvidence = diagnostics.pointerSamples > 0 || diagnostics.buttonEvents > 0
            let tapVerdict = pointerEvidence
                ? "SOME arrived in this same window, from the same tap — so the tap is live and it "
                  + "is specifically KEYBOARD events that are absent"
                : "none either — either the tap is not delivering at all, or nothing was done in "
                  + "the window"
            step.didNotHappen("no keyDown events reached the tap. Measured, not concluded:\n"
                + "  Input Monitoring status : \(monitoring)\n"
                + "  keyDowns seen           : \(diagnostics.keyDownsSeen)\n"
                + "  pointer/button events   : \(tapVerdict)\n"
                + "\"nothing was typed\" is one explanation and this run cannot tell it from the other.")
        }
        guard diagnostics.keyDownsSeen >= 20 else {
            step.preconditionFailed("only \(diagnostics.keyDownsSeen) keyDown events — fewer than the "
                                    + "twenty asked for. 'Nothing was recorded' is nearly true of an "
                                    + "empty input as well, so this cannot be read.")
        }

        step.check("induced-non-vacuous-input",
                   "\(diagnostics.keyDownsSeen) keyDown events were seen — the filter was given "
                   + "real input, so a zero result below is not vacuous",
                   diagnostics.keyDownsSeen >= 20)
        step.check("one-keysample",
                   "exactly 1 KeySample from \(diagnostics.keyDownsSeen) keystrokes (observed "
                   + "\(collected.keys.count))",
                   collected.keys.count == 1)
        step.check("shortcut-identity",
                   "the one recorded identifier is \"cmd+c\" — a name from the table in "
                   + "InputObserver.swift, not a rendering of anything pressed (observed "
                   + "\(collected.keys.map(\.shortcut)))",
                   collected.keys.map(\.shortcut) == ["cmd+c"])
        step.check("key-accounting",
                   "keyDown accounting balances: \(diagnostics.keyAccounting)",
                   diagnostics.everyKeyDownIsAccountedFor)
        step.check("ordinary-keys-refused",
                   "\(diagnostics.keyDownsRefused) keystrokes were refused and left no trace of any "
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
        step.given(arrangementRows(arrangement) + [
            ("IsSecureEventInputEnabled now",
             "\(IsSecureEventInputEnabled()) — enforced by the precondition below, which "
             + "aborts the step rather than recording an assertion. A `check` here could "
             + "never be false at the point it would run"),
        ])
        // Two rows are new. `events-arrived-while-secure` is the non-vacuity
        // row: without an event delivered while the flag was set, the "no
        // observation" row below is a statement about an empty set.
        // `bounded-by-motion` was asserted and never declared.
        //
        // "SecureInputInterval records: exactly 1, endedBy .secureInputDisabled"
        // was one row making two claims with two assertions under it. Split.
        step.expect([
            .init("induced-events-arrived-while-secure", "events arrived while it was true",
                  "> 0 — the observer needs an event to arrive while the flag is set, or "
                  + "it has nothing to ask the question on and the row below is vacuous"),
            .init("no-observations-while-secure", "observations while it is true",
                  "0 — nothing at all, not a redacted sample: no pointer sample falls "
                  + "inside the interval"),
            .init("one-interval", "SecureInputInterval records", "exactly 1"),
            .init("ended-by-disabled", "and how it ended",
                  ".secureInputDisabled — a measured interval, not the .observationStopped "
                  + "lower bound"),
            .init("positive-width", "interval width",
                  "> 0 — it spans the seconds the field had focus"),
            .init("bounded-by-motion", "the gap is bounded by real motion",
                  "pointer samples on BOTH sides of the interval, so it is a gap and not "
                  + "the end of the recording"),
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
        // Sampled once a second THROUGH the window, because "no event arrived
        // while secure input was on" has two causes that look identical from
        // the counters: secure input never turned on at all, or it did and
        // nothing moved. The first is by far the more likely — a `sudo` prompt
        // in Terminal does NOT enable system-wide secure input unless
        // Terminal's own "Secure Keyboard Entry" is switched on, which it is
        // not by default. Without this sample the refusal names two causes and
        // measures neither.
        var secondsSecureInputWasOn = 0
        let observer = observe(for: 14, into: collected, step) { _ in
            if IsSecureEventInputEnabled() { secondsSecureInputWasOn += 1 }
        }
        let diagnostics = observer.diagnostics
        print("        secure input was ON during \(secondsSecureInputWasOn) of the 14 sampled seconds")

        guard diagnostics.eventsSuppressedBySecureInput > 0 else {
            step.didNotHappen("no event was observed while secure input was enabled. "
                + "Measured, not concluded:\n"
                + "  seconds secure input was ON : \(secondsSecureInputWasOn) of 14\n"
                + "  pointer samples in total    : \(diagnostics.pointerSamples)\n"
                + (secondsSecureInputWasOn == 0
                   ? "  -> secure input NEVER turned on. The password field did not take focus, or it "
                     + "was one that does not enable system-wide secure input — a `sudo` prompt in "
                     + "Terminal does not, unless Terminal's own Secure Keyboard Entry is on. Use a "
                     + "native sheet: System Settings' unlock, or a Keychain prompt."
                   : "  -> secure input WAS on for part of the window, and no event arrived during "
                     + "it. The mouse was not moving while the field had focus.")
                + "\nThis observer needs an event to arrive while the flag is set; with none, it has "
                + "nothing to ask the question on.")
        }

        let intervals = collected.intervals
        step.check("induced-events-arrived-while-secure",
                   "\(diagnostics.eventsSuppressedBySecureInput) events arrived while secure input "
                   + "was enabled — so the zero-observation rows below are about a window in which "
                   + "something WAS delivered. The old wording here also claimed \"and NONE of them "
                   + "produced an observation\", which its predicate did not test; that clause is now "
                   + "the separate assertion at the end of this step",
                   diagnostics.eventsSuppressedBySecureInput > 0)
        step.check("one-interval",
                   "exactly 1 SecureInputInterval record (observed \(intervals.count))",
                   intervals.count == 1)
        step.check("ended-by-disabled",
                   "it is marked .secureInputDisabled — a measured interval, not the "
                   + ".observationStopped lower bound (observed \(intervals.map { $0.endedBy.rawValue }))",
                   intervals.first?.endedBy == .secureInputDisabled)
        step.check("positive-width",
                   "the interval has positive width: "
                   + String(format: "%.3f s", Double(intervals.first?.interval.duration.rawValue ?? 0) / 1e9),
                   (intervals.first?.interval.duration.rawValue ?? 0) > 0)
        step.check("bounded-by-motion",
                   "pointer samples exist on BOTH sides of the interval — the gap is bounded by "
                   + "real motion, so it is a gap and not the end of the recording",
                   collected.pointers.contains { $0.instant.hostTime < (intervals.first?.interval.start ?? Nanoseconds(0)) }
                   && collected.pointers.contains { $0.instant.hostTime >= (intervals.first?.interval.end ?? Nanoseconds(0)) })
        step.check("no-observations-while-secure",
                   "no pointer sample falls inside the interval — \(collected.pointers.count) samples "
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
