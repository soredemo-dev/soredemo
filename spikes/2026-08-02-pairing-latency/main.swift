// Spike A — click-to-hit-test pairing latency.
//
// Answers, on real targets, what F2-1 could only lower-bound:
//   * tap-path latency: the event's own timestamp -> the moment our callback runs
//   * AX interval width: mach_absolute_time() before and after each AX call
//   * how both behave while the UI is animating, which is when people click buttons
//
// It records. It does not judge — D2-1. Nothing here decides which element is
// "the control"; every element the bounded walk reaches is written out with its
// own interval, and the derivation stage chooses later.
//
// Needs Input Monitoring (for the tap) and Accessibility (for the hit-test).
// It does NOT need Screen Recording — that is spike B.

import AppKit
import ApplicationServices
import Darwin

// D4 applies: these are PLACEHOLDERS, not calibrated thresholds. The whole point
// of this spike is to produce the distribution they should be fitted to. Any
// value quoted from a run of this tool must say it was measured under these.
let depthCap = 20
let walkBudgetNanos: UInt64 = 20_000_000   // 20 ms

var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
@inline(__always) func nowNanos() -> UInt64 {
    mach_absolute_time() &* UInt64(tb.numer) / UInt64(tb.denom)
}

let outURL = URL(filePath: NSHomeDirectory())
    .appending(path: "soredemo-spike-a.jsonl")
var out = FileHandle(forWritingAtPath: outURL.path())
if out == nil {
    FileManager.default.createFile(atPath: outURL.path(), contents: nil)
    out = FileHandle(forWritingAtPath: outURL.path())
}
out?.seekToEndOfFile()

func emit(_ o: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
    out?.write(d); out?.write(Data("\n".utf8))
}

/// One AX call, bracketed. The interval width IS the uncertainty (D2-2a) —
/// this API has no timestamp of its own, so a single number would invent a
/// precision that was never measured.
func timed<T>(_ body: () -> T) -> (value: T, before: UInt64, after: UInt64) {
    let b = nowNanos(); let v = body(); let a = nowNanos()
    return (v, b, a)
}

func copyAttr(_ el: AXUIElement, _ attr: String) -> (CFTypeRef?, UInt64, UInt64) {
    var v: CFTypeRef?
    let r = timed { AXUIElementCopyAttributeValue(el, attr as CFString, &v) }
    return (r.value == .success ? v : nil, r.before, r.after)
}

func describe(_ el: AXUIElement) -> ([String: Any], UInt64) {
    var calls: UInt64 = 0
    var o: [String: Any] = [:]
    let (roleV, rb, ra) = copyAttr(el, kAXRoleAttribute as String); calls += 1
    o["role"] = (roleV as? String) ?? NSNull()
    o["roleIntervalNs"] = ["before": rb, "after": ra, "width": ra - rb]
    // TWO IPC calls, not one. `kAXFrameAttribute` is not exposed to Swift; the
    // public spelling is position + size, so every element costs an extra
    // round trip into the target process. That goes straight into the budget
    // D2-2 bounds, and it is why this is measured rather than assumed.
    let (posV, pb2, pa2) = copyAttr(el, kAXPositionAttribute as String); calls += 1
    let (sizeV, sb, sa) = copyAttr(el, kAXSizeAttribute as String); calls += 1
    var origin = CGPoint.zero, size = CGSize.zero
    if let pv = posV, CFGetTypeID(pv) == AXValueGetTypeID() {
        AXValueGetValue(pv as! AXValue, .cgPoint, &origin)
    }
    if let sv = sizeV, CFGetTypeID(sv) == AXValueGetTypeID() {
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
    }
    o["frame"] = ["x": origin.x, "y": origin.y, "w": size.width, "h": size.height]
    o["frameIntervalNs"] = ["before": pb2, "after": sa, "width": sa - pb2,
                            "positionWidth": pa2 - pb2, "sizeWidth": sa - sb]
    let (titleV, _, _) = copyAttr(el, kAXTitleAttribute as String); calls += 1
    o["title"] = (titleV as? String) ?? NSNull()
    return (o, calls)
}

var sampleIndex = 0

func handle(_ event: CGEvent) {
    let cbNanos = nowNanos()
    let evNanos = UInt64(event.timestamp)      // F2-1: this is NANOSECONDS, measured
    let loc = event.location                    // global, top-left origin — same space AX uses
    var calls: UInt64 = 0

    let sys = AXUIElementCreateSystemWide()
    var hit: AXUIElement?
    let hitR = timed { () -> AXError in
        var e: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(sys, Float(loc.x), Float(loc.y), &e)
        hit = e; return err
    }
    calls += 1

    var record: [String: Any] = [
        "sample": sampleIndex,
        "eventTimestampNs": evNanos,
        "callbackEntryNs": cbNanos,
        "tapLatencyNs": cbNanos > evNanos ? cbNanos - evNanos : 0,
        "tapLatencyNegative": cbNanos <= evNanos,   // never silently zero — F2-1's own bug
        "clickPoint": ["x": loc.x, "y": loc.y],
        "hitTestIntervalNs": ["before": hitR.before, "after": hitR.after,
                              "width": hitR.after - hitR.before],
        "hitTestError": hitR.value == .success ? NSNull() : hitR.value.rawValue,
        "depthCap": depthCap, "walkBudgetNs": walkBudgetNanos,
    ]

    guard let start = hit else {
        record["truncation"] = "hit-test returned nothing"
        record["axCalls"] = calls
        emit(record); sampleIndex += 1
        print("sample \(sampleIndex - 1): hit-test returned nothing")
        return
    }

    let (hitDesc, hitCalls) = describe(start); calls += hitCalls
    record["hit"] = hitDesc

    // Bounded ancestor walk. Truncation is itself a record (D2-2): otherwise
    // "there were no more ancestors" and "I did not ask" are identical on disk.
    var chain: [[String: Any]] = []
    var cur = start
    var truncation = "reached root"
    let walkStart = nowNanos()
    for depth in 0..<depthCap {
        if nowNanos() - walkStart > walkBudgetNanos { truncation = "budget exceeded"; break }
        let (pv, pb, pa) = copyAttr(cur, kAXParentAttribute as String); calls += 1
        guard let p = pv, CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
        let parent = p as! AXUIElement
        var (d, c) = describe(parent); calls += c
        d["depth"] = depth + 1
        d["parentLookupIntervalNs"] = ["before": pb, "after": pa, "width": pa - pb]
        chain.append(d)
        cur = parent
        if depth == depthCap - 1 { truncation = "depth cap reached" }
    }
    record["ancestors"] = chain
    record["truncation"] = truncation

    // One level down (D2-3). Without this the row's stated preference for
    // well-bounded DESCENDANTS is unimplementable in derivation.
    let (kidsV, kb, ka) = copyAttr(start, kAXChildrenAttribute as String); calls += 1
    var kids: [[String: Any]] = []
    if let arr = kidsV as? [AXUIElement] {
        for k in arr.prefix(32) { let (d, c) = describe(k); calls += c; kids.append(d) }
        record["childrenTruncated"] = arr.count > 32
    }
    record["children"] = kids
    record["childrenLookupIntervalNs"] = ["before": kb, "after": ka, "width": ka - kb]

    record["axCalls"] = calls
    record["totalWallNs"] = nowNanos() - cbNanos
    emit(record)

    let tap = record["tapLatencyNs"] as! UInt64
    print(String(format: "sample %d  tap %.2f ms  hit-test %.2f ms  chain %d  calls %llu  total %.1f ms  [%@]",
                 sampleIndex, Double(tap) / 1e6,
                 Double(hitR.after - hitR.before) / 1e6, chain.count, calls,
                 Double(record["totalWallNs"] as! UInt64) / 1e6, truncation))
    sampleIndex += 1
}

// ---- permissions, reported not assumed ----
let axTrusted = AXIsProcessTrusted()
print("Accessibility trusted: \(axTrusted)")
if !axTrusted {
    _ = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
}

let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap,
    options: .listenOnly, eventsOfInterest: CGEventMask(mask),
    callback: { _, _, event, _ in handle(event); return Unmanaged.passUnretained(event) },
    userInfo: nil)
else {
    print("TAP CREATION FAILED — Input Monitoring not granted, or the app is not the one granted.")
    print("This is the failure that must NOT be read as 'no events happened'.")
    exit(2)
}
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("Tap created. Writing to \(outURL.path())")
print("Click on things — native AppKit, an Electron app, and something known to be slow.")
print("Click DURING animations, not on a static screen. Ctrl-C to stop.\n")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
