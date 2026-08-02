// The **app** half of three checks that no test target in this repository can
// perform, because all three live on the app side of the package boundary and
// the app has no test target (and, per the Task 18 brief, is not getting one).
//
//   1. The cross-boundary SHA-256 vector. `Tests/GraphTests/CrossBoundaryDigestVectorTests.swift`
//      pins the canonical bytes and the expected digest but **cannot hash** —
//      the package has no CryptoKit, by D6. This runs `Minting.digest(of:)`
//      over those same bytes and compares against that same constant, closing
//      the link `approval-gate` binds on.
//
//   2. `ProjectDocument.writeSafely` does not destroy media. `NSDocument`'s
//      inherited implementation builds the whole document in a temporary
//      directory and swaps it into place; this document's `write(to:ofType:)`
//      writes the manifest alone, by design (D-P3), so inheriting that
//      behaviour would leave a package whose `media/` had been emptied. The
//      override is the mechanism and this is the assertion that watches it.
//
//   3. `CGGeometryBridge` converts correctly. Its argument types are the four
//      CoreGraphics types the package may not name, so no package test can
//      call it. The later CG allow-list task checks that the bridge is the
//      only file that *names* those types; nothing there checks that the
//      conversion is right.
//
// Two more were added after this comment's "three" was written and never
// renumbered — the boot epoch and host clock (Task 5, § 4 below), and now
// `CaptureSource.geometry()` (Task 7, § 5): a window's frame must be
// **absent** from the digest and its output buffer size must be **present**,
// which is a claim about `Soredemo/Capture/CaptureSource.swift`'s actual
// behaviour and needs the real `SCDisplay`/`SCWindow` types no package test
// can name. Left as "three" above rather than silently corrected to "five" —
// the drift is itself the demonstration of this file's own opening claim,
// that nothing here runs automatically enough for a stale count to be caught.
//
// **This is not a standing regression test.** Nothing runs it automatically:
// `swift test` cannot see it and there is no app test target to host it. It is
// run by hand, and the Task 18 report records the observation. Making it a real
// test needs an app-side unit-test bundle in `Soredemo.xcodeproj`, which is a
// pbxproj change and therefore an owner step.
//
// Run it with:
//
//     scripts/run-cross-boundary-probe.sh
//
// It compiles the REAL `Soredemo/Support/Minting.swift`,
// `Soredemo/Capture/CGGeometryBridge.swift` and `Soredemo/UI/ProjectDocument.swift`
// — not copies — against the package's debug build products, so it cannot drift
// away from what the app ships.
//
// **Note for the CG allow-list task:** this file names `CGRect` and is not app
// code. Rule 5 is about the app target; scope the scan to `Soredemo/`.
//
// **`CapturePermissions` (`Soredemo/Capture/CapturePermissions.swift`) is
// deliberately NOT compiled into this probe, and no permission dump belongs
// here.** This binary is `swiftc`-compiled straight to a temp path — a bare
// executable with **no bundle identity**. TCC does not attribute a request
// to the binary that made it; it attributes it to the *responsible process*,
// walked up the parent chain to whatever launched this one. Measured: run
// this probe from a shell, and any permission read inside it reports the
// SHELL's grants, not `video.soredemo.Soredemo`'s — four confident-looking
// "granted"s for a process that held none of them, discovered only because a
// human's own read of System Settings was recorded before the probe ran and
// the two disagreed. `docs/design/2026-08-01-phase-1-carried-forward.md`
// already says why the probe has no bundle identity; this is that fact
// mattering somewhere concrete rather than staying a footnote.
//
// **The permission dump lives in `Soredemo/App/SoredemoApp.swift`'s
// `init()`, gated behind `--dump-permissions`, run as the actual app
// executable** (`Soredemo.app/Contents/MacOS/Soredemo --dump-permissions`)
// — the one invocation that runs under the app's own bundle identity and so
// is the one invocation TCC can attribute to it. If you are adding a
// permission-related check, it belongs beside that one, not here — this
// probe cannot answer an identity-scoped question no matter how it is
// phrased.

import AppKit
import CoreGraphics
import Foundation
import Geometry
import Graph
import Project
@preconcurrency import ScreenCaptureKit

// Kept byte-identical to `Tests/GraphTests/CrossBoundaryDigestVectorTests.swift`.
// The two literals ARE the vector; that file checks the left-hand one against
// `DisplayGeometry.canonicalBytes`, this one checks the arrow between them.
let pinnedCanonicalBytesHex =
    "016ba7b8109dad11d180b400c04fd430c8"
    + "000f00000000000070080000000000000000000000000040"
let pinnedSHA256Hex =
    "564a19db7b51ffcdccc38bacde29f69fb293d833e85f574c5db9434d45db3bfe"

func bytes(fromHex string: String) -> [UInt8] {
    var result: [UInt8] = []
    var pending: Character?
    for character in string {
        if let high = pending {
            result.append(UInt8(String([high, character]), radix: 16)!)
            pending = nil
        } else {
            pending = character
        }
    }
    precondition(pending == nil, "odd-length hex string")
    return result
}

/// A `stat(2)` per call, never `URL.resourceValues`.
///
/// `AGENTS.md` § "The instrument can have state": `NSURL` caches resource
/// values per instance, so `.fileResourceIdentifierKey` read twice through the
/// same `URL` binding returns the identical value across a replace that
/// genuinely changed the inode — and the stale read makes a *correct*
/// implementation look broken. `attributesOfItem(atPath:)` re-`stat`s.
///
/// A missing `.systemFileNumber` returns **no value**, never a sentinel:
/// falling back to `0` would make every inode comparison in this file read
/// `0 == 0` and pass vacuously — `AGENTS.md`'s vacuous-pass shape, inside the
/// one function written to satisfy the instrument rule. An instrument that
/// cannot read must say so, not read zero.
func inode(of url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    precondition(number != nil, "no .systemFileNumber for \(url.path) — the instrument cannot read")
    precondition(number != 0, "systemFileNumber 0 for \(url.path) — no real inode is 0")
    return number!
}

@MainActor var failures = 0
@MainActor var checksRun = 0

@MainActor
func check(_ condition: Bool, _ label: String, actual: String = "", expected: String = "") {
    checksRun += 1
    if condition {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)")
        if !actual.isEmpty { print("        actual:   \(actual)") }
        if !expected.isEmpty { print("        expected: \(expected)") }
    }
}

@main
enum CrossBoundaryProbe {
    @MainActor
    static func main() async throws {
        print("1. cross-boundary SHA-256 vector")
        let canonicalBytes = bytes(fromHex: pinnedCanonicalBytesHex)
        check(canonicalBytes.count == 41, "canonical bytes are the frozen 41-byte width",
              actual: "\(canonicalBytes.count)", expected: "41")

        let computed = Minting.digest(of: canonicalBytes)
        let expected = ContentDigest(bytes(fromHex: pinnedSHA256Hex))
        check(computed == expected, "Minting.digest(of:) reproduces the pinned digest",
              actual: computed.description, expected: expected.description)
        print("        input:  \(pinnedCanonicalBytesHex)")
        print("        digest: \(computed.description)")

        print("2. ProjectDocument.writeSafely preserves media")
        try mediaSurvivesSave()

        print("2b. ProjectDocument.read takes media from the manifest")
        try readTakesMediaFromTheManifestNotTheDirectory()

        print("3. CGGeometryBridge")
        bridgeConverts()

        print("4. boot epoch and the host clock")
        epochAndClock()

        print("5. CaptureSource.geometry() — D2-13: a window's frame is extrinsic")
        try await captureSourceGeometry()

        // The count is printed, never written down: a hand-maintained total in
        // a report goes stale the first time a check is added and nobody
        // notices, which is what happened to this one.
        print(failures == 0
              ? "PROBE PASSED (\(checksRun) checks)"
              : "PROBE FAILED (\(failures) of \(checksRun) checks)")
        if failures != 0 { exit(1) }
    }

    /// Saves a document that already has a media sidecar on disk, and asserts
    /// the sidecar is still there, still the same file, and still referenced.
    ///
    /// The mutation this is aimed at is `writeSafely` falling back to
    /// `super` — see the file header. The inode check is what makes it more
    /// than an existence check: a save that copied the package would leave a
    /// file with the same name and a different inode.
    @MainActor
    static func mediaSurvivesSave() throws {
        let fm = FileManager.default
        let packageURL = fm.temporaryDirectory
            .appending(path: "t18-probe-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: packageURL) }

        // A package with one media sidecar, referenced by the manifest.
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(),
                            mediaFilenames: []),
            to: packageURL
        )
        let footage = Data(repeating: 0xAB, count: 1 << 16)
        try ProjectPackageIO.writeSidecar(footage, named: "clip.mov", into: packageURL)
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(),
                            mediaFilenames: ["clip.mov"]),
            to: packageURL
        )

        let sidecarURL = packageURL.appending(path: "media/clip.mov", directoryHint: .notDirectory)
        let manifestURL = packageURL.appending(path: "project.json", directoryHint: .notDirectory)
        let sidecarInodeBefore = try inode(of: sidecarURL)
        let manifestInodeBefore = try inode(of: manifestURL)

        let document = ProjectDocument()
        document.fileURL = packageURL
        try document.read(from: packageURL, ofType: ProjectDocument.contentTypeIdentifier)
        check(document.snapshot.mediaFilenames == ["clip.mov"],
              "read(from:) decoded the manifest alone and kept the media reference",
              actual: "\(document.snapshot.mediaFilenames)", expected: #"["clip.mov"]"#)

        try document.writeSafely(to: packageURL,
                                 ofType: ProjectDocument.contentTypeIdentifier,
                                 for: .saveOperation)

        check(fm.fileExists(atPath: sidecarURL.path),
              "the media sidecar still exists after a save")
        guard fm.fileExists(atPath: sidecarURL.path) else { return }

        // **The pair is the point, not either half.** The manifest's inode must
        // change, because `replaceItemAt` is what makes the write atomic; the
        // media's must not, because a save that rewrote it would be copying
        // footage it was supposed to leave alone.
        //
        // Each half is reddened by exactly one mutation and neither can stand
        // in for the other. A save that copies media into place — same name,
        // same bytes, new inode — passes every other check in this function and
        // fails only the first. A save that writes the manifest in place
        // instead of replacing it fails only the second. Both were run; see the
        // report's mutation table.
        //
        // What does NOT reach either of them is `super.writeSafely`: it does
        // not copy `media/`, it *empties* it, so the existence check above
        // fires and the `guard` returns before these two ever execute. That is
        // precisely why they needed their own mutations — the Task 17 failure
        // was four mutations all going red while the mechanism under test was
        // never aimed at.
        check(try inode(of: sidecarURL) == sidecarInodeBefore,
              "the media sidecar is the same file, not a copy",
              actual: "\(try inode(of: sidecarURL))", expected: "\(sidecarInodeBefore)")
        check(try inode(of: manifestURL) != manifestInodeBefore,
              "project.json was atomically replaced, not written in place",
              actual: "\(try inode(of: manifestURL))",
              expected: "anything but \(manifestInodeBefore)")
        check(try Data(contentsOf: sidecarURL) == footage,
              "the media sidecar's bytes are unchanged")

        let reloaded = try ProjectPackageIO.load(from: packageURL)
        check(reloaded.mediaFilenames == ["clip.mov"],
              "the saved manifest still references the media",
              actual: "\(reloaded.mediaFilenames)", expected: #"["clip.mov"]"#)
    }

    /// `read(from:ofType:)` takes the media list from the **manifest**, never
    /// from the directory.
    ///
    /// The realistic mutation is falling back to `FileWrapper(url:options:)`,
    /// and no fixture built on *unreadable* media can catch it: measured, a
    /// `media/` at `chmod 000` makes both a lazy and an `.immediate`
    /// `FileWrapper` return successfully with nil contents — it does not
    /// complain when it cannot read something, it silently yields nothing —
    /// and a dangling symlink makes a `FileWrapper` succeed with two entries
    /// while a plain enumerate-and-read fails with `NSError 260`. Neither
    /// discriminates.
    ///
    /// What discriminates is **where the list comes from**: the manifest names
    /// two sidecars, the directory holds three. A directory-listing reader
    /// reports three; a manifest reader reports two.
    ///
    /// The third file sorts *between* the other two on purpose. It is the trap
    /// for a weaker assertion: with `argon.mov` between `alpha.mov` and
    /// `omega.mov`, a check that compared only `first` and `last` would see the
    /// same pair either way and pass against the mutation. The assertion below
    /// compares the whole array, and the ordering is what makes that
    /// non-negotiable rather than incidental.
    ///
    /// The extra file is not contrived either — an unreferenced sidecar is
    /// exactly the state `ProjectPackageIO.unreferencedSidecars` exists to
    /// describe, asserted below so the fixture is pinned as that state and not
    /// merely as clutter.
    @MainActor
    static func readTakesMediaFromTheManifestNotTheDirectory() throws {
        let fm = FileManager.default
        let packageURL = fm.temporaryDirectory
            .appending(path: "t18-probe-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: packageURL) }

        let referenced = ["alpha.mov", "omega.mov"]
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(),
                            mediaFilenames: referenced),
            to: packageURL
        )
        for name in referenced + ["argon.mov"] {
            try ProjectPackageIO.writeSidecar(Data([0x00]), named: name, into: packageURL)
        }

        let document = ProjectDocument()
        document.fileURL = packageURL
        try document.read(from: packageURL, ofType: ProjectDocument.contentTypeIdentifier)

        check(document.snapshot.mediaFilenames == referenced,
              "read(from:) reports the manifest's two names, not the directory's three",
              actual: "\(document.snapshot.mediaFilenames)", expected: "\(referenced)")
        check(try ProjectPackageIO.unreferencedSidecars(in: packageURL, snapshot: document.snapshot)
                == ["argon.mov"],
              "the third file is an unreferenced sidecar — a real state, not clutter")
    }

    /// `CGGeometryBridge` is app-side, so no package test target can name its
    /// argument types and there is nowhere else for these to live.
    ///
    /// The later CG allow-list task (plan Task 5) checks that the bridge is the
    /// only file *naming* the CG types. That is a source-text check and says
    /// nothing about whether the conversion is right — these do.
    @MainActor
    static func bridgeConverts() {
        // Off-centre origin and a non-square size: no field can be swapped for
        // another and still compare equal (`AGENTS.md`, the identity-fixture
        // table — `(0, 0)` is translation's identity and would hide exactly
        // that).
        let pixels = CGGeometryBridge.pixelRect(from: CGRect(x: 12, y: 34, width: 800, height: 600))
        check(pixels == PixelRect(x: 12, y: 34, width: 800, height: 600),
              "pixelRect(from:) maps the four fields in order",
              actual: "\(pixels)")

        // A `CGRect` dragged up and to the left carries negative dimensions.
        // `PixelRect.init` `precondition`s on non-negative, so without
        // `standardized` this would not return at all.
        let dragged = CGGeometryBridge.pixelRect(from: CGRect(x: 100, y: 100, width: -40, height: -30))
        check(dragged == PixelRect(x: 60, y: 70, width: 40, height: 30),
              "pixelRect(from:) standardizes a negative-dimension rectangle",
              actual: "\(dragged)", expected: "PixelRect(x: 60, y: 70, width: 40, height: 30)")

        let roundTripped = CGGeometryBridge.pixelRect(from: CGGeometryBridge.rect(from: pixels))
        check(roundTripped == pixels, "PixelRect → CGRect → PixelRect is the identity",
              actual: "\(roundTripped)")

        // Points and pixels are separate types precisely so this cannot be a
        // silent unit bug. `scale: 2` — at `scale: 1` the two conversions are
        // the same function and this check would pass either way.
        let geometry = DisplayGeometry(displayUUID: UUID(), pixelWidth: 3840, pixelHeight: 2160, scale: 2)
        let points = CGGeometryBridge.pointRect(from: CGRect(x: 12, y: 34, width: 800, height: 600))
        check(geometry.pixels(from: points) == PixelRect(x: 24, y: 68, width: 1600, height: 1200),
              "pointRect(from:) yields points, which scale to different pixels",
              actual: "\(geometry.pixels(from: points))")
    }

    /// `Minting.bootEpoch()`, `hostNow()` and `continuousNow()` — Task 5. No
    /// test target can reach these; they read `sysctlbyname` and
    /// `mach_absolute_time`/`mach_continuous_time` directly, on the app side
    /// of the boundary `Tests/AppSourceTests` enforces.
    ///
    /// **Left in a shape Task 6 can extend**: one `print` header per numbered
    /// section, one function per section, `check(_:_:actual:expected:)` for
    /// each assertion. Task 6's permission checks are the next section after
    /// this one, following the same pattern.
    @MainActor
    static func epochAndClock() {
        check(Minting.bootEpoch() == Minting.bootEpoch(),
              "bootEpoch is stable across reads")

        let before = Minting.hostNow()
        usleep(1000)
        let after = Minting.hostNow()
        check(after.rawValue > before.rawValue,
              "hostNow advances",
              actual: "\(after.rawValue) vs \(before.rawValue)")

        let hostTime = Minting.hostNow()
        let continuousTime = Minting.continuousNow()
        check(continuousTime.rawValue >= hostTime.rawValue,
              "continuousNow is at or ahead of hostNow",
              actual: "continuousNow=\(continuousTime.rawValue) hostNow=\(hostTime.rawValue)")

        // The gap IS the sleep (D2-4): mach_absolute_time stops during sleep,
        // mach_continuous_time does not, so continuousNow - hostNow is exactly
        // how long this machine has slept since boot. Printed, not asserted to
        // a value — the report quotes it, and a fresh boot with a gap of zero
        // is a legitimate (if suspicious) reading, not a probe failure.
        let gapNanos = continuousTime.rawValue - hostTime.rawValue
        let gapHours = Double(gapNanos) / 1e9 / 3600
        print("        continuousNow - hostNow = \(gapNanos) ns (\(String(format: "%.2f", gapHours)) h)")
        print("        bootEpoch = \(Minting.bootEpoch())")
    }

    /// `CaptureSource.geometry()` is a pure function over its own parameters
    /// — `scale`, `displayUUID`, and (for `.window`) the associated
    /// `bufferSize` tuple — and never reads the wrapped `SCWindow`'s own
    /// state. That is the whole claim D2-13 makes: a window's screen frame
    /// is extrinsic and must not enter the digest, because entering it would
    /// mint a new `GeometryRevision` on every drag, the exact failure D-P2
    /// rejected for display arrangement.
    ///
    /// Testing it needs a *real* `SCDisplay` and a *real* `SCWindow` —
    /// `SCWindow.init`/`SCDisplay.init` are `NS_UNAVAILABLE`, so there is no
    /// way to fabricate one — but the task brief is explicit that this test
    /// "needs no permission and no picker", and `SCShareableContent.current`
    /// (the general listing) does. The permission-free source is
    /// `SCShareableContent.currentProcess`
    /// (`getCurrentProcessShareableContentWithCompletionHandler:`, macOS
    /// 14.4+, below this project's floor): its header says outright that it
    /// returns content "available to capture by current process without
    /// user consent via TCC". Measured empirically before writing this
    /// (not assumed from the header alone, per `AGENTS.md`'s primary-source
    /// rule): a bare `swiftc` binary with no window returns one real
    /// `SCDisplay` and zero windows; the same binary, after creating and
    /// ordering front one real `NSWindow`, returns that window too — both
    /// with no Screen Recording grant, no picker, and no TCC prompt, on this
    /// machine (macOS 26.6). That is the fixture source below.
    ///
    /// "Do not construct a filter by hand except in the probe" (task brief)
    /// is exercised here too: `init(pickerFilter:)` is tested by handing it
    /// filters this function builds directly with `SCContentFilter`'s own
    /// initialisers — the app itself never does this; only the picker
    /// supplies a filter there.
    @MainActor
    static func captureSourceGeometry() async throws {
        let content = try await SCShareableContent.currentProcess
        guard let display = content.displays.first else {
            print("        SKIPPED — SCShareableContent.currentProcess returned no display; " +
                  "cannot construct a CaptureSource.display without one")
            return
        }

        // A real, on-screen window this process owns, so `currentProcess`
        // has something to report. Ordered front and given a moment to
        // register with the window server — the same wait used in the
        // measurement that established this technique works at all.
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 500, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "cross-boundary-digest-probe (CaptureSource)"
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))

        let beforeMove = try await SCShareableContent.currentProcess
        guard let scWindowBeforeMove = beforeMove.windows.first(where: { $0.title == window.title }) else {
            print("        SKIPPED — the probe's own window did not appear in " +
                  "SCShareableContent.currentProcess; cannot construct a CaptureSource.window")
            return
        }

        let displayUUID = UUID()          // a plain test value — the real
        let windowSourceID = UUID()       // lookup is capture-stream's job, not this pure function's.
        let bufferSize = (width: 1600, height: 1200)   // arbitrary, fixed — see D2-13.

        // ---- 1. .display — same source, two different scales, two revisions.
        // `SCDisplay.width`/`.height` come from the window server and this
        // probe must not change the real display's resolution to test this
        // (AGENTS.md's D2-10 explains why that spike was rejected). `scale`
        // is `.geometry()`'s own parameter, decoupled from the display's
        // actual backing scale, so varying IT is the controllable proxy for
        // "the captured pixel dimensions changed" — which is what a real
        // resize changes about the digest.
        let displaySource = CaptureSource.display(display)
        let displayGeometryAt1x = displaySource.geometry(scale: 1, displayUUID: displayUUID)
        let displayGeometryAt2x = displaySource.geometry(scale: 2, displayUUID: displayUUID)
        check(displayGeometryAt1x.revision != displayGeometryAt2x.revision,
              ".display: scale 1 vs scale 2 (a resize, in pixel terms) mint different revisions",
              actual: "\(displayGeometryAt1x.revision) vs \(displayGeometryAt2x.revision)")
        check(displayGeometryAt1x.pixelWidth == display.width && displayGeometryAt1x.pixelHeight == display.height,
              ".display at scale 1: pixel dimensions equal SCDisplay's own points (identity scale)",
              actual: "\(displayGeometryAt1x.pixelWidth)x\(displayGeometryAt1x.pixelHeight)",
              expected: "\(display.width)x\(display.height)")

        // ---- 2. .window — dragged (moved to a genuinely different screen
        // location, not the (0,0)-is-translation's-identity trap AGENTS.md
        // warns about), same bufferSize: identical revision.
        let windowSourceBeforeMove = CaptureSource.window(scWindowBeforeMove, bufferSize: bufferSize)
        let geometryBeforeMove = windowSourceBeforeMove.geometry(scale: 2, displayUUID: windowSourceID)

        window.setFrameOrigin(NSPoint(x: 700, y: 40))
        try await Task.sleep(for: .milliseconds(300))
        let afterMove = try await SCShareableContent.currentProcess
        guard let scWindowAfterMove = afterMove.windows.first(where: { $0.windowID == scWindowBeforeMove.windowID }) else {
            print("        SKIPPED remainder — the probe's window disappeared from " +
                  "SCShareableContent.currentProcess after being moved")
            return
        }
        check(scWindowAfterMove.frame != scWindowBeforeMove.frame,
              "the window's frame genuinely changed — not the (0,0)/identity fixture trap",
              actual: "\(scWindowBeforeMove.frame) -> \(scWindowAfterMove.frame)")

        let windowSourceAfterMove = CaptureSource.window(scWindowAfterMove, bufferSize: bufferSize)
        let geometryAfterMove = windowSourceAfterMove.geometry(scale: 2, displayUUID: windowSourceID)
        check(geometryBeforeMove.revision == geometryAfterMove.revision,
              ".window: dragging to a different screen frame does not change the revision (D2-13)",
              actual: "\(geometryBeforeMove.revision) vs \(geometryAfterMove.revision)")

        // ---- 3. .window — resized output buffer, same window, different revision.
        let smallerBufferSource = CaptureSource.window(scWindowAfterMove, bufferSize: (width: 800, height: 600))
        let smallerBufferGeometry = smallerBufferSource.geometry(scale: 2, displayUUID: windowSourceID)
        check(geometryAfterMove.revision != smallerBufferGeometry.revision,
              ".window: a different output buffer size mints a different revision",
              actual: "\(geometryAfterMove.revision) vs \(smallerBufferGeometry.revision)")
        check(smallerBufferGeometry.pixelWidth == 800 && smallerBufferGeometry.pixelHeight == 600,
              ".window: pixel dimensions come from bufferSize, not from the window's own frame",
              actual: "\(smallerBufferGeometry.pixelWidth)x\(smallerBufferGeometry.pixelHeight)")

        // ---- 4. init(pickerFilter:) — never hand-built in the app; built by
        // hand here only, per the header comment above.
        let displayFilter = SCContentFilter(display: display, excludingWindows: [])
        guard let derivedDisplaySource = CaptureSource(pickerFilter: displayFilter) else {
            check(false, "CaptureSource(pickerFilter:) derives a .display from a display-style filter")
            return
        }
        if case .display(let derivedDisplay) = derivedDisplaySource {
            check(derivedDisplay.displayID == display.displayID,
                  "CaptureSource(pickerFilter:) picked the same SCDisplay the filter names")
        } else {
            check(false, "CaptureSource(pickerFilter:) returned .window for a display-style filter")
        }

        let windowFilter = SCContentFilter(desktopIndependentWindow: scWindowAfterMove)
        guard let derivedWindowSource = CaptureSource(pickerFilter: windowFilter) else {
            check(false, "CaptureSource(pickerFilter:) derives a .window from a window-style filter")
            return
        }
        if case .window(let derivedWindow, let derivedBufferSize) = derivedWindowSource {
            check(derivedWindow.windowID == scWindowAfterMove.windowID,
                  "CaptureSource(pickerFilter:) picked the same SCWindow the filter names")
            // The filter's own contentRect/pointPixelScale, not the fixed
            // 1600x1200/800x600 test values above — this is what the real
            // picker path derives, unlike the two synthetic sources tested
            // above it. Printed rather than pinned to an exact value: the
            // window's true on-screen pixel size depends on this machine's
            // backing scale and window chrome, neither of which this probe
            // controls.
            print("        picker-derived window bufferSize = \(derivedBufferSize.width)x\(derivedBufferSize.height)")
            check(derivedBufferSize.width > 0 && derivedBufferSize.height > 0,
                  "CaptureSource(pickerFilter:) derives a positive buffer size from the filter's contentRect")
        } else {
            check(false, "CaptureSource(pickerFilter:) returned .display for a window-style filter")
        }
    }
}
