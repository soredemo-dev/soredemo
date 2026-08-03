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

REDDENING IS NECESSARY AND NOT SUFFICIENT, WHICH IS WHY EVERY ENTRY CARRIES A FAULT CLASS.

The sixth field of each entry names the kind of fault the check exists to catch, and the mutation
must be an INSTANCE of it. Without that field the format certifies the wrong property: that some
change somewhere can make the check fail. All three checks that took a second mutation here would
have passed a verdict-only format, each in a different disguise —

    capped.ancestors.count == depthCap   reddens on the walk, never on the constant it compares to
    survivorBytes == routedBytes         reddens, but not under the mutation its own comment names
    failures.count == 0 (8 writers)      its own fault is a SEGFAULT, which is not a FAIL at all

— and the first pass supplied the missing half by hand, because the format did not ask for it.
Now it does, and the runner refuses to run at all if any entry leaves it blank, rather than
discovering it mid-run when the cheapest fix is to fill it in with whatever unblocks the run.

THIS IS NOT RETROACTIVE. The other 338 written checks are NOT to be re-certified under the new
field. The sample exists precisely so that nobody has to do that; 19 of 20 is an estimate of the
suite, and an estimate does not become a work order by being written down more carefully. The
rule governs certificates issued from here on. A tightened rule that silently commissions a
migration is how a standard stops being affordable, and this one has to stay affordable — it is
about to be applied three hundred times in Phase 2B and beyond.

Restoration is in a `finally`, and the tree is checked clean afterwards. If this process is killed
mid-run, one product file is left mutated; `git status` will say which.
"""
import subprocess, sys, json, pathlib, os

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(os.environ.get("SCRATCH", "/tmp"))

M = [
 # (index, file, old, new, target-substring-of-the-check's-label, FAULT CLASS)
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
  "no available displays returns nil for a window, not a fallback size",
  "a derivation with no inputs substituting a plausible default instead of refusing"),

 (37, "Soredemo/Capture/CaptureSession.swift",
  "let segment = MasterSegment(index: closedSegments.count, mediaFilename: openSegment.mediaFilename,",
  "let segment = MasterSegment(index: closedSegments.count + 1, mediaFilename: openSegment.mediaFilename,",
  "the first segment is index 0",
  "segment indices that no longer address the segments they name"),

 (73, "Soredemo/Capture/InputObserver.swift",
  """        let position = NormalizationContext(geometry: hit.geometry)
            .normalize(topLeftX: pixels.x, topLeftY: pixels.y)
        return (position, hit.geometry.revision)""",
  """        let position = NormalizationContext(geometry: hit.geometry)
            .normalize(topLeftX: pixels.y, topLeftY: pixels.x)
        return (position, hit.geometry.revision)""",
  "the emitted pointer sample carries the converted position and the display's revision",
  "the coordinate conversion producing a plausible but wrong point"),

 (74, "Soredemo/Capture/InputObserver.swift",
  "        return HostInstant(epoch: epoch, hostTime: Nanoseconds(stampNanos))",
  "        return HostInstant(epoch: epoch, hostTime: Minting.hostNow())",
  "the sample's instant is the EVENT's own timestamp",
  "the sample timed from when the code ran instead of from when the event happened"),

 (95, "Soredemo/Capture/InputObserver.swift",
  """                _diagnostics.secureInputCheckSpanNanos =
                    max(0, instant.hostTime.rawValue - first.hostTime.rawValue)""",
  "                _diagnostics.secureInputCheckSpanNanos = 0",
  "and the span those asks cover is recorded",
  "a count reported without the span it covers, so no rate can be recovered from it"),

 (104, "Soredemo/Capture/InputObserver.swift",
  "        .keyDown,\n    ]",
  "        .keyDown,\n        .tabletPointer,\n    ]",
  "every event type the mask asks for is one handle() dispatches on",
  "the event mask and the dispatch table drifting apart, leaving a requested type unhandled"),

 # 124 has no product subject at all — see the report. Not runnable, by construction.

 (143, "Soredemo/Capture/CGGeometryBridge.swift",
  "        return (Double(point.x), Double(point.y))",
  "        return (0, 0)",
  "an AXValue holding a position decodes to the exact scalars it was built from",
  "an AX decode failing into a legal-looking zero instead of nil"),

 (155, "Soredemo/Capture/AXObserver.swift",
  """        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX,
                                          globalTopLeftY: globalTopLeftY) else { return nil }""",
  """        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX,
                                          globalTopLeftY: globalTopLeftY)
                ?? arrangement.route(globalTopLeftX: 0, globalTopLeftY: 0) else { return nil }""",
  "a frame whose origin is on no attached display normalises to nothing",
  "an off-display coordinate normalised against whichever display happens to be first"),

 (170, "Soredemo/Capture/AXObserver.swift",
  "public nonisolated static let depthCap = 30",
  "public nonisolated static let depthCap = 8",
  "exactly depthCap ancestors were recorded",
  "the ancestor walk recording the wrong number of levels"),

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
  "the fixture click must convert",
  "the fixture's own conversion failing silently, leaving the section measuring nothing"),

 (191, "Soredemo/Capture/AXObserver.swift",
  "case .doesNotContainTheClick: tally.clickOutsideTheHitFrame = 1",
  "case .doesNotContainTheClick: tally.clickOutsideTheHitFrame = 0",
  "and it lands in the counter that reads as 'the coordinate path is wrong'",
  "a coordinate fault disappearing instead of landing in the counter that names it"),

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
  "fixture sanity: that element's frame normalised against the OTHER display",
  "a frame routed to the wrong display, making a cross-display comparison look comparable"),

 (272, "Soredemo/Capture/ObservationWriter.swift",
  "        case .inputMonitoringUnavailable: .inputMonitoringUnavailable",
  "        case .inputMonitoringUnavailable: nil",
  "CaptureError maps to the header field, in one place",
  "a permission failure not reaching the header field a reader uses to judge blindness"),

 (294, "Sources/Project/ObservationLog.swift",
  "    public var isAMeasurement: Bool { looks > 0 }",
  "    public var isAMeasurement: Bool { looks > 1 }",
  "a site that was watched and found nothing reports zero gaps AND says something",
  "a zero that was never measured reported as a zero that was"),

 (299, "Sources/Project/ObservationLog.swift",
  '''        if !isAMeasurement { line += "   ← NOTHING WAS LOOKING; the count left of the arrow is not a measurement" }''',
  '''        if !isAMeasurement { line += "   ← nothing observed here" }''',
  "and the printed form says so where a person will read it",
  "the caveat missing from the printed form the person actually reads"),

 (302, "Soredemo/Capture/ObservationWriter.swift",
  "        lock.withLock { if recordCounts[kind] == nil { recordCounts[kind] = 0 } }",
  "        lock.withLock { _ = kind }",
  "a kind the producer declared and never saw is `0`, not absent",
  "a declared-but-unseen record kind becoming indistinguishable from one never declared"),

 (313, "Soredemo/UI/ProjectDocument.swift",
  "    func acceptMedia(_ data: Data, named name: String) throws {\n        try addMedia(data, named: name)\n    }",
  """    func acceptMedia(_ data: Data, named name: String) throws {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        try ProjectPackageIO.writeSidecar(data, named: name, into: packageURL)
    }""",
  "and its bytes are the ones that were handed over",
  "media stored differing from the media handed over"),

 (323, "Soredemo/Capture/ObservationWriter.swift",
  "        try lock.withLock { try writeLineLocked(bytes, kind: kind, counted: counted) }",
  "        try writeLineLocked(bytes, kind: kind, counted: counted)",
  "no append failed under",
  "appends refused under concurrency while the log still looks complete"),

 (336, "Sources/Project/ProjectPackageIO.swift",
  "            if !referenced.contains(named) { dangling.append(entry.lastPathComponent) }",
  "            if referenced.contains(named) { dangling.append(entry.lastPathComponent) }",
  "a log whose header names media the manifest does not reference is reported",
  "a dangling join key going unreported"),
 # ---- second attempts, after the first mutation proved to be aimed elsewhere.
 (1700, "Soredemo/Capture/AXObserver.swift",
  "        for depth in 0..<Self.depthCap {",
  "        for depth in 0..<(Self.depthCap - 1) {",
  "exactly depthCap ancestors were recorded",
  "the ancestor walk recording the wrong number of levels"),

 (3130, "Soredemo/UI/ProjectDocument.swift",
  """    func addMedia(_ data: Data, named name: String) throws -> String {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        try ProjectPackageIO.writeSidecar(data, named: name, into: packageURL)""",
  """    func addMedia(_ data: Data, named name: String) throws -> String {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        try ProjectPackageIO.writeSidecar(data.dropLast(), named: name, into: packageURL)""",
  "and its bytes are the ones that were handed over",
  "media stored differing from the media handed over"),

 (3230, "Soredemo/Capture/ObservationWriter.swift",
  '        guard !bytes.contains(UInt8(ascii: "\\n")) else {',
  '        guard bytes.contains(UInt8(ascii: "\\n")) else {',
  "no append failed under",
  "appends refused under concurrency while the log still looks complete"),
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
  "no append failed under",
  "appends refused under concurrency while the log still looks complete"),
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


# The sixth field is not optional, and this is where that is true rather than in a
# comment. An entry with a blank fault class stops the whole run before a single
# build: a certificate is worthless if nobody had to say what the mutation was an
# instance of, and a missing field discovered halfway through a run gets filled in
# to unblock the run.
blank = [m[0] for m in M if len(m) < 6 or not str(m[5]).strip()]
if blank:
    sys.exit(f"entries {blank} declare no fault class — see this file's header. "
             "Nothing was run and nothing was mutated.")

results = []
only = [int(a) for a in sys.argv[1:]] or None
for idx, rel, old, new, target, fault in M:
    if only and idx not in only:
        continue
    path = ROOT / rel
    src = path.read_text()
    n = src.count(old)
    if n != 1:
        results.append((idx, rel, f"PATCH ANCHOR MATCHED {n} TIMES", fault, 0))
        print(f"[{idx}] anchor matched {n} times — skipped", flush=True)
        continue
    path.write_text(src.replace(old, new))
    try:
        rc, out = run_probe()
        (OUT / f"mut-{idx}.txt").write_text(out)
        built = "PROBE PASSED" in out or "  ok " in out or "  FAIL" in out
        v = verdict_for(out, target) if built else "DID NOT BUILD"
        nfail = sum(1 for l in out.splitlines() if l.startswith("  FAIL"))
        results.append((idx, rel, v, fault, nfail))
        print(f"[{idx}] {v:14s}  ({nfail} total FAILs)  {rel}", flush=True)
        print(f"        is this mutation an instance of: {fault}?", flush=True)
    finally:
        path.write_text(src)

(OUT / "certify-results.json").write_text(json.dumps(results, indent=1))
print("\nRED is necessary and not sufficient: the mutation must be an INSTANCE of the fault class,\n"
      "not merely something that makes the check fail. For each row above, answer the question\n"
      "printed under it before recording a certificate. The three checks that needed a second\n"
      "mutation here each missed in a different way — one stayed green with nothing reddening\n"
      "(170), one reddened three neighbours and not itself (313), one killed the probe outright\n"
      "with no verdict at all (323). A verdict column alone tells those three apart from a real\n"
      "certificate in exactly none of the cases.")
