// Spike A — click-to-hit-test pairing latency, **against the real observers**.
//
// This file used to carry its own inline tap and its own inline AX walk. It
// does not any more: it drives `Soredemo/Capture/InputObserver.swift` and
// `Soredemo/Capture/AXObserver.swift`, the code that ships, for the reason
// `scripts/run-cross-boundary-probe.sh` and Spike C's build script both carry
// — a spike that measures a copy measures the copy. F2-2's distribution was
// produced by the inline version, so re-running this is the only thing that
// can say whether the shipping observer does more work than the spike that
// justified its bounds.
//
// **What needs a person, and why nothing here can be automated further.**
// Three separate grants and one physical act:
//
//   1. Input Monitoring, for `CGEvent.tapCreate`. TCC grants it to a signed
//      bundle, not to a `swiftc` output run from a shell.
//   2. Accessibility, for `AXUIElementCopyElementAtPosition`. Without it every
//      hit-test returns nothing, and `AXObserver.Diagnostics
//      .hitTestsReturnedNothingWithoutAccessibility` is what says so instead
//      of the run reading as "nobody clicked on anything".
//   3. Real applications, of three different classes — native AppKit, an
//      Electron app, and one known to be slow. F2-2's spread is 120× between
//      p50 and max and it is entirely a property of what is being clicked on.
//   4. Clicks **during animations**. A static screen measures the easy case;
//      the pairing fails while the UI is moving, which is when people click.
//
// `scripts/cross-boundary-digest-probe.swift` § 8 checks everything that does
// not need those four: both coordinate conversions, the depth cap, the
// budget, all four truncation reasons, the call arithmetic and the
// containment instrument, against a synthetic `AXElementSource`. This file is
// the remainder, and the remainder is irreducible.
//
// It records. It does not judge — D2-1. Nothing here decides which element is
// "the control".
//
// **The JSONL it writes carries window titles from real work and is NOT
// committed**, exactly as the design doc says of the previous run's log. What
// this file *prints* is measurements and AX role names only — never a title,
// never an application name (`AGENTS.md`: reports quote measurements, never
// captured content).

import AppKit
import CoreGraphics
import Foundation
import Geometry
import Project
import Timeline

/// Everything the tap delivered, plus the AX chain recorded against each
/// `.down`.
///
/// A class with a lock rather than captured `var`s: `InputObserver`'s sink is
/// `@Sendable`, which is the constraint the real callback path lives under.
nonisolated final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AXChainRecord] = []
    private var clicks = 0

    private var windows: [TapDisabledInterval] = []

    var records: [AXChainRecord] { lock.withLock { storage } }
    var clicksSeen: Int { lock.withLock { clicks } }
    var blindWindows: [TapDisabledInterval] { lock.withLock { windows } }

    func append(_ record: AXChainRecord) { lock.withLock { storage.append(record) } }
    func appendBlindWindow(_ window: TapDisabledInterval) { lock.withLock { windows.append(window) } }
    func countClick() { lock.withLock { clicks += 1 } }
}

@main
enum SpikeA {

    static let repositoryPath = "~/Documents/Soredemo/soredemo-main"

    /// F2-2, from `docs/design/2026-08-02-phase-2-record-design.md`, 118
    /// samples. Printed as the expectation table **before** anything is
    /// measured, so a reading cannot be revised toward it afterwards.
    /// The `id` is what makes this table migratable at all. Both the
    /// expectation rows and the ratio assertions are generated from this one
    /// array, so the identifier a row declares and the identifier its
    /// assertion cites come from the same element — the only place in this
    /// migration where a generated identifier is safe, because there is one
    /// source rather than two that must agree.
    static let f2_2: [(id: String, name: String, p50: Double, p90: Double, max: Double)] = [
        ("f2-2-hit-test-ms", "hit-test interval ms", 1.05, 21.25, 125.47),
        ("f2-2-whole-walk-ms", "whole walk ms",        5.10, 32.22, 173.53),
        ("f2-2-ax-calls", "AX calls",            41,   106,   131),
        ("f2-2-chain-depth", "chain depth",          3,    12,    20),
    ]

    /// Keeps what the observation closure hands over. The first version of
    /// step 1 discarded it and could then only assert counts.
    final class CollectedWindows: @unchecked Sendable {
        // `nonisolated(unsafe)` on the storage, guarded by `lock` — the same
        // contract `CaptureSession` and `InputObserver` document at length:
        // under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor an unannotated
        // stored property is @MainActor, and this is appended to from the
        // observation closure, which runs off the main actor.
        private let lock = NSLock()
        private nonisolated(unsafe) var _windows: [TapDisabledInterval] = []
        private nonisolated(unsafe) var _pointerInstants: [Int64] = []
        nonisolated var windows: [TapDisabledInterval] { lock.withLock { _windows } }
        nonisolated func pointerInstantsAfter(_ nanos: Int64) -> Int {
            lock.withLock { _pointerInstants.filter { $0 > nanos }.count }
        }
        nonisolated func append(_ observation: InputObserver.Observation) {
            lock.withLock {
                switch observation {
                case .tapDisabled(let w): _windows.append(w)
                case .pointer(let p): _pointerInstants.append(p.instant.hostTime.rawValue)
                default: break
                }
            }
        }
    }

    /// How many stalls step 2's observation closure actually performed.
    ///
    /// `nonisolated` with a lock, for the reason `CollectedWindows` documents:
    /// the closure runs off the main actor and under
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unannotated stored
    /// property is `@MainActor`, which traps at runtime rather than failing to
    /// compile.
    ///
    /// It exists because step 2 never established that its own manipulation
    /// happened. Spike C's step 6 recorded the same defect from the other
    /// side: its guard counted callbacks, which include `mouseMoved`, while
    /// the subject was stalls — and a run with zero clicks passed claiming the
    /// tap survived a stall it never took.
    nonisolated final class StallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private nonisolated(unsafe) var _count = 0
        nonisolated var performed: Int { lock.withLock { _count } }
        nonisolated func count() { lock.withLock { _count += 1 } }
    }

    /// Every step's transcript, to a file.
    ///
    /// **`open` severs stdout.** An `LSUIElement` app started through
    /// LaunchServices has nowhere for `print` to go that anyone can read — and
    /// `open` is mandatory here, because exec'ing the binary attributes every
    /// grant to whatever started it. So the two requirements collide: the only
    /// launch path that measures this identity is the only one with no output.
    ///
    /// Discovering that after a run costs the run. `--dry-run` exists to find
    /// it before: it writes the file, prints nothing else, and **needs no
    /// permission at all**, so it can be checked while the grants are still
    /// unasked.
    nonisolated(unsafe) static var transcript: [String] = []

    nonisolated static func record(_ line: String) {
        transcript.append(line)
        print(line)
    }

    @MainActor
    static func flushTranscript() {
        guard let i = CommandLine.arguments.firstIndex(of: "--out"),
              i + 1 < CommandLine.arguments.count else { return }
        try? transcript.joined(separator: "\n")
            .write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
    }

    /// Writes the output file and exits. No TCC, no measurement, no window.
    @MainActor
    static func dryRun() -> Never {
        let responsible = ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "unknown"
        record("── dry run: does the output file appear at all? ──")
        record("process identity   : \(Bundle.main.bundleIdentifier ?? "?")")
        record("grant attributed to: \(responsible)")
        record("launched correctly : \(responsible == Bundle.main.bundleIdentifier ? "yes, via open" : "NO — exec'd, so a measuring run here would measure \(responsible)")")
        record("")
        record("This file existing is the whole result. It needed no permission, so it can be")
        record("checked while every grant is still unasked — which is the point: `open` severs")
        record("stdout, and finding that out after a timed run costs the run.")
        flushTranscript()
        exit(CommandLine.arguments.contains("--out") ? 0 : 4)
    }

    /// **Acquire the grants, and nothing else.** First of two launches.
    ///
    /// **Why it is separate from measuring.** A permission dialog inside a
    /// timed window measures how fast the operator can find the button. The
    /// windows here are 6 and 10 seconds; a first-run dialog is not a delay in
    /// the measurement, it is the whole measurement.
    ///
    /// So this launch asks for everything, reports what it got, and exits. The
    /// measuring launch then has a precondition that all three are already
    /// held — and **"no dialog appeared this time" becomes a recorded result**
    /// rather than an absence nobody looked for.
    ///
    /// Must be started with `open -n`, or the grants land on whatever exec'd
    /// it. This step refuses otherwise, by name.
    @MainActor
    static func acquireGrants() {
        var step = VerificationStep(name: "human 0 — acquire the grants, measure nothing")
        step.begin(repositoryPath: repositoryPath)

        let responsible = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        guard responsible == Bundle.main.bundleIdentifier else {
            step.preconditionFailed("""
            this process is running under \(responsible ?? "an unknown identity"), not \
            \(Bundle.main.bundleIdentifier ?? "?"). A grant accepted now would attach to THAT, \
            which is how every Phase 2 verification came to be recorded under a bundle identifier \
            that holds nothing. Start with:
              open -n ~/Applications/SoredemoSpikeA.app --args grant --out <file>
            """)
        }

        step.inducesNothing("this launch acquires permissions and measures nothing; the stimulus "
                            + "controls belong to the launches that measure")
        step.expect([
            .init("granted-screen", "Screen Recording", "granted to THIS bundle identity",
                  reds: [.init("the grant, not the process",
                               "run this exec'd instead of via open: the precondition above fires "
                               + "and names the other identity")]),
            .init("granted-input", "Input Monitoring", "granted to THIS bundle identity",
                  reds: [.init("the grant", "deny it in the dialog: status reads denied, not granted")]),
            .init("granted-ax", "Accessibility", "granted to THIS bundle identity",
                  reds: [.init("the grant", "remove the entry from the pane and re-run: notGranted")]),
        ])

        _ = CGRequestScreenCaptureAccess()
        // The key is spelled rather than read from `kAXTrustedCheckOptionPrompt`,
        // which Swift 6 rejects as shared mutable state. The literal is what
        // that global holds; ApplicationServices documents it as
        // "AXTrustedCheckOptionPrompt".
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        print("\nIf dialogs appeared, answer them, then QUIT AND RE-RUN THIS — a grant does not "
              + "apply to a process that is already running.\n")
        print(CapturePermissions.dumpText())

        step.check("granted-screen", "Screen Recording is granted to this identity",
                   CapturePermissions.status(of: .screenRecording) == .granted)
        step.check("granted-input", "Input Monitoring is granted to this identity",
                   CapturePermissions.status(of: .inputMonitoring) == .granted)
        step.check("granted-ax", "Accessibility is granted to this identity",
                   CapturePermissions.status(of: .accessibility) == .granted)
        step.finish(remedy: "Grant what is missing in System Settings, then QUIT and re-run this "
                            + "launch. Only when all three are green does the measuring launch have "
                            + "a window that is not measuring your reaction time.")
    }

    // ---------------------------------------------------------------- shared

    /// Every human step prints these two before anything else it measures.
    ///
    /// **They are `given` rows, not expectations.** Both are read off the
    /// configuration at the moment they are printed — `type(of: source)` and
    /// `ObjectIdentifier(observer)` cannot disagree with themselves — so there
    /// is nothing here for a later assertion to be right or wrong about. Under
    /// the previous harness they were concatenated into `expect`, where the
    /// new guard would have named them undischarged in every step and the only
    /// ways out would have been a tautological check or a weaker guard.
    ///
    /// **The AX source**, because `LiveAXElementSource` has never executed —
    /// every § 8 probe check runs against the synthetic one, which answers the
    /// same role vocabulary (`AXButton`, `AXGroup`, `AXApplication`). Without
    /// this line "the human half passed" and "the human half passed against a
    /// fixture" are the same sentence in the record.
    ///
    /// **The observer's object identity**, because the question these steps
    /// answer is whether the PRODUCT's detector works — not whether a
    /// structurally identical copy does. Printing the identity of the instance
    /// whose diagnostics are read, beside the identity of the instance that
    /// owns the tap, makes "same object" checkable rather than assumed. An
    /// injectable seam is an opportunity to verify the wrong implementation,
    /// and this is the cheapest way to show which one was verified.
    @MainActor
    static func subjectLines(_ observer: InputObserver, _ source: some AXElementSource) -> [(String, String)] {
        [("AX source", "\(String(describing: type(of: source))) — the value passed in, not a literal"),
         ("observer identity", "\(ObjectIdentifier(observer)) — the instance that owns the tap AND "
                               + "whose diagnostics are read below; one object, not two")]
    }

    /// Runs an observer for `seconds`, beeping the window, letting the caller
    /// act at a chosen second. Output goes nowhere but stdout.
    @MainActor
    static func observe(_ observer: InputObserver, seconds: Int,
                        at moment: Int? = nil, act: (() -> Void)? = nil) {
        VerificationStep.beepStart()
        for elapsed in 0..<seconds {
            CFRunLoopRunInMode(.defaultMode, 1, false)
            if elapsed == moment { act?() }
        }
        VerificationStep.beepStop()
    }

    // ------------------------------------------- step 1: the real port down

    /// **The positive control for `stall`, and it must run first.**
    ///
    /// `disableTapForVerification()` takes a real `CFMachPort` down through
    /// `CGEventTapEnable`, the same mechanism the OS uses, and returns the
    /// instant it did — so `T_off` is *known*. That is what this step buys and
    /// a timeout-induced disable cannot: with `T_off` known, "the poll did not
    /// find it" has exactly one explanation, and the window's **edges** are
    /// assertable rather than only its non-emptiness. The left edge is the part
    /// of the arithmetic nothing has ever exercised.
    ///
    /// Run `stall` first and a null result cannot tell "the OS did not disable
    /// the tap" from "our detector did not see it".
    @MainActor
    static func theRealPortGoesDown() {
        var step = VerificationStep(name: "human 1 — the poll finds a REAL port going down")
        step.begin(repositoryPath: repositoryPath)
        let source = LiveAXElementSource()
        let observer = InputObserver(arrangement: InputObserver.currentArrangement(),
                                      epoch: Minting.bootEpoch())
        step.given(subjectLines(observer, source))
        // **This is the table the guard's own regression case replays.** As
        // first written it declared six rows and discharged one — the negative
        // control — and passed, because the old guard's output was a count.
        // `VerificationStep.selfTest()` runs those six identifiers against the
        // current guard and requires it to name the other five.
        //
        // `window-count` is new: "exactly one blind window" was asserted here
        // from the first version and never appeared in the table, so it was an
        // assertion with nothing to correspond to.
        // Bound out of the call so the type checker sees eight small
        // expressions rather than one large one — it timed out on the single
        // literal once the rows carried arrays.
        let rows: [VerificationStep.Expectation] = [
            .init("induced", "what is induced",
                  "CGEventTapEnable(tap, false) on the real port — T_off is KNOWN",
                  reds: [.init("the disable happened at all",
                               "return nil from disableTapForVerification without touching the "
                               + "port: offAt is nil and the step reports didNotHappen")]),
            .init("which-channel", "which channel",
                  "the NOTIFICATION one: a manual disable delivers kCGEventTapDisabledByUserInput. "
                  + "This step validates the EDGE arithmetic against ground truth, not the poll",
                  reds: [.init("our attribution of the channel",
                               "have the notification path record .enabledPoll / .timeout instead "
                               + "of what the OS reported: the assertion fails and names the guess"),
                         .init("the OS's behaviour — NOT WITNESSABLE HERE",
                               "no mutation in this repository makes the OS stop delivering "
                               + "kCGEventTapDisabledByUserInput. That half is a D6b row, not a red")]),
            .init("window-count", "how many windows",
                  "exactly 1 — a second window would mean the detector emits them on its own",
                  reds: [.init("the count",
                               "call disableTapForVerification twice, 200 ms apart: count is 2")]),
            .init("edges", "the assertion",
                  "the window's EDGES: interval.start <= T_off <= interval.end",
                  reds: [.init("the lower edge",
                               "have lowerBoundLocked() return observationBegan: containment STILL "
                               + "HOLDS and only the bound row fails — which is why they are two rows"),
                         .init("the upper edge",
                               "close the window at the poll BEFORE the one that found it: T_off "
                               + "falls after interval.end")]),
            .init("over-estimate-bound", "over-estimate bound",
                  "interval.duration <= the poll interval + slack",
                  reds: [.init("the bound's size",
                               "same mutation as `edges`'s lower one: the lead becomes seconds "
                               + "against a 100 ms interval. OBSERVED")]),
            .init("poll-pair", "empty vs unwatched",
                  "tapEnabledPolls > 0 — an empty window list means nothing without it",
                  reds: [.init("that anything polled",
                               "delete startPolling() from start(): polls read 0. This is the "
                               + "Critical the Task 10 re-review found")]),
            .init("delivery-resumed", "delivery resumed",
                  ">= 1 pointer sample stamped after interval.end",
                  reds: [.init("delivery, not the flag",
                               "drop CGEventTapEnable(true) from the re-arm path: the flag never "
                               + "recovers and no sample arrives after the window")]),
            .init("negative-control", "negative control",
                  "an equal window with NO disable: zero windows, non-zero polls",
                  reds: [.init("the detector does not emit windows on its own",
                               "emit a TapDisabledInterval on every poll: the clean window reports "
                               + "one and the control fails before the real run")]),
        ]
        step.expect(rows)

        // Collected, not discarded. The window itself arrives as
        // `.tapDisabled(TapDisabledInterval)` through this closure — the first
        // version of this step passed `{ _ in }`, threw the record away, and
        // then had nothing to assert the edges against.
        let collected = CollectedWindows()
        do { try observer.start(onObservation: { collected.append($0) }) }
        catch { step.preconditionFailed("InputObserver.start threw \(error) — Input Monitoring is "
                                        + "not granted to video.soredemo.SpikeA.") }

        // ---- negative control first: a clean window ----
        print("\n>>> NEGATIVE CONTROL — move the mouse for 6 s. Nothing will be disabled.")
        observe(observer, seconds: 6)
        let clean = observer.diagnostics
        print("    clean window: \(clean.tapDisabledIntervals) disabled window(s), "
              + "\(clean.tapEnabledPolls) polls")
        step.check("negative-control",
                   "NEGATIVE CONTROL: an undisturbed window produced ZERO disabled windows over "
                   + "\(clean.tapEnabledPolls) polls — so a window found below is a finding, not "
                   + "an instrument that emits them",
                   clean.tapDisabledIntervals == 0 && clean.tapEnabledPolls > 0)

        // ---- the induced disable ----
        print("\n>>> Now keep moving the mouse for 10 s. The port goes down at t+3s.")
        var offAt: HostInstant?
        let observeStart = Minting.hostNow().rawValue
        observe(observer, seconds: 10, at: 3) { offAt = observer.disableTapForVerification() }
        let observeEnd = Minting.hostNow().rawValue
        let after = observer.diagnostics
        observer.stop()

        guard let offAt else {
            step.didNotHappen("disableTapForVerification() returned nil — there was no live port, "
                              + "so nothing was taken down and nothing could be detected.")
        }
        print("    T_off = \(offAt.hostTime.rawValue) ns")
        print("    \(after.tapDisabledIntervals) window(s), \(after.tapEnabledPolls) polls over "
              + "\(Double(after.tapPollingSpanNanos) / 1e9) s")

        // **The assertions this step exists for.** The first version of it
        // printed the three numbers above and called `finish()` — so it passed
        // on the negative control alone, while the edges, the bound, the poll
        // pair and the resumed delivery were listed in the expectation table
        // and checked nowhere. Six expectations, one check. The harness's
        // "no assertions ran" guard did not catch that: there was one. The
        // guard now names the five, and `VerificationStep.selfTest()` proves it
        // does without needing a person or a port.

        // `induced`, which had no assertion at all — the `guard let offAt`
        // above turns a nil into `didNotHappen`, which is right, but a step
        // that reaches this line has ground truth and never said so.
        //
        // Not `offAt != nil` — reaching this line already establishes that, so
        // such an assertion could not fail, which is the shape this whole
        // change exists to remove. The checkable claim is that T_off lies
        // inside the window this process actually observed: a stamp from a
        // stale port, or one on a different clock base, lands outside it and
        // every edge assertion below would then be arithmetic on two unrelated
        // numbers.
        let offInsideRun = observeStart <= offAt.hostTime.rawValue
            && offAt.hostTime.rawValue <= observeEnd
        step.check("induced", "T_off is GROUND TRUTH and it is OUR ground truth: this process took "
                   + "the port down itself, and the returned instant "
                   + "\(offAt.hostTime.rawValue) ns falls inside the observed window "
                   + "[\(observeStart), \(observeEnd)] — same clock base, same run",
                   offInsideRun)
        let windows = collected.windows
        step.check("window-count", "exactly 1 blind window was recorded (observed \(windows.count))",
                   windows.count == 1)
        guard let window = windows.first else {
            step.finish(remedy: "No window means the poll never saw the port down.")
        }
        let start = window.interval.start.rawValue
        let end = window.interval.end.rawValue
        let off = offAt.hostTime.rawValue
        let pollNanos = InputObserver.pollIntervalNanos
        step.check("edges",
                   "the window CONTAINS T_off: start \(start) <= \(off) <= end \(end). This is "
                   + "the edge assertion — a window that merely exists proves the poll fired, not "
                   + "that it bracketed the event",
                   start <= off && off <= end)
        let leadMs = String(format: "%.1f", Double(off - start) / 1e6)
        let pollMs = String(format: "%.1f", Double(pollNanos) / 1e6)
        let boundHolds = (off - start) <= pollNanos * 2
        step.check("over-estimate-bound",
                   "the over-estimate is bounded by the POLLING RATE, not by the run: T_off - start "
                   + "= \(leadMs) ms against a \(pollMs) ms poll interval. A left edge that "
                   + "drifted back to the start of observation would pass containment and fail this",
                   boundHolds)
        // **Measured, and it changes what this step is for.**
        //
        // `CGEventTapEnable(tap, false)` from inside the process delivers
        // `kCGEventTapDisabledByUserInput` — the callback receives it, so the
        // window is found by the NOTIFICATION channel, not by the poll. The
        // 0.5 ms lead above is the notification's speed; a poll-detected window
        // would show a lead approaching the 100 ms interval.
        //
        // So this step does NOT exercise polling, which was its assumed
        // purpose. A manual disable and a `.listenOnly` timeout are NOT
        // interchangeable to the detector: Spike C step 5 measured that a
        // timeout delivers no notification at all. What this step does prove is
        // the part that needs ground truth — the window's edge arithmetic
        // against a known T_off — and that the notification path attributes
        // honestly rather than guessing.
        //
        // The consequence: step 2 (`stall`) is the only thing that can
        // exercise the poll, which moves it from confirmatory to load-bearing.
        let detection = "\(window.detectedBy) / \(String(describing: window.disabledBy))"
        let honest = window.detectedBy == .notification && window.disabledBy == .userInput
        step.check("which-channel",
                   "a manual CGEventTapEnable(false) is detected by the NOTIFICATION channel and "
                   + "attributed as \(detection) — the OS calls it userInput, and the observer "
                   + "records what it was told rather than guessing .timeout. This step therefore "
                   + "does NOT exercise polling; only a .listenOnly timeout can, because that is "
                   + "the case with no notification (Spike C step 5)",
                   honest)
        step.check("poll-pair",
                   "something was looking: \(after.tapEnabledPolls) polls. An empty window list "
                   + "means nothing without this, and a non-empty one is only readable with it",
                   after.tapEnabledPolls > 0)
        let resumed = collected.pointerInstantsAfter(end)
        step.check("delivery-resumed",
                   "delivery RESUMED: \(resumed) pointer samples stamped after the window closed. "
                   + "'Re-armed' must mean events arriving again, not a flag reading true",
                   resumed > 0)
        step.finish(remedy: "If windows climb every 100 ms and never stop, the re-arm's "
                            + "CGEventTapEnable is not taking effect from the poll queue — that "
                            + "reads as a detector working extremely well and is the opposite.")
    }

    // ------------------------------- step 2: a real OS timeout, no product seam

    /// A real timeout-induced disable, with **no seam in the product at all**:
    /// the stall goes in this spike's own observation closure, which is the
    /// recipe Spike C step 5 proved reliably disables a `.listenOnly` tap
    /// (every `mouseMoved`, 50 ms — sustained overload, not a per-click cost).
    ///
    /// Runs second, because step 1 establishes that the detector finds a port
    /// that is known to be down.
    @MainActor
    static func aRealTimeoutDisable() {
        var step = VerificationStep(name: "human 2 — the poll finds a REAL OS timeout disable")
        step.begin(repositoryPath: repositoryPath)
        let source = LiveAXElementSource()
        let observer = InputObserver(arrangement: InputObserver.currentArrangement(),
                                      epoch: Minting.bootEpoch())
        step.given(subjectLines(observer, source) + [
            ("why second", "step 1 already showed the poll finds a port known to be down, so a "
                           + "null here means the OS did not disable it — one explanation, not two"),
        ])
        // Two of the five rows this step used to declare were conjunctions,
        // and each had an unchecked half: "detectedBy == .enabledPoll,
        // disabledBy == nil" was discharged by an assertion about the first
        // clause only, and "tapEnabledPolls > 0, and the run survives" by one
        // about the first. Split, so the guard can see the halves.
        step.expect([
            .init("induced-stall-applied", "what is induced",
                  "a real OS timeout — 50 ms of sleep in THIS SPIKE's observation "
                  + "closure, on every pointer event. No product seam. The stall must be "
                  + "shown to have RUN: a window found without it is a different finding"),
            .init("poll-found", "found by the poll",
                  ">= 1 window with detectedBy == .enabledPoll — the path that had "
                  + "never once run against a real CFMachPort"),
            .init("poll-attribution", "a poll cannot know why",
                  "disabledBy == nil on the poll-found windows: the flag says the tap is "
                  + "off and nothing more, so an attribution here would be a guess "
                  + "recorded as a measurement"),
            .init("poll-pair", "empty vs unwatched",
                  "tapEnabledPolls > 0 — an empty window list means nothing without it"),
            .init("tap-rearms", "the run survives",
                  "> 1 window: a second window is only reachable through a successful "
                  + "re-arm, so the count is the evidence that the tap came back rather "
                  + "than a flag read after the fact"),
            .init("rearm-loop", "expected side effect",
                  "the stall NEVER stops, so the cause PERSISTS: expect a re-arm "
                  + "loop, many windows, and most of the span recorded blind. "
                  + "That is the condition the re-arm note called unmeasured"),
        ])

        // Counted, so "the stall was applied" stops being an assumption. A run
        // where no pointer event arrives performs no stall, and every number
        // below would then be about a tap nobody overloaded.
        let stalls = StallCounter()
        // Collected, not discarded — for the same reason step 1 stopped
        // discarding them: `disabledBy` lives on the window, and the diagnostics
        // counters can only say how many there were.
        let collectedStallWindows = CollectedWindows()
        do {
            try observer.start(onObservation: { observation in
                collectedStallWindows.append(observation)
                // The overload, in the spike, not in the product.
                stalls.count()
                usleep(50_000)
            })
        } catch {
            step.preconditionFailed("InputObserver.start threw \(error) — Input Monitoring is not "
                                    + "granted to video.soredemo.SpikeA.")
        }
        // **The cursor will NOT feel laggy, and that is the point.** A
        // `.listenOnly` tap is not in the delivery path — it only listens — so
        // its callback falling behind does not slow the cursor by one
        // millisecond. Only OUR observation falls behind. The instruction here
        // originally said "it will feel very laggy", carried over from Spike C
        // step 5's `.defaultTap` control, which IS in the delivery path and
        // does freeze the machine. The operator noticed the discrepancy.
        //
        // It sharpens the finding rather than softening it: when a listen-only
        // tap is disabled, the cursor is normal, no notification is delivered
        // (measured), and nothing is visible to anyone. The pointer track just
        // stops. That is why polling is the only detection, and why a bare
        // count of disables was never going to be enough.
        print("\n>>> Move the cursor CONTINUOUSLY for 10 s.")
        print("    The cursor will feel NORMAL — a .listenOnly tap is not in the delivery path, so "
              + "our callback falling behind does not slow it. That is exactly why a disabled tap "
              + "is invisible without polling.")
        print("    Wall clock will be much longer than 10 s: every event is stalled 50 ms, so the "
              + "run loop overruns its own timeout by up to that on each pass. The previous run "
              + "spanned 144 s for a 20 s window.")
        observe(observer, seconds: 10)
        let d = observer.diagnostics
        observer.stop()
        print("    \(d.tapDisabledIntervals) window(s), found by polling: "
              + "\(d.tapDisabledIntervalsFoundByPolling), \(d.tapEnabledPolls) polls, "
              + "blind \(Double(d.tapBlindNanos) / 1e9) s")
        guard d.tapDisabledIntervals > 0 else {
            step.didNotHappen("no window was recorded. Step 1 established the detector finds a "
                              + "port that is down, so this is the OS not having disabled the tap "
                              + "— 20 s of 50 ms stalls was not enough overload, or the mouse was "
                              + "not moving. Polls: \(d.tapEnabledPolls).")
        }
        let byPoll = d.tapDisabledIntervalsFoundByPolling
        let total = d.tapDisabledIntervals
        // Not "every window", which the first version asserted. A notification
        // does arrive sometimes — step 1 measured that a manual disable is
        // reported as `.userInput` through that channel — so a handful of
        // notification-found windows in a long run is the OS being consistent,
        // not a defect. What matters is that the POLL found them, because the
        // poll is the path that had never executed against a real port.
        step.check("induced-stall-applied",
                   "the overload RAN: \(stalls.performed) observations were each stalled 50 ms, "
                   + "which is \(String(format: "%.1f", Double(stalls.performed) * 0.05)) s of "
                   + "deliberate lateness. A run where the mouse did not move performs zero stalls "
                   + "and every window below would then be about something else",
                   stalls.performed > 0)
        step.check("poll-found",
                   "the POLL found \(byPoll) of \(total) windows — the path that had never once "
                   + "run against a real CFMachPort. A .listenOnly timeout delivers no notification "
                   + "(Spike C step 5), so without the poll these would all be silence",
                   byPoll > 0 && Double(byPoll) / Double(max(total, 1)) > 0.9)
        // The half of the old "the assertion" row that was declared and never
        // checked. A poll reads a boolean flag; it has no access to a reason,
        // so anything other than `nil` here is the observer inventing one.
        let pollFound = collectedStallWindows.windows.filter { $0.detectedBy == .enabledPoll }
        let attributed = pollFound.filter { $0.disabledBy != nil }
        step.check("poll-attribution",
                   "\(attributed.count) of \(pollFound.count) poll-found windows carry a "
                   + "disabledBy attribution — a poll reads a flag and learns nothing about why, so "
                   + "any value here would be a guess recorded in the same field the notification "
                   + "channel fills with fact"
                   + (pollFound.isEmpty ? ". VACUOUS ON THIS RUN: no window was poll-found" : ""),
                   !pollFound.isEmpty && attributed.isEmpty)
        step.check("poll-pair",
                   "something was looking: \(d.tapEnabledPolls) polls over "
                   + "\(String(format: "%.1f", Double(d.tapPollingSpanNanos) / 1e9)) s",
                   d.tapEnabledPolls > 0)
        step.check("tap-rearms",
                   "the tap CAME BACK: \(total) windows were recorded, and every window after the "
                   + "first is only reachable through a re-arm that took effect. A tap that was "
                   + "disabled once and never re-armed produces exactly one window and then silence "
                   + "for the rest of the run",
                   total > 1)

        // **The case the re-arm note called unmeasured, now measured.** The
        // stall is never switched off here, so the cause persists: the tap is
        // re-armed and immediately disabled again. The re-review predicted
        // exactly this — "a 10 Hz re-arm loop emitting a window every 100 ms" —
        // and it is the only condition that would justify backoff.
        //
        // It is NOT the failure mode where a CGEventTapEnable from the poll
        // queue does not take effect. Step 1 separates those: after its re-arm,
        // 854 pointer samples arrived. Delivery resumes; the cause returns.
        let blindFraction = Double(d.tapBlindNanos) / Double(max(d.tapPollingSpanNanos, 1))
        let windowsPerSecond = Double(total) / (Double(max(d.tapPollingSpanNanos, 1)) / 1e9)
        step.check("rearm-loop",
                   String(format: "under a PERSISTENT cause the detector becomes a re-arm loop: "
                          + "%.1f windows per second, %.0f%% of the span recorded as blind. This is "
                          + "the condition the re-arm note called unmeasured, and the only one that "
                          + "would justify backoff — it is now a number",
                          windowsPerSecond, blindFraction * 100),
                   windowsPerSecond > 1 && blindFraction > 0.5)
        step.finish()
    }

    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--permissions") {
            // Printed WITH the command that produced it. "which grants does this
            // identity hold" is a derived value with a short life — the next
            // re-sign or path change makes it wrong — and this project's rule is
            // that a derived value carries its origin. A conclusion pasted into a
            // report outlives the state it described; a command does not.
            print("$ \(CommandLine.arguments.first ?? "?") --permissions")
            print("(re-run this rather than trusting a transcript — a re-sign or a moved")
            print(" path invalidates every line below without changing any of them)\n")
            if CommandLine.arguments.contains("--dump-env") {
                let env = ProcessInfo.processInfo.environment
                let dump = env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
                if let i = CommandLine.arguments.firstIndex(of: "--permissions-to"),
                   i + 1 < CommandLine.arguments.count {
                    try? dump.write(toFile: CommandLine.arguments[i + 1],
                                    atomically: true, encoding: .utf8)
                }
                print(dump)
                exit(0)
            }
            let text = CapturePermissions.dumpText()
            print(text)
            // Also to a file, because the discriminating measurement needs the
            // OTHER launch path: `open` starts the app through LaunchServices,
            // which makes launchd the responsible process, and an LSUIElement
            // app started that way has no stdout anyone can read. Comparing the
            // two answers is how "this bundle holds the grant" is told from
            // "TCC attributed it up the chain to whatever launched it" — the
            // failure that once reported four greens for a terminal.
            if let i = CommandLine.arguments.firstIndex(of: "--permissions-to"),
               i + 1 < CommandLine.arguments.count {
                try? text.write(toFile: CommandLine.arguments[i + 1],
                                atomically: true, encoding: .utf8)
            }
            exit(0)
        }
        switch CommandLine.arguments.dropFirst().first {
        // The guard's own regression case. No permission, no hardware, no
        // operator — so it is the one thing in this file that can be run on
        // every build rather than by a person at the machine, which is exactly
        // what the previous guard's failure case could not be.
        case "--self-test": VerificationStep.selfTest()
        case "--dry-run": dryRun()
        case "grant": acquireGrants(); return
        case "tapdown": theRealPortGoesDown(); return
        case "stall": aRealTimeoutDisable(); return
        default: break
        }
        let seconds = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 45
        var step = VerificationStep(name: "Spike A — pairing latency against the real AXObserver")
        step.begin(repositoryPath: repositoryPath)

        // **Bound here and passed explicitly, so the name printed below comes
        // from the value that produced the numbers.**
        //
        // `chain(at:)` would hardcode the live source and the output would say
        // so from a string literal — an unearned claim of exactly the class
        // this spike exists to avoid making. It matters because the printed
        // role vocabulary does not distinguish the two: the synthetic source
        // in the probe answers `AXButton`, `AXGroup` and `AXApplication` too,
        // so "PASS" and "PASS against a fixture" would otherwise be
        // indistinguishable in the record. Today only one conformer exists;
        // the print is derived rather than asserted so it stays true when a
        // second one does.
        let axSource = LiveAXElementSource()
        let arrangement = InputObserver.currentArrangement()
        step.given([
            ("AX source", "\(String(describing: type(of: axSource))) — the value passed to "
                          + "enqueue(_:source:onRecord:) below, not a literal"),
            ("depth cap", "\(AXObserver.depthCap) — fixed (D2-5), expected to bind only on web content"),
            ("walk budget", "\(Double(AXObserver.walkBudgetNanos) / 1e6) ms — a D4 PLACEHOLDER"),
            ("displays", "\(arrangement.placements.count) in the arrangement under test"),
        ])
        // Five rows below are new, and each was already an assertion with
        // nothing to correspond to: the chains-recorded floor, the click
        // accounting, the truncation reason, the containment verdict and the
        // monotonic clock were all checked and none was declared. That is the
        // size of the gap in this step — five of thirteen — and it is the
        // number this change exists to expose rather than to fix quietly.
        //
        // "tap poll" was one row making two claims (non-zero, and covering the
        // window) with two assertions; split, so an assertion cannot discharge
        // the half it does not test.
        step.expect(f2_2.map {
            .init($0.id, $0.name, String(format: "p50 %.2f  p90 %.2f  max %.2f  (F2-2, 118 samples)",
                                         $0.p50, $0.p90, $0.max))
        } + [
            .init("induced-chains-recorded", "chains recorded",
                  "> 0 — a run with no chain is didNotHappen, and every distribution "
                  + "below would otherwise be a percentile of the empty set"),
            .init("clicks-accounted", "click accounting",
                  "every click reaching the observer is recorded, dropped or truncated "
                  + "with a reason, and the totals reconcile — AXObserver.Diagnostics "
                  + ".everyClickIsAccountedFor"),
            .init("truncation-reason", "truncation reasons",
                  "every record carries exactly one of the four F2-3 reasons; a record "
                  + "with none left the walk by a path nothing counts"),
            .init("containment-verdict", "containment verdicts",
                  "every record carries exactly one containment verdict — the denominator "
                  + "the containment row below is a fraction of"),
            .init("containment", "containment",
                  "NOT all clicks outside their element — a uniform miss is the "
                  + "coordinate path, not AX staleness"),
            .init("monotonic-clock", "monotonic clock",
                  "0 intervals measured backwards; a negative duration would make every "
                  + "percentile above meaningless without making any of them look wrong"),
            .init("tap-poll-nonzero", "tap poll fired",
                  "non-zero — an unpolled run cannot tell 'no blind windows' from "
                  + "'nothing was looking'"),
            .init("tap-poll-span", "tap poll covered the run",
                  "> 50% of the observation window — a timer that fires twice and dies "
                  + "satisfies a non-zero count while covering none of the run"),
            .init("blind-windows", "blind windows",
                  "any found are expected to say detectedBy: enabledPoll — the "
                  + "notification is measured never to arrive for a .listenOnly tap"),
        ])

        controlRow(step, arrangement)
        guard CapturePermissions.status(of: .accessibility) == .granted else {
            step.preconditionFailed("""
            Accessibility is not granted to this bundle (video.soredemo.SpikeA). \
            CapturePermissions reports: \(CapturePermissions.status(of: .accessibility)). \
            Every hit-test would return nothing and the run would measure the permission, \
            not the pairing. System Settings → Privacy & Security → Accessibility.
            """)
        }

        // ---- the run
        let epoch = Minting.bootEpoch()
        let samples = Samples()
        let axObserver = AXObserver(arrangement: arrangement, epoch: epoch)
        let inputObserver = InputObserver(arrangement: arrangement, epoch: epoch)
        let out = openLog()

        do {
            try inputObserver.start { observation in
                // The tap-disabled interval is an observation too, and it is
                // the one that says a stretch of this run was not observed at
                // all. Collected before the click filter, so a window that
                // arrives between clicks is not dropped on the floor.
                if case .tapDisabled(let window) = observation {
                    samples.appendBlindWindow(window)
                    if let line = try? ObservationLog.encode(window) {
                        out?.write(line); out?.write(Data("\n".utf8))
                    }
                    return
                }
                // `.down` only. The verb half of "click the Save button" is
                // the press; hit-testing the release as well would double the
                // AX cost for a second answer to the same question.
                guard case .button(let event) = observation, event.phase == .down else { return }
                samples.countClick()
                // **`enqueue`, not `chain`.** This closure runs inside the tap
                // callback. A slow callback does not by itself disable the tap
                // — measured, 125 ms on clicks only, 18 stalls over 30 s,
                // does not — but a target that HANGS would take the tap down with
                // it, and with it the whole pointer track this spike is also
                // measuring. Behind the queue the same hang costs the AX
                // chains of the affected clicks, counted. See `AXObserver`'s
                // header; the asymmetry is the reason, not a time budget.
                axObserver.enqueue(event, source: axSource) { record in
                    samples.append(record)
                    if let line = try? ObservationLog.encode(record) {
                        out?.write(line); out?.write(Data("\n".utf8))
                    }
                }
            }
        } catch CaptureError.inputMonitoringUnavailable {
            step.preconditionFailed("""
            CGEvent.tapCreate returned nil — Input Monitoring is not granted to this bundle \
            (video.soredemo.SpikeA), or it is granted to a previous build with a different \
            signature. CapturePermissions reports: \
            \(CapturePermissions.status(of: .inputMonitoring)). This is NOT 'no clicks happened'.
            """)
        } catch {
            step.preconditionFailed("InputObserver.start threw \(error)")
        }

        step.humanWindow(seconds, """
            Click on things — a native AppKit app, an Electron app (Slack, VS Code), and \
            something known to be slow. Click DURING animations: open a menu and click an item \
            while it is still appearing, click the Dock while it is moving, click inside web \
            content while it is scrolling. \(seconds)s.
            """)
        inputObserver.stop()
        // Clicks land on the AX queue and are answered there, so a run that
        // reads its records the instant the window closes is missing whatever
        // was still in flight — and would report it as a shorter click list.
        axObserver.waitForQueuedClicks()
        out?.closeFile()

        // ---- what came back
        let records = samples.records
        let diagnostics = axObserver.diagnostics
        guard !records.isEmpty else {
            step.didNotHappen("""
            \(samples.clicksSeen) clicks reached the observer and \(records.count) chains were \
            recorded. \(diagnostics.accounting)
            """)
        }

        let hitTestMs = records.map { Double($0.hitTestInterval.duration.rawValue) / 1e6 }
        let walkMs = records.map { wholeWalkNanos(of: $0) / 1e6 }
        let calls = records.map { Double($0.axCalls) }
        let depths = records.map { Double($0.ancestors.count) }
        // Paired to `f2_2` by position, so the id an assertion cites and the id
        // its expectation declared come from the same element of the same
        // array. `zip` rather than a lookup by name: a name lookup is two
        // strings that have to agree, which is the failure mode a mechanical
        // migration produces on every call site at once.
        let measured: [(id: String, name: String, values: [Double])] =
            zip(f2_2, [hitTestMs, walkMs, calls, depths]).map { ($0.id, $0.name, $1) }

        print("\n---- MEASURED, \(records.count) samples on this machine ----")
        print("  AX source: \(String(describing: type(of: axSource)))"
              + " — read off the value handed to enqueue(_:source:onRecord:), not written down")
        func column(_ text: String, _ width: Int) -> String {
            text.count >= width ? text
                : String(repeating: " ", count: width - text.count) + text
        }
        print("  " + column("", 22) + column("p50", 9) + column("p90", 9) + column("max", 9)
              + "   " + column("F2-2 p50", 9) + column("p90", 9) + column("max", 9))
        for (id, name, values) in measured {
            let reference = f2_2.first { $0.id == id }!
            let cells = [percentile(values, 0.50), percentile(values, 0.90), values.max() ?? 0,
                         reference.p50, reference.p90, reference.max]
                .map { column(String(format: "%.2f", $0), 9) }
            print("  " + name.padding(toLength: 22, withPad: " ", startingAt: 0)
                  + cells[0] + cells[1] + cells[2] + "   " + cells[3] + cells[4] + cells[5])
        }
        print("  a 60 fps frame is 16.67 ms; the whole walk at p90 is "
              + String(format: "%.1f frames", percentile(walkMs, 0.90) / 16.67))
        print("\n---- truncation, and where the chains topped out (F2-3) ----")
        for reason in [ChainTruncation.reachedRoot, .depthCapReached, .budgetExceeded,
                       .hitTestReturnedNothing] {
            let matching = records.filter { $0.truncation == reason }
            guard !matching.isEmpty else { continue }
            let tops = Dictionary(grouping: matching.compactMap { $0.ancestors.last?.role ?? $0.hit?.role },
                                  by: { $0 })
                .map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: ", ")
            print("  \(reason.rawValue): \(matching.count) — tops: \(tops)")
        }
        // The deferral this run paid to keep the tap alive, as a distribution
        // rather than an assurance.
        let queueMs = records.compactMap { $0.clickToHitTestStartNanos }.map { Double($0) / 1e6 }
        if !queueMs.isEmpty {
            print(String(format: "  click → AX queue pickup:  p50 %.2f  p90 %.2f  max %.2f ms",
                         percentile(queueMs, 0.50), percentile(queueMs, 0.90), queueMs.max() ?? 0))
            print("  (the price of moving AX off the callback thread. It is added to every "
                  + "hit-test's staleness and it is recorded, not absorbed.)")
        }

        print("\n---- diagnostics ----")
        print("  " + diagnostics.accounting.replacingOccurrences(of: "\n", with: "\n  "))
        let tap = inputObserver.diagnostics
        print("  " + tap.tapAccounting.replacingOccurrences(of: "\n", with: "\n  "))
        for window in samples.blindWindows {
            print(String(format: "    blind window %.1f ms, found by %@, lower bound %@, reason %@",
                         Double(window.interval.duration.rawValue) / 1e6,
                         window.detectedBy.rawValue, window.lowerBoundFrom.rawValue,
                         window.disabledBy?.rawValue ?? "not reported"))
        }
        print("  AX log: \(logURL.path()) — NOT to be committed; it carries window titles.")

        // ---- the checks
        step.check("induced-chains-recorded",
                   "\(records.count) chains recorded from \(samples.clicksSeen) clicks",
                   records.count > 0)
        step.check("clicks-accounted",
                   "every click is accounted for — \(diagnostics.accounting.split(separator: "\n")[0])",
                   diagnostics.everyClickIsAccountedFor)
        step.check("truncation-reason", "every record carries one truncation reason",
                   diagnostics.everyRecordHasATruncationReason)
        step.check("containment-verdict", "every record carries one containment verdict",
                   diagnostics.everyRecordHasAContainmentVerdict)

        // **The coordinate check, stated as what it can actually rule out.**
        // Some proportion of clicks legitimately miss: AX is stale during
        // animation, which is what this run is deliberately provoking. What
        // cannot legitimately happen is ALL of them missing — that is the
        // reverse conversion being wrong, and it is the one shape a plausible
        // AX explanation does not cover.
        step.check("containment", """
                   \(diagnostics.clickInsideTheHitFrame) of \(diagnostics.chainsRecorded) clicks fell \
                   inside the element the hit-test returned, \(diagnostics.clickOutsideTheHitFrame) \
                   outside, \(diagnostics.clickFrameNotComparable) not comparable, \
                   \(diagnostics.recordsWithNoFrame) with no frame — not all of them missed
                   """,
                   diagnostics.clickOutsideTheHitFrame < diagnostics.chainsRecorded)
        step.check("monotonic-clock",
                   "no interval was measured backwards (\(diagnostics.nonMonotonicClockReadings))",
                   diagnostics.nonMonotonicClockReadings == 0)

        // **Evidence of looking, ASSERTED — printing it is not enough, and
        // this file printed it and nothing else for one round.**
        //
        // Without these two, a run where the poll timer never fires (a starved
        // queue, or `startPolling()` not reached at all) prints
        // `tap enabled polls : 0 over 0.0 s  ← NOTHING WAS LOOKING` and then
        // reports PASS, because nothing reads it. This is the only place on
        // real hardware where "something was looking" can be established at
        // all, so it is the one place it must be able to fail.
        step.check("tap-poll-nonzero", """
                   \(tap.tapEnabledPolls) polls of the tap's own enabled flag over \
                   \(String(format: "%.1f", Double(tap.tapPollingSpanNanos) / 1e9)) s — so \
                   "\(tap.tapDisabledIntervals) blind windows" is a measurement and not a silence
                   """,
                   tap.tapEnabledPolls > 0)
        // The span, separately: a timer that fires twice and dies satisfies
        // the count above while covering none of the run.
        let windowNanos = Double(seconds) * 1e9
        let covered = windowNanos > 0 ? Double(tap.tapPollingSpanNanos) / windowNanos : 0
        step.check("tap-poll-span", """
                   the polling spanned \(String(format: "%.0f", covered * 100))% of the \
                   \(seconds)s observation window — a poll that stopped early cannot see what \
                   happened after it, and its count would still look healthy
                   """,
                   covered > 0.5)
        // Every blind window this run found should have come from the poll:
        // the notification is measured never to arrive for a .listenOnly tap.
        // Zero windows makes this vacuously true, which is why the two checks
        // above have to pass first for it to mean anything.
        step.check("blind-windows", """
                   \(samples.blindWindows.filter { $0.detectedBy == .enabledPoll }.count) of \
                   \(samples.blindWindows.count) blind windows were found by the poll rather than \
                   by a notification that a .listenOnly tap does not receive
                   """,
                   samples.blindWindows.allSatisfy { $0.detectedBy == .enabledPoll })

        // Order of magnitude, not equality. F2-2 is one machine, one session,
        // an uncontrolled app mix; D4 still applies and this is not a
        // calibration. What a 10× divergence would mean is that the shipping
        // observer does substantially more work per click than the inline walk
        // the bounds were fitted to, which is the question this re-run exists
        // to answer.
        for (id, name, values) in measured {
            let reference = f2_2.first { $0.id == id }!
            let mine = percentile(values, 0.50)
            let ratio = reference.p50 == 0 ? 1 : mine / reference.p50
            step.check(id,
                       String(format: "%@ p50 %.2f against F2-2's %.2f — ratio %.2f, within 10×",
                              name, mine, reference.p50, ratio),
                       ratio > 0.1 && ratio < 10)
        }

        step.finish(remedy: """
        A p50 an order of magnitude above F2-2's means AXObserver is doing more work per click \
        than the inline walk F2-2 measured — compare `axCalls` first, which is exact.

        IF EVERY CLICK LANDED OUTSIDE ITS ELEMENT, start from what this run already proved. The \
        control above took a point on this machine's own main display through the forward \
        conversion and back through AXObserver.globalPoint and got the same coordinate, and it \
        exits before measuring anything if it does not. So the two conversions ARE mutually \
        inverse on this arrangement, and auditing globalPoint is auditing code this run has \
        already exercised. (Probe § 8.1 says the same thing against a fixture, and would be green \
        either way — it never touches this machine's arrangement.)

        Two causes survive that control, and they are distinguishable:

          (i)  kAXPositionAttribute is not in the space this code assumes. AXObserver treats an \
               element frame as GLOBAL, TOP-LEFT POINTS — the same space CGEventGetLocation \
               reports in. If a target reports window-relative or bottom-left coordinates \
               instead, the hit-test is asked at the right place and the frame comes back \
               describing somewhere else.
          (ii) Forward and reverse are inverse to each other and both wrong against the real \
               display. A composition can be an identity and still map to the wrong point: a \
               scale from currentArrangement() that does not match the display's actual mode \
               cancels exactly in the round trip. The control cannot see this — it validates the \
               composition, not either half.

        THE MEASUREMENT THAT SEPARATES THEM, at a known screen landmark: click something whose \
        real position you can state independently — the close button of a window you have just \
        placed at a known origin, or a menu bar item — and read the record's hit.frame beside its \
        clickPosition. Both are NormalizedFrame/NormalizedPoint on the same display, so compare \
        them directly against the landmark's true fraction of the screen:

          * clickPosition is right for the landmark and hit.frame is not  ->  (i). The click was \
            converted correctly; the AX frame is in a space this code does not handle. Confirm by \
            reading hitTestGlobalX/Y from the record: it will be the correct global point.
          * clickPosition is ALSO wrong for the landmark, by a constant factor (the display scale) \
            or a constant offset (its global origin)  ->  (ii). Check currentArrangement()'s \
            scale against CGDisplayCopyDisplayMode's pixelWidth/width for that display; probe \
            § 7.8 pins those two derivations against each other but only for the display it can \
            reach.

        A landmark is required for this and the control cannot supply one: nothing this process \
        can compute knows where anything on screen actually is.
        """)
    }

    // MARK: -

    /// Hit-test start to the last attribute read of the whole observation —
    /// the "chain that never simultaneously existed" span (F2-2 § 3), computed
    /// from the record rather than measured separately, so it is the same
    /// number a reader of the log would get.
    static func wholeWalkNanos(of record: AXChainRecord) -> Double {
        let ends = ([record.hit] + record.ancestors.map { $0 } + (record.children ?? []).map { $0 })
            .compactMap { $0?.readInterval.end.rawValue }
        let last = ends.max() ?? record.hitTestInterval.end.rawValue
        return Double(last - record.hitTestInterval.start.rawValue)
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[index]
    }

    static let logURL = URL(filePath: NSHomeDirectory()).appending(path: "soredemo-spike-a.jsonl")

    static func openLog() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: logURL.path()) {
            FileManager.default.createFile(atPath: logURL.path(), contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: logURL.path())
        handle?.seekToEndOfFile()
        return handle
    }

    /// A row whose answer is known independently of anything under test — and
    /// deliberately, the *coordinate* half rather than the AX half.
    ///
    /// The forward conversion was verified against real hardware in Task 9;
    /// this reverses it and lands back on the point it started from. If that
    /// fails, every hit-test below is performed at the wrong place and every
    /// number this run prints is about the wrong element — which would
    /// otherwise present as "AX returned the wrong thing", the explanation
    /// F2-2 makes credible and this control exists to remove.
    @MainActor
    static func controlRow(_ step: VerificationStep, _ arrangement: DisplayArrangement) {
        guard let screen = NSScreen.main else {
            step.preconditionFailed("NSScreen.main is nil; there is no independent source to check against")
        }
        // A point a third of the way across the main screen — not its centre
        // and not its origin, both of which are fixed points of some wrong
        // conversions.
        let globalX = (screen.frame.width / 3).rounded()
        let globalY = (screen.frame.height / 4).rounded()
        guard let forward = InputObserver.normalizedPosition(globalTopLeftX: globalX,
                                                             globalTopLeftY: globalY,
                                                             in: arrangement) else {
            step.preconditionFailed("(\(globalX), \(globalY)) is on no display in the arrangement")
        }
        let back = AXObserver.globalPoint(of: forward.position, revision: forward.revision,
                                          in: arrangement)
        step.control("a global point through the forward conversion and back, on this machine's own display",
                     expected: "(\(globalX), \(globalY))",
                     observed: back.map { "(\($0.x), \($0.y))" } ?? "nil")
    }
}
