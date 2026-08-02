import CoreFoundation
import Foundation

/// The shared skeleton every human-in-the-loop verification step in this
/// project turned out to need.
///
/// **Why this exists.** Tasks 6, 7 and 8 each grew the same three things
/// independently — an identity block, an expectation table written before the
/// run, and a positive control that has to pass before anything below it is
/// readable — and four more manual steps are coming. Each was arrived at the
/// same way: by a verification producing a confident, wrong report, and the
/// fix being generalised afterwards. They are not decoration. Every one of
/// them has caught something:
///
///   * the **identity block** caught a permission dump that reported four
///     grants for a process TCC had attributed up the chain to a terminal;
///   * the **expectation table** caught three fixtures whose expected value
///     was the identity element of the transform under test, where the check
///     would have passed for the wrong reason;
///   * the **positive control** caught a synthetic `CMSampleBuffer` with no
///     data buffer, which produced a real AVFoundation error code that read
///     like a verdict on the code and was a verdict on the fixture.
///
/// **Three outcomes, not two.** `pass` and `fail` are the obvious ones. The
/// third — `inconclusive` — is for a step whose experiment did not happen:
/// the display was never reconfigured, the tone was never played, the person
/// did not do the thing. It must never be recorded as either of the others,
/// and it gets its own exit code so a script cannot collapse it into one.
///
/// **The guard's output is a correspondence table, not a number.** See
/// `expect` and `Verdict`. That is the one thing about this type that has
/// changed since Task 10, and it changed because the number was satisfiable
/// by the wrong element — ten times.
struct VerificationStep {

    /// 0 pass, 1 fail, 2 the experiment did not happen, 3 the positive
    /// control failed so nothing below it is readable.
    enum ExitCode: Int32 {
        case passed = 0
        case failed = 1
        case didNotHappen = 2
        case controlFailed = 3
    }

    let name: String
    private var checks: [(id: String, description: String, passed: Bool)] = []
    private var expectations: [Expectation] = []

    init(name: String) {
        self.name = name
    }

    // MARK: - 1. Identity

    /// Printed first, always, before anything a person might read as a
    /// result.
    ///
    /// A verification's output is worthless without knowing which binary
    /// produced it, under which bundle identity, from which commit. The
    /// permission dump that reported four grants was correct about *some*
    /// process; it was not the one anyone thought.
    func begin(repositoryPath: String) {
        let commit = Self.shellOutput("/usr/bin/git",
                                      ["-C", repositoryPath, "rev-parse", "--short", "HEAD"]) ?? "unknown"
        let executable = Bundle.main.executableURL?.path() ?? CommandLine.arguments.first ?? "unknown"
        let identifier = Bundle.main.bundleIdentifier
            ?? "NONE — a bare executable, so TCC attributes it to whatever launched it"
        print("""
        ── verification step: \(name) ──
        commit (read at launch, NOT baked — throwaway spike, not BuildProvenance): \(commit)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        bundle identifier : \(identifier)
        executable path   : \(executable)
        inside a .app     : \(executable.contains(".app/Contents/MacOS/") ? "yes" : "NO")
        pid               : \(ProcessInfo.processInfo.processIdentifier)
        ──
        """)
    }

    // MARK: - 1b. The setup, recorded but not claimed

    /// Rows that describe **the conditions this run happened under** — the
    /// display arrangement, the depth cap, which `AXElementSource` was passed,
    /// the object identity of the observer whose diagnostics are read. They
    /// are printed for the record and they carry **no identifier**, because
    /// there is nothing about them for a later assertion to be right or wrong
    /// about: they are read off the configuration at the moment they are
    /// printed.
    ///
    /// **This is not a softer `expect`, and the separation is enforced.** A
    /// `given` row has no id, so no `check` can cite one; a check that tries
    /// is reported as citing something never declared. The rule for which
    /// method a row belongs to is: if the row states something that could turn
    /// out to be false about *this run's outcome*, it is an `expect` row and
    /// something must check it. If it states what was configured before the
    /// run began, it is a `given`.
    ///
    /// **A `given` may only appear before this step's `expect`, and a scan
    /// enforces that.** `theGivenBlockCannotHoldAMeasuredResult` in
    /// `Tests/AppSourceTests` fails the build otherwise.
    ///
    /// The rule is about *position*, not about which labels are allowed. A
    /// name whitelist is an open set: it gets widened, each time for a
    /// legitimate new source of provenance, until it permits everything —
    /// which is `AGENTS.md`'s "a hand-written list rots by omission", one
    /// scope over. Position cannot be widened by argument. Configuration
    /// exists before the run; a measured result does not exist until after
    /// it, so the abuse this guards against — *measure something, then park it
    /// here rather than assert it* — is syntactically unreachable.
    ///
    /// It also settles a question that was argued out by hand: **"which
    /// `AXElementSource` actually ran" is not a `given`.** Under any dynamic
    /// selection that value is only known after the action, so the position
    /// rule refuses it here and forces it to be an expectation with an
    /// assertion. That was the right answer and it took a conversation; now it
    /// falls out of the structure.
    ///
    /// **Why this was scanned immediately rather than left to the ledger.**
    /// The test is whether a violation announces itself. Abuse of `given`
    /// **passes, and prints** — there is no trigger, so "wait until it happens
    /// once" is waiting for someone to happen to look. This project has the
    /// measurement: Spike B's step 2 kept its four assertions in a `print`
    /// block the harness could not read, and it passed. What found it was a
    /// migration, not the guard.
    ///
    /// Before this existed, `expect` carried both kinds, and the provenance
    /// rows — which no assertion can discharge — were the majority in some
    /// steps. Keeping them in `expect` under the new guard would have meant
    /// either inventing tautological checks for them or weakening the guard,
    /// and both are the shape this change exists to remove.
    func given(_ rows: [(String, String)]) {
        guard !rows.isEmpty else { return }
        let width = rows.map(\.0.count).max() ?? 0
        print("\n---- GIVEN, the setup this run happened under (recorded, asserted nowhere) ----")
        for (label, value) in rows {
            // The prefix is per row, not only on the header. A row quoted out
            // of this block — into a report, a commit message, a message to
            // someone — otherwise looks exactly like a discharged expectation.
            // Printed is not checked, and the line has to say so wherever it
            // ends up.
            print("  [not checked] \(label.padding(toLength: width, withPad: " ", startingAt: 0))  \(value)")
        }
        print("-------------------------------------------------------------------------------")
    }

    // MARK: - 2. Expectations, before the run — each one named

    /// An expectation, with an **identifier a later assertion must cite**.
    ///
    /// The identifier is a declaration, not a comment. That is the whole
    /// difference between this design and the one it replaces.
    struct Expectation {
        let id: String
        let label: String
        let value: String
        init(_ id: String, _ label: String, _ value: String) {
            self.id = id; self.label = label; self.value = value
        }
    }

    /// Prints what this step expects, **before** it measures anything, and
    /// records each expectation's identifier so `finish` can say which ones
    /// were never discharged.
    ///
    /// **Why identifiers, and why counting failed ten times.** The previous
    /// guard was "a step that records no assertions fails" — a check on the
    /// *count* of a set, when the property wanted is about its *members*. A
    /// number is always satisfiable by the wrong element, and it was: step 1
    /// of Task 10's human half declared six expectations, checked one (its
    /// negative control), printed three numbers and passed. The guard saw one
    /// assertion and was satisfied. Twice now that failure has happened inside
    /// something written to prevent it.
    ///
    /// So the guard's output changes type. It is no longer a number; it is the
    /// correspondence between what was declared and what was discharged, and a
    /// declared expectation that no assertion cites fails the step **by name**.
    /// `VerificationStep.selfTest()` replays step 1's historical shape against
    /// it, because a guard whose failure case exists only in prose is the shape
    /// that failed ten times.
    ///
    /// **One row, one claim.** A row whose text is a conjunction — "≥ 1
    /// window, detected by the poll, with no attribution" — is discharged by
    /// an assertion that checks any one of its three parts, and the guard
    /// cannot see the difference. Split conjunctions into separate rows with
    /// separate identifiers; four such rows were found already carrying
    /// unchecked halves.
    ///
    /// Values still come from the configuration, never typed by hand: every
    /// expectation-table error this project has made was a constant written by
    /// someone who knew the implementation, and each was the identity element
    /// of the transform under test.
    mutating func expect(_ rows: [Expectation]) {
        expectations.append(contentsOf: rows)
        guard !rows.isEmpty else { return }
        let width = rows.map(\.label.count).max() ?? 0
        print("\n---- EXPECTED, computed before measuring — each row must be cited below ----")
        for row in rows {
            print("  \(row.label.padding(toLength: width, withPad: " ", startingAt: 0))  \(row.value)")
            print("  \(String(repeating: " ", count: width))  [\(row.id)]")
        }
        print("----------------------------------------------------------------------------\n")
    }

    // MARK: - 3. Positive control

    /// A row whose answer is known **independently of anything under test**.
    /// Runs first; if it does not match, the step stops and reports
    /// `controlFailed` rather than printing results nobody can read.
    ///
    /// Without one, a malformed fixture answers questions about itself in the
    /// voice of the thing being measured. Synthetic CoreMedia and
    /// AVFoundation fixtures are especially good at this: they fail with real
    /// error codes.
    func control(_ description: String, expected: String, observed: String) {
        let matched = observed == expected
        print("CONTROL — \(description)")
        print("   expected (known independently): \(expected)")
        print("   observed:                       \(observed)")
        guard matched else {
            print("""

            STOP. The control did not reproduce its known answer, so the fixture or the setup is not a \
            valid stand-in for the real thing. Nothing below it would be about what this step measures.
            """)
            exit(ExitCode.controlFailed.rawValue)
        }
        print("   → validated; the checks below are readable.\n")
    }

    // MARK: - 3b. Signalling a human who cannot see this output

    /// Marks the start and end of a window in which a person must do
    /// something, **audibly**.
    ///
    /// **Because the printed countdown is not where the human is.** These
    /// steps run as a tool invocation whose stdout the operator never sees;
    /// they read a summary afterwards. So `print("starting in 3…")` is an
    /// instruction delivered to the one party that cannot act on it. Three
    /// consecutive runs of a five-second click window failed on timing alone —
    /// eight events, then ten, then zero, then zero — and each failure looked
    /// like it might be a defect in the tap.
    ///
    /// The same rule as a check's printed caveat, applied to instructions
    /// rather than results: say it where the audience that must act on it
    /// actually is. For a person at the machine, that is a sound.
    ///
    /// One beep at GO, two at STOP. `NSSound.beep()` is not used: it is
    /// AppKit, needs an app to be foregrounded to be reliable, and these
    /// spikes are `LSUIElement` background tools. `afplay` on a system sound
    /// plays regardless.
    func humanWindow(_ seconds: Int, _ instruction: String,
                     during: (Int) -> Void = { _ in }) {
        print("\n>>> \(instruction)")
        print("    (one beep = start, two beeps = stop — the countdown below is for the log,")
        print("     the beeps are for you)")
        for remaining in stride(from: 3, to: 0, by: -1) {
            print("    starting in \(remaining)…")
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        Self.beep()
        print("    GO — \(seconds)s\n")
        for elapsed in 0..<seconds {
            CFRunLoopRunInMode(.defaultMode, 1, false)
            during(elapsed)
        }
        Self.beep(); Self.beep()
        print("    STOP\n")
    }

    /// One beep: the window is open, do the thing now.
    static func beepStart() { beep() }
    /// Two beeps: the window is closed, stop.
    static func beepStop() { beep(); beep() }

    private static func beep() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/afplay")
        process.arguments = ["/System/Library/Sounds/Tink.aiff"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 4. Checks

    /// One named assertion, **citing the expectation it discharges**.
    ///
    /// The description carries the measured value, not a summary of it — a
    /// refusal or a failure is read at the moment someone starts
    /// investigating, which is when an inferred statement does the most
    /// damage. It must also not claim more than its own predicate tests: one
    /// assertion here described "events arrived while secure input was on, and
    /// NONE produced an observation" over a predicate that only tested the
    /// first clause.
    ///
    /// `id` must name an expectation declared by `expect`. Citing one that was
    /// never declared is itself a failure: it means the step is checking
    /// something it did not say it would, which is the same drift in the other
    /// direction — and it is how a mechanical migration hides, by generating
    /// identifiers on both sides that never meet.
    ///
    /// Several checks may cite one expectation; that is a row being discharged
    /// from more than one direction, which is fine. What is not fine is a row
    /// whose *text* is a conjunction and whose single check tests one half —
    /// see `expect`.
    mutating func check(_ id: String, _ description: String, _ passed: Bool) {
        checks.append((id, description, passed))
    }

    /// A precondition that makes the measurement readable was not met — the
    /// tone was not playing, the acoustic path was too loud, the permission
    /// was not granted. Distinct from `didNotHappen`, which is about the
    /// experiment; this is about whether its result could be interpreted.
    ///
    /// Shares `controlFailed`'s exit code deliberately: both mean "stop, and
    /// do not read anything below this". Every step routes through here so
    /// exit codes live in one space — steps that invented their own drifted
    /// to 5 and 6 while the harness used 0 through 3.
    func preconditionFailed(_ why: String) -> Never {
        print("\nABORTING before measuring — \(why)")
        exit(ExitCode.controlFailed.rawValue)
    }

    /// The experiment did not run. Not a pass, not a failure, and it exits
    /// with its own code so nothing downstream can average it into either.
    func didNotHappen(_ why: String) -> Never {
        print("""

        THE EXPERIMENT DID NOT HAPPEN — \(why)
        This is neither a pass nor a failure, and it must not be recorded as either.
        """)
        exit(ExitCode.didNotHappen.rawValue)
    }

    // MARK: - 5. The guard, as a correspondence rather than a count

    /// The correspondence between the expectations a step declared and the
    /// assertions that cited them.
    ///
    /// Pure and separately constructible, so the guard itself is testable —
    /// the previous one was only reachable by running a whole spike with a
    /// person at the machine, which is why its own failure case was never
    /// executed.
    struct Verdict {
        /// Declared, and no assertion cited it. These fail the step **by
        /// name**; this is the case a count could not see.
        let undischarged: [String]
        /// Cited by an assertion, never declared. The same drift the other way
        /// round: the step checked something it did not say it would.
        let uninvited: [String]
        /// Declared more than once. Two rows sharing an identifier mean one
        /// assertion silently discharges both, which is the count problem
        /// again at a smaller scale.
        let duplicated: [String]
        /// Cited and failing.
        let failed: [String]
        /// The step declared no expectations at all. Kept as its own case
        /// because the correspondence between two empty sets is vacuously
        /// perfect — a step with no `expect` and no `check` would otherwise
        /// pass, which is exactly the vacuous pass the old count-based guard
        /// did catch and this one must not lose.
        let declaredNothing: Bool

        var passed: Bool {
            !declaredNothing && undischarged.isEmpty && uninvited.isEmpty
                && duplicated.isEmpty && failed.isEmpty
        }
    }

    static func verdict(expected: [String],
                        checks: [(id: String, passed: Bool)]) -> Verdict {
        let cited = Set(checks.map(\.id))
        let declared = Set(expected)
        var seen = Set<String>()
        var duplicated: [String] = []
        for id in expected where !seen.insert(id).inserted { duplicated.append(id) }
        return Verdict(undischarged: expected.uniqued().filter { !cited.contains($0) },
                       uninvited: checks.map(\.id).filter { !declared.contains($0) }.uniqued(),
                       duplicated: duplicated.uniqued(),
                       failed: checks.filter { !$0.passed }.map(\.id).uniqued(),
                       declaredNothing: expected.isEmpty)
    }

    /// Prints every assertion, then the correspondence, and exits.
    ///
    /// `remedy` is printed only on failure: the first thing to suspect when
    /// this particular step fails, which is usually the physical setup rather
    /// than the code.
    func finish(remedy: String? = nil) -> Never {
        print("\n\(checks.count) ASSERTION\(checks.count == 1 ? "" : "S") — \(name):")
        for check in checks {
            print("  \(check.passed ? "ok  " : "FAIL") [\(check.id)] \(check.description)")
        }
        let result = Self.verdict(expected: expectations.map(\.id),
                                  checks: checks.map { ($0.id, $0.passed) })

        print("\nCORRESPONDENCE — \(expectations.count) declared, "
              + "\(Set(checks.map(\.id)).count) cited by \(checks.count) assertion(s):")
        for expectation in expectations.uniquedBy(\.id) {
            let citing = checks.filter { $0.id == expectation.id }
            let mark = citing.isEmpty ? "✗ NEVER CITED"
                : citing.allSatisfy(\.passed) ? "ok  ×\(citing.count)"
                : "FAIL×\(citing.count)"
            print("  \(mark.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                  + "[\(expectation.id)] \(expectation.label)")
        }

        if result.declaredNothing {
            print("""

            NO EXPECTATIONS WERE DECLARED. The correspondence between two empty sets is perfect, \
            which is why this is checked separately: a step that declares nothing and checks nothing \
            passes vacuously, and that is the one outcome that must never be reported as success.
            """)
        }
        if !result.undischarged.isEmpty {
            print("\nUNDISCHARGED EXPECTATIONS — declared, and no assertion cites them:")
            for id in result.undischarged {
                let label = expectations.first { $0.id == id }?.label ?? id
                print("  ✗ [\(id)] \(label)")
            }
            print("""
            A step that declares an expectation and never checks it has stated an intention, not a \
            result. The previous guard counted assertions and was satisfied by one — which is how a \
            step declaring six and checking only its negative control passed.
            """)
        }
        if !result.uninvited.isEmpty {
            print("\nUNDECLARED ASSERTIONS — cited, never declared: "
                  + result.uninvited.joined(separator: ", "))
            print("The step checked something it did not say it would, which is the same drift the "
                  + "other way round. Either the expectation table is incomplete — which is a "
                  + "finding — or the identifier is a typo.")
        }
        if !result.duplicated.isEmpty {
            print("\nDUPLICATE EXPECTATION IDENTIFIERS: " + result.duplicated.joined(separator: ", "))
            print("Two rows sharing an identifier are discharged by one assertion, which is the "
                  + "count problem again at a smaller scale.")
        }
        if result.passed {
            print("\nPASS — \(name)  (\(expectations.count) expectations, every one discharged)")
            exit(ExitCode.passed.rawValue)
        }
        print("\nFAIL — \(name)")
        if !result.failed.isEmpty {
            print("  failing assertions: " + result.failed.joined(separator: ", "))
        }
        if let remedy { print(remedy) }
        exit(ExitCode.failed.rawValue)
    }

    // MARK: -

    private static func shellOutput(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Array where Element: Hashable {
    /// Order-preserving deduplication, so a verdict lists each id once in the
    /// order it was first seen rather than in hash order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension Array {
    /// Order-preserving deduplication on a key — used to print the
    /// correspondence table once per identifier even when a row was declared
    /// twice (which is itself reported).
    func uniquedBy<Key: Hashable>(_ key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}

// MARK: - The guard's own regression case

extension VerificationStep {
    /// **The historical failure this guard exists for, as an executable case.**
    ///
    /// Task 10's human step 1 declared six expectations — the edges, the
    /// over-estimate bound, the poll pair, resumed delivery, the negative
    /// control, and what was induced — and discharged exactly one of them, its
    /// negative control. It then printed three numbers and called `finish()`.
    /// It **passed**, because the old guard's output was a count and the count
    /// was one.
    ///
    /// This replays those identifiers against the current guard, and it is not
    /// a demonstration: a guard whose own failure case is described only in
    /// prose is the shape that failed ten times. It also runs the guard's own
    /// positive control — a fully discharged step must still pass — so a guard
    /// that has degraded into failing everything is caught here rather than by
    /// the person who cannot get a green step.
    ///
    /// Needs no permission, no hardware and no operator: `--self-test` on any
    /// spike.
    static func selfTest() -> Never {
        var failures: [String] = []
        func require(_ condition: Bool, _ what: String) {
            if !condition { failures.append(what) }
        }

        print("── VerificationStep self-test — the guard's own regression case ──")

        // ---- 1. Task 10 human step 1, as it was first written ----
        let declared = ["induced", "edges", "over-estimate-bound", "poll-pair",
                        "delivery-resumed", "negative-control"]
        let asStepOneWas: [(id: String, passed: Bool)] = [("negative-control", true)]
        let old = Self.verdict(expected: declared, checks: asStepOneWas)
        print("\n1. replaying Task 10 human step 1 as it was first written:")
        print("   declared   \(declared.count): \(declared.joined(separator: ", "))")
        print("   discharged \(asStepOneWas.count): \(asStepOneWas.map(\.id).joined(separator: ", "))")
        print("   the OLD guard's output was a count — 1 assertion, so it PASSED")
        print("   this guard names the undischarged: \(old.undischarged.joined(separator: ", "))")
        require(!old.passed, "the guard passed step 1's original shape")
        require(old.undischarged.count == 5,
                "expected 5 undischarged, got \(old.undischarged.count)")
        require(!old.undischarged.contains("negative-control"),
                "the one expectation that WAS discharged is listed as undischarged")
        for id in declared where id != "negative-control" {
            require(old.undischarged.contains(id), "\"\(id)\" was not named as undischarged")
        }

        // ---- 2. the other direction: an assertion citing something undeclared ----
        let uninvited = Self.verdict(expected: ["a"], checks: [("a", true), ("b", true)])
        print("\n2. an assertion citing an identifier that was never declared:")
        print("   declared [a], cited [a, b] → uninvited: \(uninvited.uninvited.joined(separator: ", "))")
        require(uninvited.uninvited == ["b"], "an undeclared assertion was not named")
        require(!uninvited.passed, "the guard passed an undeclared assertion")

        // ---- 3. the guard's own POSITIVE CONTROL ----
        //
        // Without this the guard could have degraded into failing everything
        // and cases 1 and 2 would still read as green — which is the same
        // "passes for the wrong reason" shape one level up.
        let clean = Self.verdict(expected: ["a", "b"], checks: [("a", true), ("b", true)])
        print("\n3. positive control — a fully discharged step must still PASS:")
        print("   declared [a, b], cited [a, b] → passed: \(clean.passed)")
        require(clean.passed, "the guard failed a fully discharged step")
        require(clean.undischarged.isEmpty && clean.uninvited.isEmpty,
                "a fully discharged step reported a correspondence problem")

        // ---- 4. a failing assertion still fails ----
        let failing = Self.verdict(expected: ["a"], checks: [("a", false)])
        require(!failing.passed, "the guard passed a step whose only assertion failed")
        require(failing.failed == ["a"], "a failing assertion was not named")

        // ---- 5. the vacuous step the OLD guard did catch, and this must too ----
        let empty = Self.verdict(expected: [], checks: [])
        print("\n4. a step that declares nothing and checks nothing:")
        print("   declaredNothing: \(empty.declaredNothing), passed: \(empty.passed)")
        require(!empty.passed, "a step declaring nothing and checking nothing passed")
        require(empty.declaredNothing, "declaring nothing was not reported as such")

        // ---- 6. two rows sharing an identifier ----
        let duped = Self.verdict(expected: ["a", "a"], checks: [("a", true)])
        require(duped.duplicated == ["a"], "a duplicated identifier was not named")
        require(!duped.passed, "the guard passed a step with two rows sharing an identifier")

        // ---- 7. one expectation, several assertions ----
        let manyToOne = Self.verdict(expected: ["a"], checks: [("a", true), ("a", true)])
        require(manyToOne.passed, "two assertions citing one expectation were rejected")

        guard failures.isEmpty else {
            print("\nFAIL — the guard does not catch its own historical failure:")
            for failure in failures { print("  ✗ \(failure)") }
            exit(ExitCode.failed.rawValue)
        }
        print("""

        PASS — the guard names all five of step 1's undischarged expectations, rejects an assertion \
        citing an identifier that was never declared, rejects a duplicated identifier, rejects a step \
        that declares nothing, and still passes a fully discharged step.
        """)
        exit(ExitCode.passed.rawValue)
    }
}
