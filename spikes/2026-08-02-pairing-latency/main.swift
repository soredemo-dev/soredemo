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

    var records: [AXChainRecord] { lock.withLock { storage } }
    var clicksSeen: Int { lock.withLock { clicks } }

    func append(_ record: AXChainRecord) { lock.withLock { storage.append(record) } }
    func countClick() { lock.withLock { clicks += 1 } }
}

@main
enum SpikeA {

    static let repositoryPath = "~/Documents/Soredemo/soredemo-main"

    /// F2-2, from `docs/design/2026-08-02-phase-2-record-design.md`, 118
    /// samples. Printed as the expectation table **before** anything is
    /// measured, so a reading cannot be revised toward it afterwards.
    static let f2_2: [(name: String, p50: Double, p90: Double, max: Double)] = [
        ("hit-test interval ms", 1.05, 21.25, 125.47),
        ("whole walk ms",        5.10, 32.22, 173.53),
        ("AX calls",            41,   106,   131),
        ("chain depth",          3,    12,    20),
    ]

    @MainActor
    static func main() {
        let seconds = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 45
        var step = VerificationStep(name: "Spike A — pairing latency against the real AXObserver")
        step.begin(repositoryPath: repositoryPath)

        let arrangement = InputObserver.currentArrangement()
        step.expect([
            ("depth cap", "\(AXObserver.depthCap) — fixed (D2-5), expected to bind only on web content"),
            ("walk budget", "\(Double(AXObserver.walkBudgetNanos) / 1e6) ms — a D4 PLACEHOLDER"),
            ("displays", "\(arrangement.placements.count) in the arrangement under test"),
        ] + f2_2.map { ($0.name, String(format: "p50 %.2f  p90 %.2f  max %.2f  (F2-2, 118 samples)",
                                        $0.p50, $0.p90, $0.max)) }
          + [("containment", "NOT all clicks outside their element — a uniform miss is the "
                             + "coordinate path, not AX staleness")])

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
                // `.down` only. The verb half of "click the Save button" is
                // the press; hit-testing the release as well would double the
                // AX cost for a second answer to the same question.
                guard case .button(let event) = observation, event.phase == .down else { return }
                samples.countClick()
                guard let record = axObserver.chain(at: event) else { return }
                samples.append(record)
                if let line = try? ObservationLog.encode(record) {
                    out?.write(line); out?.write(Data("\n".utf8))
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
        let measured: [(String, [Double])] = [
            ("hit-test interval ms", hitTestMs), ("whole walk ms", walkMs),
            ("AX calls", calls), ("chain depth", depths),
        ]

        print("\n---- MEASURED, \(records.count) samples on this machine ----")
        func column(_ text: String, _ width: Int) -> String {
            text.count >= width ? text
                : String(repeating: " ", count: width - text.count) + text
        }
        print("  " + column("", 22) + column("p50", 9) + column("p90", 9) + column("max", 9)
              + "   " + column("F2-2 p50", 9) + column("p90", 9) + column("max", 9))
        for (name, values) in measured {
            let reference = f2_2.first { $0.name == name }!
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
        print("\n---- diagnostics ----")
        print("  " + diagnostics.accounting.replacingOccurrences(of: "\n", with: "\n  "))
        print("  tap re-armed after a timeout: \(inputObserver.diagnostics.tapReArmedCount)")
        print("  AX log: \(logURL.path()) — NOT to be committed; it carries window titles.")

        // ---- the checks
        step.check("\(records.count) chains recorded from \(samples.clicksSeen) clicks",
                   records.count > 0)
        step.check("every click is accounted for — \(diagnostics.accounting.split(separator: "\n")[0])",
                   diagnostics.everyClickIsAccountedFor)
        step.check("every record carries one truncation reason",
                   diagnostics.everyRecordHasATruncationReason)
        step.check("every record carries one containment verdict",
                   diagnostics.everyRecordHasAContainmentVerdict)

        // **The coordinate check, stated as what it can actually rule out.**
        // Some proportion of clicks legitimately miss: AX is stale during
        // animation, which is what this run is deliberately provoking. What
        // cannot legitimately happen is ALL of them missing — that is the
        // reverse conversion being wrong, and it is the one shape a plausible
        // AX explanation does not cover.
        step.check("""
                   \(diagnostics.clickInsideTheHitFrame) of \(diagnostics.chainsRecorded) clicks fell \
                   inside the element the hit-test returned, \(diagnostics.clickOutsideTheHitFrame) \
                   outside, \(diagnostics.clickFrameNotComparable) not comparable, \
                   \(diagnostics.recordsWithNoFrame) with no frame — not all of them missed
                   """,
                   diagnostics.clickOutsideTheHitFrame < diagnostics.chainsRecorded)
        step.check("no interval was measured backwards (\(diagnostics.nonMonotonicClockReadings))",
                   diagnostics.nonMonotonicClockReadings == 0)

        // Order of magnitude, not equality. F2-2 is one machine, one session,
        // an uncontrolled app mix; D4 still applies and this is not a
        // calibration. What a 10× divergence would mean is that the shipping
        // observer does substantially more work per click than the inline walk
        // the bounds were fitted to, which is the question this re-run exists
        // to answer.
        for (name, values) in measured {
            let reference = f2_2.first { $0.name == name }!
            let mine = percentile(values, 0.50)
            let ratio = reference.p50 == 0 ? 1 : mine / reference.p50
            step.check(String(format: "%@ p50 %.2f against F2-2's %.2f — ratio %.2f, within 10×",
                              name, mine, reference.p50, ratio),
                       ratio > 0.1 && ratio < 10)
        }

        step.finish(remedy: """
        A p50 an order of magnitude above F2-2's means AXObserver is doing more work per click \
        than the inline walk F2-2 measured — compare `axCalls` first, which is exact.
        All clicks landing outside their element means the reverse conversion \
        (AXObserver.globalPoint) is wrong, NOT that AX is stale: staleness moves an element by a \
        frame of animation, it does not move it out of its own coordinate space. Probe § 8.1 is \
        the same claim against a fixture and would still be green, because it does not use this \
        machine's arrangement.
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
