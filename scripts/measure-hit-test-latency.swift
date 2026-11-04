// How long the accessibility hit-test takes, per application, over the windows on screen — the
// measurement behind `docs/design/2026-11-04-a-read-is-stale-only-after-the-release.md`, which
// replaced gate 3's 4 ms budget with the click's release. Read-only: it asks the system-wide
// element what is at a grid of points inside each window, the call `LiveAXElementSource.hitTest`
// makes, and records only how long each answer took. Nothing is clicked, typed or read back.
//
//   xcrun swift scripts/measure-hit-test-latency.swift [budget-ms]
//
// The first ask of each window is reported apart from the rest: a click is usually the first
// question an app has been asked in a while, and an app that builds its tree on demand (a web
// view, notably) answers that one slowly. Needs the Accessibility grant of whatever runs it;
// refuses to print a distribution when it measured nothing.
import AppKit
import ApplicationServices

let budget = Double(CommandLine.arguments.dropFirst().first ?? "4") ?? 4
guard AXIsProcessTrusted() else {
    print("refused: this process has no Accessibility grant, so every hit-test would fail fast")
    exit(2)
}

struct Window { let owner: String; let pid: pid_t; let frame: CGRect }
let me = ProcessInfo.processInfo.processIdentifier
let windows: [Window] = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] ?? [])
    .compactMap { info in
        guard info[kCGWindowLayer as String] as? Int == 0,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
              let owner = info[kCGWindowOwnerName as String] as? String,
              let b = info[kCGWindowBounds as String] as? [String: Double] else { return nil }
        let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        return frame.width >= 200 && frame.height >= 150 ? Window(owner: owner, pid: pid, frame: frame) : nil
    }

func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

var first: [String: [Double]] = [:], warm: [String: [Double]] = [:]
var failures = 0
let system = AXUIElementCreateSystemWide()
for window in windows {
    // A 6 x 5 grid inside the window, clear of its edges, in reading order; the first is "cold".
    for row in 0..<5 {
        for column in 0..<6 {
            let x = window.frame.minX + window.frame.width * (Double(column) + 0.5) / 6
            let y = window.frame.minY + window.frame.height * (Double(row) + 0.5) / 5
            var element: AXUIElement?
            var error = AXError.success
            let ms = milliseconds { error = AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &element) }
            if error != .success { failures += 1; continue }
            if row == 0 && column == 0 { first[window.owner, default: []].append(ms) }
            else { warm[window.owner, default: []].append(ms) }
        }
    }
}

let all = (first.values.flatMap { $0 } + warm.values.flatMap { $0 }).sorted()
guard !all.isEmpty else {
    print("refused: \(windows.count) windows on screen, \(failures) failed hit-tests, nothing measured")
    exit(2)
}
func quantile(_ sorted: [Double], _ q: Double) -> Double {
    sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
}
func line(_ name: String, _ values: [Double]) -> String {
    let s = values.sorted()
    let over = s.filter { $0 > budget }.count
    return String(format: "%-22@ n=%-4d p50 %7.2f  p90 %7.2f  p99 %7.2f  max %7.2f ms   over %.0f ms: %d",
                  name as NSString, s.count, quantile(s, 0.5), quantile(s, 0.9), quantile(s, 0.99),
                  s.last ?? 0, budget, over)
}
print("hit-test latency, \(windows.count) windows, \(all.count) answers, \(failures) failed")
print("— first ask of each window —")
for owner in first.keys.sorted() { print(line(owner, first[owner]!)) }
print("— later asks —")
for owner in warm.keys.sorted() { print(line(owner, warm[owner]!)) }
print(line("ALL", all))
