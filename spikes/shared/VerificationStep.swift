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
    private var checks: [(description: String, passed: Bool)] = []

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

    // MARK: - 2. Expectations, before the run

    /// Prints what this step expects, **before** it measures anything.
    ///
    /// Pass derived values, not hand-written ones. Every expectation-table
    /// error this project has made was a constant typed by the person who
    /// knew the implementation, and each one happened to be the identity
    /// element of the transform under test — a scale of 1, an origin of
    /// (0, 0), a display where "the content was not resampled" is necessarily
    /// true. A table computed from the configuration cannot degrade into
    /// "something plausible was visible, so it passed", and being in the log
    /// above the results means it cannot be revised afterwards either.
    func expect(_ rows: [(String, String)]) {
        let width = rows.map(\.0.count).max() ?? 0
        print("\n---- EXPECTED, computed before measuring ----")
        for (label, value) in rows {
            print("  \(label.padding(toLength: width, withPad: " ", startingAt: 0))  \(value)")
        }
        print("---------------------------------------------\n")
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

    /// One named assertion. The description carries the **measured value**,
    /// not a summary of it — a refusal or a failure is read at the moment
    /// someone starts investigating, which is when an inferred statement does
    /// the most damage.
    mutating func check(_ description: String, _ passed: Bool) {
        checks.append((description, passed))
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

    /// Prints every check and exits with `passed` or `failed`.
    ///
    /// `remedy` is printed only on failure: the first thing to suspect when
    /// this particular step fails, which is usually the physical setup rather
    /// than the code.
    func finish(remedy: String? = nil) -> Never {
        print("\n\(checks.count) ASSERTION\(checks.count == 1 ? "" : "S") — \(name):")
        for (description, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(description)")
        }
        guard !checks.isEmpty else {
            print("\nFAIL — no assertions ran. A step that checks nothing passes vacuously, which is " +
                  "the one outcome that must never be reported as success.")
            exit(ExitCode.failed.rawValue)
        }
        if checks.allSatisfy(\.passed) {
            print("\nPASS — \(name)")
            exit(ExitCode.passed.rawValue)
        }
        print("\nFAIL — \(checks.filter { !$0.passed }.count) of \(checks.count) assertions failed.")
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
