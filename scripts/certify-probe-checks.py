#!/usr/bin/env python3
"""The red certificates for the Task 12 sample: mutate PRODUCT code, and see what reddens.

The twenty checks were drawn by `scripts/enumerate-probe-checks.py --sample 20 --seed 20260803`
from the 338 written call sites, by index, before any of them was read. This file is what turned
that list into evidence: each entry names one mutation to the SHIPPING sources — never to the
probe — and the check whose label must go `FAIL` under it. One mutation at a time, build, run,
restore. A check earns its certificate only by failing.

    scripts/certify-probe-checks.py            run every mutation
    scripts/certify-probe-checks.py 170 313    run only those

Results are summarised in `AGENTS.md`'s red-certificate register. Three entries below appear
twice, with a second index (1700, 3130, 3231): the first mutation for each was aimed at something
the check does not depend on, and finding that out is most of what the exercise produced. Keep
both — a mutation that leaves a check green is a fact about the check, not a failed attempt.

Restoration is in a `finally`, and the tree is checked clean afterwards. If this process is killed
mid-run, one product file is left mutated; `git status` will say which.
"""
import subprocess, sys, json, pathlib, os

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(os.environ.get("SCRATCH", "/tmp"))

M = [
 # (index, file, old, new, target-substring-of-the-check's-label)
 (33, "Soredemo/Capture/CaptureSource.swift",
  """            guard let largestDisplay = availableDisplays.max(by: { $0.width * $0.height < $1.width * $1.height })
            else { return nil }""",
  """            guard let largestDisplay = availableDisplays.max(by: { $0.width * $0.height < $1.width * $1.height })
            else {
                let s = Double(filter.pointPixelScale)
                self = .window(window, bufferSize: (width: Int(filter.contentRect.width * s),
                                                    height: Int(filter.contentRect.height * s)))
                return
            }""",
  "no available displays returns nil for a window, not a fallback size"),

 (37, "Soredemo/Capture/CaptureSession.swift",
  "let segment = MasterSegment(index: closedSegments.count, mediaFilename: openSegment.mediaFilename,",
  "let segment = MasterSegment(index: closedSegments.count + 1, mediaFilename: openSegment.mediaFilename,",
  "the first segment is index 0"),

 (73, "Soredemo/Capture/InputObserver.swift",
  """        let position = NormalizationContext(geometry: hit.geometry)
            .normalize(topLeftX: pixels.x, topLeftY: pixels.y)
        return (position, hit.geometry.revision)""",
  """        let position = NormalizationContext(geometry: hit.geometry)
            .normalize(topLeftX: pixels.y, topLeftY: pixels.x)
        return (position, hit.geometry.revision)""",
  "the emitted pointer sample carries the converted position and the display's revision"),

 (74, "Soredemo/Capture/InputObserver.swift",
  "        return HostInstant(epoch: epoch, hostTime: Nanoseconds(stampNanos))",
  "        return HostInstant(epoch: epoch, hostTime: Minting.hostNow())",
  "the sample's instant is the EVENT's own timestamp"),

 (95, "Soredemo/Capture/InputObserver.swift",
  """                _diagnostics.secureInputCheckSpanNanos =
                    max(0, instant.hostTime.rawValue - first.hostTime.rawValue)""",
  "                _diagnostics.secureInputCheckSpanNanos = 0",
  "and the span those asks cover is recorded"),

 (104, "Soredemo/Capture/InputObserver.swift",
  "        .keyDown,\n    ]",
  "        .keyDown,\n        .tabletPointer,\n    ]",
  "every event type the mask asks for is one handle() dispatches on"),

 # 124 has no product subject at all — see the report. Not runnable, by construction.

 (143, "Soredemo/Capture/CGGeometryBridge.swift",
  "        return (Double(point.x), Double(point.y))",
  "        return (0, 0)",
  "an AXValue holding a position decodes to the exact scalars it was built from"),

 (155, "Soredemo/Capture/AXObserver.swift",
  """        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX,
                                          globalTopLeftY: globalTopLeftY) else { return nil }""",
  """        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX,
                                          globalTopLeftY: globalTopLeftY)
                ?? arrangement.route(globalTopLeftX: 0, globalTopLeftY: 0) else { return nil }""",
  "a frame whose origin is on no attached display normalises to nothing"),

 (170, "Soredemo/Capture/AXObserver.swift",
  "public nonisolated static let depthCap = 30",
  "public nonisolated static let depthCap = 8",
  "exactly depthCap ancestors were recorded"),

 (184, "Soredemo/Capture/InputObserver.swift",
  """        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX,
                                          globalTopLeftY: globalTopLeftY) else { return nil }
        // Step 3 — display-local points → display-local native pixels.
        let pixels = hit.geometry.pixels(
            from: PointRect(x: hit.localX, y: hit.localY, width: 0, height: 0))""",
  """        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX,
                                          globalTopLeftY: globalTopLeftY) else { return nil }
        if globalTopLeftX > 0 { return nil }
        // Step 3 — display-local points → display-local native pixels.
        let pixels = hit.geometry.pixels(
            from: PointRect(x: hit.localX, y: hit.localY, width: 0, height: 0))""",
  "the fixture click must convert"),

 (191, "Soredemo/Capture/AXObserver.swift",
  "case .doesNotContainTheClick: tally.clickOutsideTheHitFrame = 1",
  "case .doesNotContainTheClick: tally.clickOutsideTheHitFrame = 0",
  "and it lands in the counter that reads as 'the coordinate path is wrong'"),

 (192, "Soredemo/Capture/AXObserver.swift",
  """        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX,
                                          globalTopLeftY: globalTopLeftY) else { return nil }
        // Step 3 — display-local points → display-local native pixels.
        let pixels = hit.geometry.pixels(
            from: PointRect(x: hit.localX, y: hit.localY, width: width, height: height))""",
  """        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX + width / 2,
                                          globalTopLeftY: globalTopLeftY + height / 2) else { return nil }
        // Step 3 — display-local points → display-local native pixels.
        let pixels = hit.geometry.pixels(
            from: PointRect(x: hit.localX, y: hit.localY, width: width, height: height))""",
  "fixture sanity: that element's frame normalised against the OTHER display"),

 (272, "Soredemo/Capture/ObservationWriter.swift",
  "        case .inputMonitoringUnavailable: .inputMonitoringUnavailable",
  "        case .inputMonitoringUnavailable: nil",
  "CaptureError maps to the header field, in one place"),

 (294, "Sources/Project/ObservationLog.swift",
  "    public var isAMeasurement: Bool { looks > 0 }",
  "    public var isAMeasurement: Bool { looks > 1 }",
  "a site that was watched and found nothing reports zero gaps AND says something"),

 (299, "Sources/Project/ObservationLog.swift",
  '''        if !isAMeasurement { line += "   ← NOTHING WAS LOOKING; the count left of the arrow is not a measurement" }''',
  '''        if !isAMeasurement { line += "   ← nothing observed here" }''',
  "and the printed form says so where a person will read it"),

 (302, "Soredemo/Capture/ObservationWriter.swift",
  "        lock.withLock { if recordCounts[kind] == nil { recordCounts[kind] = 0 } }",
  "        lock.withLock { _ = kind }",
  "a kind the producer declared and never saw is `0`, not absent"),

 (313, "Soredemo/UI/ProjectDocument.swift",
  "    func acceptMedia(_ data: Data, named name: String) throws {\n        try addMedia(data, named: name)\n    }",
  """    func acceptMedia(_ data: Data, named name: String) throws {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        try ProjectPackageIO.writeSidecar(data, named: name, into: packageURL)
    }""",
  "and its bytes are the ones that were handed over"),

 (323, "Soredemo/Capture/ObservationWriter.swift",
  "        try lock.withLock { try writeLineLocked(bytes, kind: kind, counted: counted) }",
  "        try writeLineLocked(bytes, kind: kind, counted: counted)",
  "no append failed under"),

 (336, "Sources/Project/ProjectPackageIO.swift",
  "            if !referenced.contains(named) { dangling.append(entry.lastPathComponent) }",
  "            if referenced.contains(named) { dangling.append(entry.lastPathComponent) }",
  "a log whose header names media the manifest does not reference is reported"),
 # ---- second attempts, after the first mutation proved to be aimed elsewhere.
 (1700, "Soredemo/Capture/AXObserver.swift",
  "        for depth in 0..<Self.depthCap {",
  "        for depth in 0..<(Self.depthCap - 1) {",
  "exactly depthCap ancestors were recorded"),

 (3130, "Soredemo/UI/ProjectDocument.swift",
  """    func addMedia(_ data: Data, named name: String) throws -> String {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        try ProjectPackageIO.writeSidecar(data, named: name, into: packageURL)""",
  """    func addMedia(_ data: Data, named name: String) throws -> String {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        try ProjectPackageIO.writeSidecar(data.dropLast(), named: name, into: packageURL)""",
  "and its bytes are the ones that were handed over"),

 (3230, "Soredemo/Capture/ObservationWriter.swift",
  '        guard !bytes.contains(UInt8(ascii: "\\n")) else {',
  '        guard bytes.contains(UInt8(ascii: "\\n")) else {',
  "no append failed under"),
 # A bounded-capacity writer: appends start being refused past 1000 records of a
 # kind. Narrow on purpose — the earlier `recordSpansTwoLines` inversion also
 # broke the HEADER write, which killed the probe at the first log it opened.
 (3231, "Soredemo/Capture/ObservationWriter.swift",
  """        try ObservationLog.checkEpoch(of: record, against: header.epoch)
        try writeLine(try ObservationLog.encode(record), kind: record.kind, counted: true)""",
  """        try ObservationLog.checkEpoch(of: record, against: header.epoch)
        if lock.withLock({ recordCounts[record.kind, default: 0] }) > 1000 {
            throw WriterError.logIsClosed
        }
        try writeLine(try ObservationLog.encode(record), kind: record.kind, counted: true)""",
  "no append failed under"),
]



SDK = "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"


def run_probe():
    # The login profile exports SDKROOT pointing at the CommandLineTools SDK
    # (26.5), while `swift build` uses Xcode-beta's (27.0). Inheriting it makes
    # every run fail identically on "cannot load module built with SDK 27.0",
    # which reads exactly like a mutation that broke the build.
    env = {**os.environ, "SDKROOT": SDK}
    r = subprocess.run(["./scripts/run-cross-boundary-probe.sh"], cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=900)
    return r.returncode, r.stdout + r.stderr


def verdict_for(out, target):
    fail = [l for l in out.splitlines() if l.startswith("  FAIL") and target in l]
    ok = [l for l in out.splitlines() if l.startswith("  ok") and target in l]
    if fail:
        return "RED"
    if ok:
        return "still green"
    return "did not run"


results = []
only = [int(a) for a in sys.argv[1:]] or None
for idx, rel, old, new, target in M:
    if only and idx not in only:
        continue
    path = ROOT / rel
    src = path.read_text()
    n = src.count(old)
    if n != 1:
        results.append((idx, rel, f"PATCH ANCHOR MATCHED {n} TIMES", "", 0))
        print(f"[{idx}] anchor matched {n} times — skipped", flush=True)
        continue
    path.write_text(src.replace(old, new))
    try:
        rc, out = run_probe()
        (OUT / f"mut-{idx}.txt").write_text(out)
        built = "PROBE PASSED" in out or "  ok " in out or "  FAIL" in out
        v = verdict_for(out, target) if built else "DID NOT BUILD"
        nfail = sum(1 for l in out.splitlines() if l.startswith("  FAIL"))
        results.append((idx, rel, v, "", nfail))
        print(f"[{idx}] {v:14s}  ({nfail} total FAILs)  {rel}", flush=True)
    finally:
        path.write_text(src)

(OUT / "certify-results.json").write_text(json.dumps(results, indent=1))
