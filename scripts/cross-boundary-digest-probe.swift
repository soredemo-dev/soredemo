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
// `kVK_ANSI_*` for § 7's keyboard fixtures — the same layout-independent key
// positions `InputObserver.approvedShortcuts` is written against, so the two
// cannot drift into disagreeing about which key is which.
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Geometry
import Graph
import Project
@preconcurrency import ScreenCaptureKit
// `Nanoseconds.rawValue` (§ 4, epochAndClock) is `Timeline`'s, reached until
// now only transitively through `Project` → `Graph` → `Timeline`. Harmless
// under a plain `swiftc` invocation; `-enable-upcoming-feature
// MemberImportVisibility` (added to this probe's flags alongside the app's
// other isolation semantics) no longer allows it — a real, pre-existing gap
// this flag surfaced rather than introduced.
import Timeline

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

        print("6. SegmentLedger — segment lifecycle against a fake frame source (Task 8)")
        segmentLedgerLifecycle()

        print("7. InputObserver — the conversion boundary's first caller (Task 9)")
        print("7.1 the four-step conversion, against a scale: 2 fixture display")
        theConversionOrder()
        print("7.2 the callback body, driven by synthetic CGEvents")
        theCallbackBody()
        print("7.3 keystrokes are not stored")
        keystrokesAreNotStored()
        print("7.4 secure input produces an interval, not silence")
        secureInputProducesAnInterval()
        print("7.5 the event mask asks for exactly what handle() dispatches on")
        theEventMaskMatchesTheDispatchTable()
        print("7.6 currentArrangement() — the ambient reader, against AppKit")
        theAmbientArrangement()
        print("7.7 the PRODUCTION secure-input predicate is really read")
        theProductionSecureInputPredicateIsRead()

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

        // `location(from:)` — Task 9's addition, the entry point for a
        // `CGEvent`'s global position. Fractional and negative on purpose: a
        // display placed above or to the left of the main one has a negative
        // global origin (`DisplayArrangement.Placement` says so explicitly),
        // and a truncation to `Int` somewhere in the conversion would survive
        // any whole-number fixture.
        let location = CGGeometryBridge.location(from: CGPoint(x: 12.5, y: -34.25))
        check(location.x == 12.5 && location.y == -34.25,
              "location(from:) carries a fractional, negative CGPoint across unchanged",
              actual: "(\(location.x), \(location.y))", expected: "(12.5, -34.25)")
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
    /// is exercised here too: `init(pickerFilter:availableDisplays:)` is
    /// tested by handing it filters this function builds directly with
    /// `SCContentFilter`'s own initialisers — the app itself never does
    /// this; only the picker supplies a filter there.
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

        // ---- 4. init(pickerFilter:availableDisplays:) — never hand-built in
        // the app; built by hand here only, per the header comment above.
        let displayFilter = SCContentFilter(display: display, excludingWindows: [])
        guard let derivedDisplaySource = CaptureSource(pickerFilter: displayFilter, availableDisplays: [display])
        else {
            check(false, "CaptureSource(pickerFilter:) derives a .display from a display-style filter")
            return
        }
        if case .display(let derivedDisplay) = derivedDisplaySource {
            check(derivedDisplay.displayID == display.displayID,
                  "CaptureSource(pickerFilter:) picked the same SCDisplay the filter names")
        } else {
            check(false, "CaptureSource(pickerFilter:) returned .window for a display-style filter")
        }

        // D2-13a: the window case's bufferSize is DISPLAY-sized, derived
        // from `availableDisplays`, not from the filter's own `contentRect`
        // (which reports the window's own, smaller, current size — printed
        // below for contrast, exactly the number this derivation must NOT
        // produce). `windowFilter.contentRect` needs no bridge here: this is
        // the probe, not app code, and rule 5 scopes to `Soredemo/`.
        let windowFilter = SCContentFilter(desktopIndependentWindow: scWindowAfterMove)
        print("        window's own filter.contentRect = \(windowFilter.contentRect), " +
              "pointPixelScale = \(windowFilter.pointPixelScale) — NOT the bufferSize input under D2-13a")
        guard let derivedWindowSource = CaptureSource(pickerFilter: windowFilter, availableDisplays: [display])
        else {
            check(false, "CaptureSource(pickerFilter:) derives a .window from a window-style filter")
            return
        }
        if case .window(let derivedWindow, let derivedBufferSize) = derivedWindowSource {
            check(derivedWindow.windowID == scWindowAfterMove.windowID,
                  "CaptureSource(pickerFilter:) picked the same SCWindow the filter names")
            // The expected pixel size is the DISPLAY's, at the filter's own
            // pointPixelScale (see `init(pickerFilter:availableDisplays:)`'s
            // doc comment for why that scale, not a separately-looked-up
            // display scale). Pinned to a computed expectation, not merely
            // "positive" — a regression back to contentRect-sizing would
            // still be positive and would pass a weaker check.
            let expectedWidth = Int((Double(display.width) * Double(windowFilter.pointPixelScale)).rounded())
            let expectedHeight = Int((Double(display.height) * Double(windowFilter.pointPixelScale)).rounded())
            check(derivedBufferSize.width == expectedWidth && derivedBufferSize.height == expectedHeight,
                  "CaptureSource(pickerFilter:) derives a DISPLAY-sized buffer (D2-13a), not a window-sized one",
                  actual: "\(derivedBufferSize.width)x\(derivedBufferSize.height)",
                  expected: "\(expectedWidth)x\(expectedHeight)")
            // And the display-sized buffer is strictly larger than the
            // window's own content, on this machine — the property D2-13a's
            // "D strictly dominates" argument rests on.
            //
            // **Not discriminating on its own — recorded, not fixed, per
            // AGENTS.md's mutation-granularity rule.** A `>=` comparison is
            // still satisfied when the two sides are equal, which is exactly
            // what happens if this regresses to window-content-sizing (the
            // check above catches that regression; this one does not, on
            // its own, at this window's current size). Mutation run and
            // reverted while building this task: reverting the window
            // branch to `filter.contentRect`-based sizing reddened the
            // `==`-based check above (`1000x784` vs an expected
            // `3024x1964`) and left this `>=` check green. Kept anyway,
            // because it states a property (the buffer strictly dominates
            // the window) that is worth asserting on its own terms, not as
            // a substitute for the check above.
            check(derivedBufferSize.width >= Int(windowFilter.contentRect.width * CGFloat(windowFilter.pointPixelScale)),
                  "the derived buffer is at least as wide as the window's own content, in pixels")
        } else {
            check(false, "CaptureSource(pickerFilter:) returned .display for a window-style filter")
        }

        // ---- 5. init(pickerFilter:availableDisplays:) with no displays
        // supplied: a window selection must fail rather than silently fall
        // back to the window's own size (`AGENTS.md`: a measurement/derivation
        // has no safe default).
        let noDisplaysSource = CaptureSource(pickerFilter: windowFilter, availableDisplays: [])
        check(noDisplaysSource == nil,
              "CaptureSource(pickerFilter:) with no available displays returns nil for a window, not a fallback size")
    }

    /// `SegmentLedger` (`Soredemo/Capture/CaptureSession.swift`) is Task 8's
    /// "yours" half: segment lifecycle bookkeeping with no
    /// `ScreenCaptureKit`, no `AVFoundation`, no permission, no picker. A
    /// "fake frame source" here is nothing more than a sequence of
    /// synthetic `HostInstant`s and `SegmentBoundary`s fed straight to
    /// `openSegment`/`closeSegment` — there is no real stream to fake,
    /// because this type never touches one; every value it holds is a
    /// parameter its caller supplied (see the type's own doc comment).
    ///
    /// **Correction to the task brief's own Step 4 sample.** The brief's
    /// spike checklist includes `table.segments.allSatisfy { $0.endedBy !=
    /// nil }`. `MasterSegment.endedBy` is typed `SegmentBoundary`, not
    /// `SegmentBoundary?` (`Sources/Project/SegmentTable.swift`) — that line
    /// does not compile as written, and the property it is testing for is
    /// not a runtime condition at all: `MasterSegment`'s initialiser
    /// requires `endedBy` unconditionally, so "every segment has a boundary
    /// reason" is a compile-time guarantee, not something a test needs to
    /// observe — a gap here would be a type the compiler refuses to build,
    /// not a value at runtime. What is worth checking instead, and what
    /// actually distinguishes correct code from a plausible mutation, is
    /// that the RIGHT boundary reason lands on the RIGHT segment — which is
    /// what every check below asserts directly, rather than re-deriving a
    /// vacuous one the type system already guarantees.
    @MainActor
    static func segmentLedgerLifecycle() {
        let epoch = Minting.bootEpoch()
        func instant(_ nanos: Int64) -> HostInstant {
            HostInstant(epoch: epoch, hostTime: Nanoseconds(nanos))
        }
        // Two DISTINCT, non-zero revisions — `id: 0` would be scale/identity
        // territory (`AGENTS.md`'s fixture-diversity table), and the whole
        // point of the reconfiguration segment below is that segment 2
        // carries a DIFFERENT revision from segments 0 and 1.
        let revisionA = GeometryRevision(id: 0xAAAA_AAAA)
        let revisionB = GeometryRevision(id: 0xBBBB_BBBB)

        var ledger = SegmentLedger()
        check(!ledger.isSegmentOpen, "a fresh ledger has no open segment")

        // Segment 0: opened at t=0s, paused at t=1s.
        ledger.openSegment(at: instant(0), revision: revisionA, mediaFilename: "master-00.mov")
        check(ledger.isSegmentOpen, "openSegment makes isSegmentOpen true")
        let seg0 = ledger.closeSegment(at: instant(1_000_000_000), endedBy: .paused)
        check(!ledger.isSegmentOpen, "closeSegment makes isSegmentOpen false again")
        check(seg0.index == 0, "the first segment is index 0", actual: "\(seg0.index)")
        check(seg0.endedBy == .paused, "segment 0 closed with the boundary it was given",
              actual: "\(seg0.endedBy)")
        check(seg0.revision == revisionA, "segment 0 carries the revision it was opened with")
        check(seg0.hostRange.start == Nanoseconds(0) && seg0.hostRange.duration == Nanoseconds(1_000_000_000),
              "segment 0's HostRange is exactly [start, end) as given",
              actual: "start=\(seg0.hostRange.start.rawValue) duration=\(seg0.hostRange.duration.rawValue)")

        // Segment 1: resumed at t=2s — a real one-second GAP while paused,
        // legal (`SegmentTable` forbids overlap, not gaps) — closed by a
        // display reconfiguration that mints revisionB.
        ledger.openSegment(at: instant(2_000_000_000), revision: revisionA, mediaFilename: "master-01.mov")
        let seg1 = ledger.closeSegment(at: instant(3_000_000_000),
                                        endedBy: .displayReconfigured(newRevision: revisionB))
        check(seg1.index == 1, "the second segment is index 1", actual: "\(seg1.index)")
        check(seg1.endedBy == .displayReconfigured(newRevision: revisionB),
              "segment 1 closed with the reconfiguration boundary and the new revision it was given")

        // Segment 2: opened with the NEW revision — mirroring what
        // `CaptureSession.handleReconfiguration` actually does, immediately
        // after closing with `.displayReconfigured` — closed by `.stopped`.
        ledger.openSegment(at: instant(3_000_000_000), revision: revisionB, mediaFilename: "master-02.mov")
        let seg2 = ledger.closeSegment(at: instant(4_000_000_000), endedBy: .stopped)
        check(seg2.revision == revisionB,
              "segment 2 carries the NEW revision minted by the reconfiguration boundary, not the old one")
        check(seg2.endedBy == .stopped, "segment 2 closed with .stopped")

        let table: SegmentTable
        do {
            table = try ledger.finish()
        } catch {
            check(false, "finish() on a well-formed ledger does not throw", actual: "\(error)")
            return
        }
        check(table.segments.count == 3, "three closeSegment calls produce a three-segment SegmentTable",
              actual: "\(table.segments.count)")
        check(table.segments.map(\.index) == [0, 1, 2],
              "indices are sequential, assigned by the ledger itself, not the caller")
        check(table.segments.map(\.endedBy) == [.paused, .displayReconfigured(newRevision: revisionB), .stopped],
              "all three boundary reasons round-trip to the SegmentTable, in order",
              actual: "\(table.segments.map(\.endedBy))")
        check(table.contentDuration == Nanoseconds(3_000_000_000),
              "contentDuration sums the three segments' OWN durations (3s), not the wall-clock span, " +
              "which includes the 1s paused gap and would be 4s",
              actual: "\(table.contentDuration.rawValue)")
        // t=2.5s falls inside segment 1's [2s, 3s) — contentTime must report
        // it as 1.5s of CONTENT time (1s from segment 0 + 0.5s into segment
        // 1), not 2.5s of host time. This is the whole point of the
        // gapless-concatenation mapping `SegmentTable.contentTime(of:)`
        // exists for (D2-12 Q1) — it is what makes the 1s paused gap
        // disappear from the exported timeline while staying exactly
        // recoverable from the table.
        let midSegment1 = table.contentTime(of: instant(2_500_000_000))
        check(midSegment1 == Nanoseconds(1_500_000_000),
              "contentTime(of:) maps an instant inside segment 1 through the paused gap correctly",
              actual: "\(String(describing: midSegment1?.rawValue))")
        // t=1.5s — inside the paused GAP itself, between segment 0's end
        // and segment 1's start — is not covered by any segment's
        // HostRange, and must answer `nil`, not a nearest-edge guess
        // (`AGENTS.md`: a measurement has no safe default).
        let insideTheGap = table.contentTime(of: instant(1_500_000_000))
        check(insideTheGap == nil, "an instant inside the paused gap has no content time — nil, not a guess",
              actual: "\(String(describing: insideTheGap?.rawValue))")

        // ---- mixedEpochs: two INDIVIDUALLY well-formed segments from
        // different boot epochs must not silently produce a table with a
        // meaningless combined duration. Each segment's own open/close pair
        // is internally consistent — `SegmentLedger.closeSegment` traps if
        // `end`'s epoch does not match its own segment's `start` (see that
        // method's doc comment), so there is no way to construct an
        // internally-mismatched segment through this type at all — so this
        // is a genuine CROSS-segment check, reaching `SegmentTable.init`'s
        // own guard exactly the way two segments spliced from different
        // recordings would (D2-11).
        let otherEpoch = BootEpoch(id: UUID())
        func otherInstant(_ nanos: Int64) -> HostInstant {
            HostInstant(epoch: otherEpoch, hostTime: Nanoseconds(nanos))
        }
        var mixedLedger = SegmentLedger()
        mixedLedger.openSegment(at: instant(0), revision: revisionA, mediaFilename: "master-00.mov")
        _ = mixedLedger.closeSegment(at: instant(1_000_000_000), endedBy: .stopped)
        mixedLedger.openSegment(at: otherInstant(0), revision: revisionA, mediaFilename: "master-01.mov")
        _ = mixedLedger.closeSegment(at: otherInstant(1_000_000_000), endedBy: .stopped)
        do {
            _ = try mixedLedger.finish()
            check(false, "finish() across two boot epochs must throw, not silently succeed")
        } catch SegmentTableError.mixedEpochs {
            check(true, "finish() surfaces SegmentTableError.mixedEpochs rather than computing a meaningless duration")
        } catch {
            check(false, "finish() threw the wrong error for two segments from different boot epochs",
                  actual: "\(error)")
        }

        // ---- overlapping: `SegmentLedger` has no notion of "now" — every
        // instant is supplied by the caller — so it does not itself prevent
        // opening the next segment before the previous one's own end
        // instant. That guard belongs to `SegmentTable`; this confirms it
        // is actually reached through the ledger, not bypassed by it.
        var overlapLedger = SegmentLedger()
        overlapLedger.openSegment(at: instant(0), revision: revisionA, mediaFilename: "master-00.mov")
        _ = overlapLedger.closeSegment(at: instant(2_000_000_000), endedBy: .paused)
        overlapLedger.openSegment(at: instant(1_000_000_000), revision: revisionA, mediaFilename: "master-01.mov")
        _ = overlapLedger.closeSegment(at: instant(3_000_000_000), endedBy: .stopped)
        do {
            _ = try overlapLedger.finish()
            check(false, "finish() with an overlapping second segment must throw, not silently succeed")
        } catch SegmentTableError.overlapping(1) {
            check(true, "finish() surfaces SegmentTableError.overlapping(1) for a segment starting before " +
                        "the previous one ended")
        } catch {
            check(false, "finish() threw the wrong error for an overlapping segment", actual: "\(error)")
        }

        // ---- .failed(reason:) — the fourth `SegmentBoundary` case,
        // exercised separately so all four are proven to round-trip through
        // the ledger, not just the three the happy path above used.
        var failedLedger = SegmentLedger()
        failedLedger.openSegment(at: instant(0), revision: revisionA, mediaFilename: "master-00.mov")
        let failureReason = "frames are uniformly black; screen recording may have been revoked"
        let failedSeg = failedLedger.closeSegment(at: instant(500_000_000), endedBy: .failed(reason: failureReason))
        check(failedSeg.endedBy == .failed(reason: failureReason),
              ".failed(reason:) round-trips its reason string exactly, through the ledger and back out")
    }

    // MARK: - § 7  InputObserver (Task 9)
    //
    // Why here and not in a test target: `InputObserver` lives in the app,
    // names `CGEvent`, `CGEventFlags` and `CGDirectDisplayID`, and its
    // conversion begins at a `CGPoint` — four things no package test may
    // touch. The four functions below are the machine-checkable half of the
    // `input-observation` row. The half that needs a person is
    // `spikes/2026-08-02-input-observation/`: creating the tap needs Input
    // Monitoring, and only a real password field makes
    // `IsSecureEventInputEnabled()` true.

    /// The fixture arrangement: a `scale: 1` display at the origin and a
    /// `scale: 2` display immediately to its right.
    ///
    /// **The `scale: 2` display is the whole point of the fixture.** The
    /// conversion has a points → pixels step in the middle
    /// (`DisplayGeometry.pixels(from:)`) that is the *identity* at `scale: 1`;
    /// against a `scale: 1` fixture the step can be deleted and every
    /// assertion still passes. This project has written three expectation
    /// tables whose fixture made the check vacuous in exactly that way.
    ///
    /// The second display is 3840×2160 native pixels at `scale: 2`, which is
    /// **1920 points wide**, so it occupies global points [1920, 3840) — not
    /// [1920, 5760). Comparing a global point against the pixel width was the
    /// Task 10.5 defect; the arrangement below is built so a regression of it
    /// changes which display a point routes to.
    @MainActor
    static func fixtureArrangement() -> (arrangement: DisplayArrangement,
                                         main: DisplayGeometry, retina: DisplayGeometry) {
        let main = DisplayGeometry(displayUUID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                                   pixelWidth: 1920, pixelHeight: 1080, scale: 1)
        let retina = DisplayGeometry(displayUUID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                                     pixelWidth: 3840, pixelHeight: 2160, scale: 2)
        let arrangement = DisplayArrangement(placements: [
            .init(geometry: main, globalOriginX: 0, globalOriginY: 0),
            .init(geometry: retina, globalOriginX: 1920, globalOriginY: 0),
        ])
        return (arrangement, main, retina)
    }

    @MainActor
    static func theConversionOrder() {
        let (arrangement, main, retina) = fixtureArrangement()

        // ---- The expectation, computed from the fixture rather than typed.
        //
        // Global (2400, 270) points:
        //   route   -> retina, local (480, 270) POINTS
        //   pixels  -> (960, 540) PIXELS            (× scale 2)
        //   normalize -> x = 960/3840 = 0.25
        //               y = 1 - 540/2160 = 0.75     (the Y flip)
        // Fixture sanity, stated rather than emergent. Degrading the fixture
        // to `scale: 1` turns `skippingThePixelStep` below red — the guard is
        // real either way — but a reader should not have to derive that from
        // two other assertions to know the fixture is the load-bearing part.
        check(retina.scale == 2 && main.scale == 1,
              "fixture sanity: the second display is at scale 2, which is what makes the "
              + "points→pixels step non-vacuous",
              actual: "main \(main.scale), retina \(retina.scale)", expected: "1 and 2")

        let globalX = 2400.0, globalY = 270.0
        let localPointsX = globalX - 1920, localPointsY = globalY - 0
        let localPixelsX = localPointsX * retina.scale, localPixelsY = localPointsY * retina.scale
        let expectedX = localPixelsX / Double(retina.pixelWidth)
        let expectedY = 1 - (localPixelsY / Double(retina.pixelHeight))
        print("        expected, computed from the fixture: (\(expectedX), \(expectedY))")

        guard let converted = InputObserver.normalizedPosition(globalTopLeftX: globalX,
                                                               globalTopLeftY: globalY,
                                                               in: arrangement) else {
            check(false, "a point on the scale: 2 display must route somewhere")
            return
        }
        check(converted.position == NormalizedPoint(x: expectedX, y: expectedY),
              "the four-step conversion lands a scale: 2 global point at its computed position",
              actual: "(\(converted.position.x), \(converted.position.y))",
              expected: "(\(expectedX), \(expectedY))")
        check(converted.revision == retina.revision,
              "the sample carries the revision of the display it was normalised against, not the main one",
              actual: "\(converted.revision)", expected: "\(retina.revision)")

        // ---- The two ways to get the order wrong, computed explicitly.
        //
        // Neither fails to compile and neither produces an out-of-range
        // value, which is why they are written out here: an assertion whose
        // failure mode is unstated is an assertion nobody can tell is
        // load-bearing. Both are off by a factor tied to `scale`, and both
        // collapse onto the right answer at `scale: 1`.
        let skippingThePixelStep = NormalizedPoint(
            x: localPointsX / Double(retina.pixelWidth),
            y: 1 - (localPointsY / Double(retina.pixelHeight)))
        check(converted.position != skippingThePixelStep,
              "wiring route's POINTS straight into normalize gives a different, plausible answer",
              actual: "correct \(converted.position.x) vs point-valued \(skippingThePixelStep.x)")
        let skippingTheRouteStep = NormalizedPoint(
            x: globalX / Double(retina.pixelWidth),
            y: 1 - (globalY / Double(retina.pixelHeight)))
        check(converted.position != skippingTheRouteStep,
              "feeding an unrouted GLOBAL point to normalize gives a different, plausible answer",
              actual: "correct \(converted.position.x) vs unrouted \(skippingTheRouteStep.x)")

        // ---- The same conversion on the scale: 1 display, to show the
        // fixture is not simply always returning the retina display.
        guard let onMain = InputObserver.normalizedPosition(globalTopLeftX: 192, globalTopLeftY: 108,
                                                            in: arrangement) else {
            check(false, "a point on the main display must route somewhere")
            return
        }
        check(onMain.revision == main.revision && onMain.position == NormalizedPoint(x: 0.1, y: 0.9),
              "a point on the scale: 1 display routes to it and normalises against its own geometry",
              actual: "\(onMain.revision) (\(onMain.position.x), \(onMain.position.y))",
              expected: "\(main.revision) (0.1, 0.9)")

        // ---- The half-open boundary. Global x = 1920 is the retina
        // display's first column, not the main display's last: a closed
        // interval on both sides would let placement order decide, silently.
        let atSeam = InputObserver.normalizedPosition(globalTopLeftX: 1920, globalTopLeftY: 10,
                                                      in: arrangement)
        check(atSeam?.revision == retina.revision,
              "a point exactly on the shared edge belongs to the display whose origin it is",
              actual: "\(String(describing: atSeam?.revision))", expected: "\(retina.revision)")

        // ---- Every point on either display normalises into [0, 1].
        // The plan flags the trap: a sample on a second display fails this if
        // the global point was not routed first. It is routed, so it does not.
        var sweep: [NormalizedPoint] = []
        for x in stride(from: 0.0, through: 3839.0, by: 137.0) {
            for y in stride(from: 0.0, through: 1079.0, by: 97.0) {
                if let p = InputObserver.normalizedPosition(globalTopLeftX: x, globalTopLeftY: y,
                                                            in: arrangement) {
                    sweep.append(p.position)
                }
            }
        }
        check(!sweep.isEmpty, "the sweep produced samples — an empty one would pass the next check vacuously",
              actual: "\(sweep.count)")
        check(sweep.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) },
              "every normalised coordinate across BOTH displays is in [0, 1]",
              actual: "\(sweep.filter { !(0...1).contains($0.x) || !(0...1).contains($0.y) }.count) outside")

        // ---- A point on no display is nil, never a clamp. A clamped sample
        // is a pointer position on a display the pointer was never on, which
        // reads downstream as real motion.
        check(InputObserver.normalizedPosition(globalTopLeftX: 9000, globalTopLeftY: 9000,
                                               in: arrangement) == nil,
              "a location on no known display returns nil rather than being clamped onto one")
    }

    /// A synthetic `CGEvent`, positioned and stamped.
    ///
    /// `CGEvent(mouseEventSource:…)` and `CGEvent(keyboardEventSource:…)`
    /// build events with the same fields a tapped one carries, and the tap
    /// callback body reads nothing else. What they cannot stand in for is the
    /// tap itself — that is the human step.
    ///
    /// **The timestamp is set explicitly on every event here, because a
    /// constructed `CGEvent` has `timestamp == 0`** (measured: `CGEvent(source:
    /// nil)!.timestamp` is 0 on this OS build, unlike a tapped event, whose
    /// stamp the window server fills in). Leaving it at 0 would drive the
    /// implausibility instrument on every event and mask a real one.
    @MainActor
    static func mouseEvent(_ type: CGEventType, at point: CGPoint, stamp: Nanoseconds) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)!
        event.timestamp = CGEventTimestamp(stamp.rawValue)
        return event
    }

    @MainActor
    static func keyEvent(_ keyCode: Int, flags: CGEventFlags, stamp: Nanoseconds) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        event.flags = flags
        event.timestamp = CGEventTimestamp(stamp.rawValue)
        return event
    }

    /// Collects observations from `InputObserver`'s `@Sendable` callback.
    ///
    /// A class with a lock rather than a captured `var`: the handler is
    /// `@Sendable` and cannot capture a mutable MainActor binding, which is
    /// the same constraint the real callback path lives under.
    nonisolated final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [InputObserver.Observation] = []
        var observations: [InputObserver.Observation] { lock.withLock { storage } }
        func append(_ observation: InputObserver.Observation) {
            lock.withLock { storage.append(observation) }
        }
    }

    @MainActor
    static func theCallbackBody() {
        let (arrangement, _, retina) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        let collector = Collector()
        let observer = InputObserver(arrangement: arrangement, epoch: epoch)
        // `start()` is deliberately NOT called: that creates the real tap and
        // needs Input Monitoring. The sink is installed through the seam
        // `start()` itself uses, and `handle(type:event:)` — the whole
        // callback body — is driven directly.
        observer.setObservationSink(collector.append)
        let stamp = Minting.hostNow()

        observer.handle(type: .mouseMoved,
                        event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270), stamp: stamp))
        guard case .pointer(let sample)? = collector.observations.first else {
            check(false, "a mouseMoved event produces exactly one pointer sample",
                  actual: "\(collector.observations)")
            return
        }
        check(collector.observations.count == 1, "a mouseMoved event produces exactly one observation",
              actual: "\(collector.observations.count)")
        check(sample.position == NormalizedPoint(x: 0.25, y: 0.75) && sample.revision == retina.revision,
              "the emitted pointer sample carries the converted position and the display's revision",
              actual: "(\(sample.position.x), \(sample.position.y)) \(sample.revision)")
        check(sample.instant == HostInstant(epoch: epoch, hostTime: stamp),
              "the sample's instant is the EVENT's own timestamp, taken as nanoseconds and not converted",
              actual: "\(sample.instant.hostTime.rawValue)", expected: "\(stamp.rawValue)")
        check(observer.diagnostics.implausibleEventTimestampCount == 0,
              "a CGEventTimestamp read as nanoseconds sits within a second of hostNow()",
              actual: "\(observer.diagnostics.implausibleEventTimestampCount)")

        // ---- The unit instrument, driven the other way. This is the standing
        // check that `CGEventTimestamp` is nanoseconds: a stamp that is not on
        // `hostNow()`'s base lands here. A tick-valued stamp (the mistake the
        // plan warns about) is ~24× smaller than the nanosecond value and so
        // sits hours away from `hostNow()` — far outside the one-second
        // window, exactly like the 0 below.
        let ticksNotNanos = Nanoseconds(stamp.rawValue * 3 / 125)   // what mach ticks would read as
        observer.handle(type: .mouseMoved,
                        event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270), stamp: ticksNotNanos))
        check(observer.diagnostics.implausibleEventTimestampCount == 1,
              "a tick-valued (unconverted) timestamp is counted as implausible, not accepted silently",
              actual: "\(observer.diagnostics.implausibleEventTimestampCount)")

        // ---- The other direction, which a symmetric window silently
        // admitted. The window server stamps the event BEFORE this callback
        // runs, so a stamp in the future is a different clock, not latency —
        // and Spike A measured `tapLatencyNegative` false in all 118 of its
        // samples, so it has never legitimately occurred. 100 ms ahead is
        // inside the old ±1 s window and outside the new one.
        observer.handle(type: .mouseMoved,
                        event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270),
                                          stamp: Nanoseconds(Minting.hostNow().rawValue + 100_000_000)))
        check(observer.diagnostics.implausibleEventTimestampCount == 2,
              "a timestamp in the FUTURE is counted — the plausibility window is one-sided, "
              + "because an event cannot be stamped after the callback that received it ran",
              actual: "\(observer.diagnostics.implausibleEventTimestampCount)", expected: "2")

        // ---- And the healthy band is not so tight that a real callback
        // trips it. Spike A's worst of 118 samples was 5.46 ms; 20 ms of
        // simulated latency must still be accepted, or the instrument would
        // fire on ordinary recordings and be relaxed into uselessness.
        let latencyObserver = InputObserver(arrangement: arrangement, epoch: epoch)
        latencyObserver.handle(type: .mouseMoved,
                               event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270),
                                                 stamp: Nanoseconds(Minting.hostNow().rawValue - 20_000_000)))
        check(latencyObserver.diagnostics.implausibleEventTimestampCount == 0,
              "20 ms of tap latency — ~4x Spike A's worst of 118 samples — is still plausible",
              actual: "\(latencyObserver.diagnostics.implausibleEventTimestampCount)", expected: "0")

        // ---- A click is a down and an up. Both carry a position.
        let clicks = Collector()
        let clickObserver = InputObserver(arrangement: arrangement, epoch: epoch)
        clickObserver.setObservationSink(clicks.append)
        clickObserver.handle(type: .leftMouseDown,
                             event: mouseEvent(.leftMouseDown, at: CGPoint(x: 2400, y: 270), stamp: stamp))
        clickObserver.handle(type: .leftMouseUp,
                             event: mouseEvent(.leftMouseUp, at: CGPoint(x: 2400, y: 270),
                                               stamp: Nanoseconds(stamp.rawValue + 80_000_000)))
        let buttons = clicks.observations.compactMap { observation -> ButtonEvent? in
            if case .button(let event) = observation { return event }
            return nil
        }
        check(buttons.count == 2 && buttons[0].phase == .down && buttons[1].phase == .up
                && buttons.allSatisfy { $0.button == .left },
              "a click produces a down and an up, in that order, both on the left button",
              actual: "\(buttons.map { "\($0.button.rawValue).\($0.phase.rawValue)" })")
        check(buttons.allSatisfy { $0.position == NormalizedPoint(x: 0.25, y: 0.75) },
              "both halves of the click carry the converted position")

        // ---- A location on no display is dropped and counted, not clamped.
        let offscreen = Collector()
        let offscreenObserver = InputObserver(arrangement: arrangement, epoch: epoch)
        offscreenObserver.setObservationSink(offscreen.append)
        offscreenObserver.handle(type: .mouseMoved,
                                 event: mouseEvent(.mouseMoved, at: CGPoint(x: 9000, y: 9000), stamp: stamp))
        check(offscreen.observations.isEmpty
                && offscreenObserver.diagnostics.unroutablePointerLocations == 1,
              "a pointer location on no known display emits nothing and is counted",
              actual: "\(offscreen.observations.count) observations, "
                      + "\(offscreenObserver.diagnostics.unroutablePointerLocations) unroutable")
    }

    /// **The privacy claim, as a negative assertion — the category this
    /// project has repeatedly passed vacuously.**
    ///
    /// Observed red before being reported green: with the two gates removed
    /// from `InputObserver.approvedShortcut(forKeyCode:flags:)` so that it
    /// returns an identifier for every key, the first two checks below fail.
    /// The failure text is quoted in the Task 9 report; without it, "ordinary
    /// typing is never recorded" and "this check tests nothing" read exactly
    /// alike.
    @MainActor
    static func keystrokesAreNotStored() {
        let (arrangement, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        let stamp = Minting.hostNow()

        // A password, typed. Key POSITIONS, never characters — this probe has
        // no more business holding the text than the observer does.
        let typedKeys = [kVK_ANSI_H, kVK_ANSI_U, kVK_ANSI_N, kVK_ANSI_T,
                         kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_2, kVK_ANSI_Period]
        let collector = Collector()
        let observer = InputObserver(arrangement: arrangement, epoch: epoch)
        observer.setObservationSink(collector.append)
        for key in typedKeys {
            observer.handle(type: .keyDown,
                            event: keyEvent(key, flags: [.maskNonCoalesced], stamp: stamp))
        }
        // Held shift, because that is how the capitals in a password are
        // typed, and because a filter keyed on "any modifier" would let them
        // through.
        for key in typedKeys {
            observer.handle(type: .keyDown,
                            event: keyEvent(key, flags: [.maskShift, .maskNonCoalesced], stamp: stamp))
        }
        check(observer.diagnostics.keyDownsSeen == typedKeys.count * 2,
              "the observer saw every synthetic keystroke — a filter tested against no input passes vacuously",
              actual: "\(observer.diagnostics.keyDownsSeen)", expected: "\(typedKeys.count * 2)")
        check(collector.observations.isEmpty,
              "ordinary typing, shifted and unshifted, produces NO observation of any kind",
              actual: "\(collector.observations.count) observations")
        check(observer.diagnostics.everyKeyDownIsAccountedFor,
              "every keyDown is accounted for as recorded or refused",
              actual: observer.diagnostics.keyAccounting)

        // ---- The allow-list admits what it says it admits, so the checks
        // above are not passing because nothing at all gets through.
        let approved = Collector()
        let approvedObserver = InputObserver(arrangement: arrangement, epoch: epoch)
        approvedObserver.setObservationSink(approved.append)
        approvedObserver.handle(type: .keyDown,
                                event: keyEvent(kVK_ANSI_C, flags: [.maskCommand, .maskNonCoalesced],
                                                stamp: stamp))
        guard case .key(let sample)? = approved.observations.first else {
            check(false, "cmd+C is on the allow-list and must produce a KeySample",
                  actual: "\(approved.observations)")
            return
        }
        check(sample.shortcut == "cmd+c",
              "an approved shortcut is recorded under the table's own identifier",
              actual: sample.shortcut, expected: "cmd+c")

        // ---- Modifiers are matched exactly, not by subset.
        check(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_Z),
                                             flags: [.maskCommand, .maskNonCoalesced]) == "cmd+z"
                && InputObserver.approvedShortcut(
                    forKeyCode: Int64(kVK_ANSI_Z),
                    flags: [.maskCommand, .maskShift, .maskNonCoalesced]) == "cmd+shift+z",
              "⌘Z and ⇧⌘Z are different entries, not one entry with a spare flag")
        check(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_C),
                                             flags: [.maskCommand, .maskAlternate,
                                                     .maskNonCoalesced]) == nil,
              "⌥⌘C is not ⌘C — an unlisted modifier combination is refused, not rounded to the nearest entry")

        // ---- A command chord that is not in the table is still refused. The
        // allow-list is closed; it is not "anything with ⌘".
        check(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_H),
                                             flags: [.maskCommand, .maskNonCoalesced]) == nil,
              "⌘H is a real shortcut and is not on the list, so it is not recorded")

        // ---- `maskNonCoalesced` is set on every real event, so an exact
        // comparison against the raw flags would match nothing, ever — a
        // filter indistinguishable from a working one until someone presses
        // ⌘C and looks for it. Every check above passes it deliberately; this
        // one states why.
        check(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_C),
                                             flags: [.maskCommand]) == "cmd+c"
                && InputObserver.approvedShortcut(
                    forKeyCode: Int64(kVK_ANSI_C),
                    flags: [.maskCommand, .maskNonCoalesced, .maskNumericPad]) == "cmd+c",
              "the filter masks to the four modifiers it considers, so incidental flags do not defeat it")

        // ---- Nothing that leaves the filter is a keystroke. Every
        // identifier is a literal from the table; this states the property
        // rather than trusting the eleven literals above it.
        check(InputObserver.approvedShortcuts.allSatisfy { $0.identifier.contains("+") }
                && !InputObserver.approvedShortcuts.isEmpty,
              "every approved identifier names a chord, and none is a single character",
              actual: "\(InputObserver.approvedShortcuts.count) entries")
    }

    /// **An interval with no samples is otherwise indistinguishable from an
    /// interval where nothing happened.** That is the whole reason the record
    /// exists, and this is the check that it is produced.
    ///
    /// The secure-input predicate is injected (see `InputObserver.init`):
    /// `IsSecureEventInputEnabled()` is true only while another
    /// application's password field has focus, so a check that waited for the
    /// real one would never run. That the real predicate is wired up is the
    /// human step's job.
    @MainActor
    static func secureInputProducesAnInterval() {
        let (arrangement, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        let base = Minting.hostNow().rawValue

        nonisolated final class Toggle: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isOn: Bool {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }
        let secure = Toggle()
        let collector = Collector()
        let observer = InputObserver(arrangement: arrangement, epoch: epoch,
                                     secureInputIsEnabled: { secure.isOn })
        observer.setObservationSink(collector.append)

        func move(at offset: Int64) {
            observer.handle(type: .mouseMoved,
                            event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270),
                                              stamp: Nanoseconds(base + offset)))
        }

        move(at: 0)                                   // before: an ordinary sample
        secure.isOn = true
        move(at: 1_000_000_000)                       // the interval opens here
        move(at: 2_000_000_000)
        move(at: 3_000_000_000)
        check(collector.observations.count == 1,
              "while secure input is on the observer emits NOTHING — not a redacted sample, not a placeholder",
              actual: "\(collector.observations.count) observations after 3 suppressed events")
        check(observer.diagnostics.eventsSuppressedBySecureInput == 3,
              "the suppressed events are counted, so the silence is not itself silent",
              actual: "\(observer.diagnostics.eventsSuppressedBySecureInput)")

        secure.isOn = false
        move(at: 4_000_000_000)                       // the interval closes here
        let intervals = collector.observations.compactMap { observation -> SecureInputInterval? in
            if case .secureInput(let interval) = observation { return interval }
            return nil
        }
        check(intervals.count == 1, "leaving secure input emits exactly one interval record",
              actual: "\(intervals.count)")
        guard let interval = intervals.first else { return }
        check(interval.interval.start == Nanoseconds(base + 1_000_000_000)
                && interval.interval.end == Nanoseconds(base + 4_000_000_000),
              "the interval spans the first suppressed event to the first one emitted again",
              actual: "start +\(interval.interval.start.rawValue - base) "
                      + "end +\(interval.interval.end.rawValue - base)",
              expected: "start +1000000000 end +4000000000")
        check(interval.endedBy == .secureInputDisabled,
              "an interval the observer watched end is marked as measured, not as a bound",
              actual: "\(interval.endedBy.rawValue)")
        check(interval.interval.epoch == epoch, "the interval carries the recording's boot epoch")

        // ---- A recording that ends mid-password still reports the interval,
        // marked as the lower bound it is. Dropping it would lose exactly the
        // stretch the log has no samples for.
        let atStop = Collector()
        let stoppingObserver = InputObserver(arrangement: arrangement, epoch: epoch,
                                             secureInputIsEnabled: { true })
        stoppingObserver.setObservationSink(atStop.append)
        stoppingObserver.handle(type: .mouseMoved,
                                event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270),
                                                  stamp: Nanoseconds(base)))
        check(atStop.observations.isEmpty, "nothing is emitted while secure input is on")
        // The real `stop()`, not a stand-in: with no tap created it does
        // nothing to the run loop and takes exactly the path that closes an
        // open interval.
        stoppingObserver.stop()
        let stopIntervals = atStop.observations.compactMap { observation -> SecureInputInterval? in
            if case .secureInput(let interval) = observation { return interval }
            return nil
        }
        check(stopIntervals.count == 1 && stopIntervals.first?.endedBy == .observationStopped,
              "stopping mid-interval still reports it, marked .observationStopped rather than dropped",
              actual: "\(stopIntervals.map { $0.endedBy.rawValue })")
    }

    /// **The mask is the one piece of this file only the tap reads.**
    ///
    /// Everything downstream of it is checked by driving
    /// `handle(type:event:)` directly, which bypasses the mask entirely — so
    /// deleting `.mouseMoved` from `eventTypes` left every test and every
    /// check in this file green while the shipped app would have recorded
    /// clicks and shortcuts and no pointer track at all. That is the mutation
    /// this section exists for, and it is pinned in **both** directions:
    /// a type asked for but not handled is a wasted callback, and a type
    /// handled but not asked for is a code path that never runs.
    @MainActor
    static func theEventMaskMatchesTheDispatchTable() {
        check(!InputObserver.eventTypes.isEmpty,
              "the mask asks for at least one event type — an empty list would pass the rest vacuously",
              actual: "\(InputObserver.eventTypes.count)")

        let unhandled = InputObserver.eventTypes.filter { InputObserver.category(of: $0) == nil }
        check(unhandled.isEmpty,
              "every event type the mask asks for is one handle() dispatches on",
              actual: "\(unhandled.map(\.rawValue))", expected: "[]")

        // The reverse sweep. `CGEventType` is a fixed C enum, so
        // `init(rawValue:)` returns nil for anything that is not a real type
        // — which bounds this to the types that actually exist rather than to
        // an arbitrary integer range. The two out-of-band types
        // (`tapDisabledByTimeout`/`tapDisabledByUserInput`, 0xFFFFFFFE/F) are
        // handled before dispatch and are deliberately not in `eventTypes`:
        // a tap is delivered them regardless of its mask.
        var handledButNotRequested: [UInt32] = []
        for raw in UInt32(0)...UInt32(255) {
            guard let type = CGEventType(rawValue: raw) else { continue }
            guard InputObserver.category(of: type) != nil else { continue }
            if !InputObserver.eventTypes.contains(where: { $0.rawValue == raw }) {
                handledButNotRequested.append(raw)
            }
        }
        check(handledButNotRequested.isEmpty,
              "every event type handle() dispatches on is one the mask asks for — deleting a type "
              + "from eventTypes fails HERE, where nothing else would notice",
              actual: "\(handledButNotRequested)", expected: "[]")

        check(InputObserver.eventMask.nonzeroBitCount == InputObserver.eventTypes.count,
              "the mask has exactly one bit set per requested type — no type is dropped or doubled "
              + "by the shift that builds it",
              actual: "\(InputObserver.eventMask.nonzeroBitCount) bits for "
                      + "\(InputObserver.eventTypes.count) types")
        for type in InputObserver.eventTypes where type.rawValue < 64 {
            check(InputObserver.eventMask & (CGEventMask(1) << CGEventMask(type.rawValue)) != 0,
                  "the mask's bit for event type \(type.rawValue) is set")
        }
    }

    /// **`currentArrangement()` is the ambient input to every conversion in
    /// the file, and it had no machine-checked coverage.**
    ///
    /// The mutation it is written against: invert the scale to
    /// `Double(pointWidth) / Double(mode.pixelWidth)`. Every pointer sample
    /// then lands at half its true position, every value stays inside [0, 1],
    /// no precondition fires anywhere, and every other check in this file and
    /// every package test stays green — because they all run against the
    /// *fixture* arrangement, which this function does not build.
    ///
    /// The check is the spike's own positive control, brought down to where it
    /// runs without a permission: `NSScreen.main.frame` is the main display's
    /// size in **points**, from AppKit; `pixelWidth / scale` is the same
    /// quantity derived from `CGDisplayMode` and `CGDisplayBounds`. Two APIs
    /// over the same window-server state, and an inverted scale makes them
    /// disagree by a factor of `scale²`.
    ///
    /// It reads real hardware, so it asserts nothing about *which* displays
    /// are attached — only that what it built agrees with a second source.
    @MainActor
    static func theAmbientArrangement() {
        let arrangement = InputObserver.currentArrangement()
        check(!arrangement.placements.isEmpty,
              "currentArrangement() found at least one display — an empty arrangement would make "
              + "every check below vacuous",
              actual: "\(arrangement.placements.count) placements")
        guard let screen = NSScreen.main else {
            check(false, "NSScreen.main is nil — there is no independent source to check against")
            return
        }
        guard let mainIdentity = Minting.displayIdentity(of: CGMainDisplayID()),
              let main = arrangement.placements.first(where: { $0.geometry.displayUUID == mainIdentity })
        else {
            check(false, "the main display is not in the arrangement currentArrangement() built")
            return
        }

        let derivedPointWidth = Double(main.geometry.pixelWidth) / main.geometry.scale
        let derivedPointHeight = Double(main.geometry.pixelHeight) / main.geometry.scale
        print("        AppKit  : \(screen.frame.width)×\(screen.frame.height) points, "
              + "backingScaleFactor \(screen.backingScaleFactor)")
        print("        derived : \(derivedPointWidth)×\(derivedPointHeight) points, "
              + "from \(main.geometry.pixelWidth)×\(main.geometry.pixelHeight) px at "
              + "scale \(main.geometry.scale)")
        check(derivedPointWidth == Double(screen.frame.width)
                && derivedPointHeight == Double(screen.frame.height),
              "the main display's size in points, derived from CGDisplayMode, equals AppKit's — "
              + "an inverted scale disagrees here by scale squared",
              actual: "\(derivedPointWidth)×\(derivedPointHeight)",
              expected: "\(screen.frame.width)×\(screen.frame.height)")
        check(main.geometry.scale == Double(screen.backingScaleFactor),
              "the scale derived from pixelWidth/width equals AppKit's backingScaleFactor",
              actual: "\(main.geometry.scale)", expected: "\(screen.backingScaleFactor)")

        // `CGDisplayBounds` puts the main display at the global origin. Not a
        // tautology of the line above: it checks the placement half of what
        // `currentArrangement()` builds, which is read from a different API
        // than the geometry half.
        check(main.globalOriginX == 0 && main.globalOriginY == 0,
              "the main display sits at the global origin, as CGDisplayBounds defines it",
              actual: "(\(main.globalOriginX), \(main.globalOriginY))")

        // Every placement is distinct in identity AND rectangle. A software
        // mirror set shares a `CGDisplayBounds` across members with different
        // UUIDs, so an arrangement holding both would let `route` pick a
        // revision by list order — and `NormalizationContext.denormalize`
        // preconditions on revision equality, making the downstream failure a
        // trap rather than a wrong number. On a single-display machine this
        // passes trivially; it is here so a mirrored setup fails loudly.
        let identities = Set(arrangement.placements.map(\.geometry.displayUUID))
        check(identities.count == arrangement.placements.count,
              "no display appears twice in the arrangement",
              actual: "\(identities.count) identities for \(arrangement.placements.count) placements")
        let rectangles = arrangement.placements.map {
            "\($0.globalOriginX),\($0.globalOriginY),\(Double($0.geometry.pixelWidth) / $0.geometry.scale),"
                + "\(Double($0.geometry.pixelHeight) / $0.geometry.scale)"
        }
        check(Set(rectangles).count == rectangles.count,
              "no two placements occupy the same global rectangle — mirrored displays are folded "
              + "to the display being mirrored, not both kept",
              actual: "\(Set(rectangles).count) rectangles for \(rectangles.count) placements")

        // Finally: a point in the middle of the real main display routes and
        // normalises. `currentArrangement()` feeding `normalizedPosition` is
        // the pairing the app actually ships, and nothing else here runs it.
        let centreX = derivedPointWidth / 2
        let centreY = derivedPointHeight / 2
        guard let centre = InputObserver.normalizedPosition(globalTopLeftX: centreX,
                                                            globalTopLeftY: centreY,
                                                            in: arrangement) else {
            check(false, "the centre of the main display must route somewhere")
            return
        }
        check(centre.position.x == 0.5 && centre.position.y == 0.5,
              "the centre of the real main display normalises to (0.5, 0.5)",
              actual: "(\(centre.position.x), \(centre.position.y))", expected: "(0.5, 0.5)")
        check(centre.revision == main.geometry.revision,
              "and carries that display's own revision")
    }

    /// **`§ 7.4` proves the default predicate is not `{ true }`. Nothing
    /// proved it is not `{ false }` — and `{ false }` silently disables the
    /// privacy guarantee with every test and every other check still green.**
    ///
    /// `IsSecureEventInputEnabled()` appears on exactly one executable line
    /// under `Soredemo/`: the default argument of
    /// `InputObserver.init(arrangement:epoch:secureInputIsEnabled:)`. Every
    /// other check in `§ 7.4` passes its own predicate in, so none of them
    /// touches that line. This one takes the default and makes the real thing
    /// true, with no seam anywhere in the path.
    ///
    /// **Here, and deliberately NOT in `swift test`.** Secure event input is
    /// held by the window server against the *enabling process* and released
    /// when that process dies. This probe is a standalone binary that runs
    /// and exits in under a second, so the worst case is bounded by its own
    /// lifetime. `swift test` is one long-lived process running the whole
    /// suite; a hang, a breakpoint or a crash-loop there is the case that
    /// actually strands the machine's keyboard until a reboot, and "it looks
    /// more at home in the test suite" is not worth that. The lexical half of
    /// this claim — that the line exists and is the only one — is in
    /// `Tests/AppSourceTests`, where it costs nothing to run.
    ///
    /// The window is kept microseconds wide and contains no run loop, no
    /// printing, no I/O, no permission-requiring call and no `check()`. Every
    /// assertion below runs after secure input has been released, because a
    /// failing `check` must never be the thing that leaves it on.
    @MainActor
    static func theProductionSecureInputPredicateIsRead() {
        check(!IsSecureEventInputEnabled(),
              "precondition: secure input is off before this check starts — otherwise the toggle "
              + "below measures someone else's state and the release at the end is not ours to make")
        guard !IsSecureEventInputEnabled() else { return }

        // Everything that can be built, built first. Nothing but the three
        // calls between Enable and Disable happens inside the window.
        let (arrangement, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        let collector = Collector()
        // DEFAULT-INITIALISED. No `secureInputIsEnabled:` argument — that is
        // the entire point of this check, and passing one here would make it
        // a slower copy of § 7.4.
        let observer = InputObserver(arrangement: arrangement, epoch: epoch)
        observer.setObservationSink(collector.append)
        let event = mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270), stamp: Minting.hostNow())

        var released = false
        func release() {
            guard !released else { return }
            DisableSecureEventInput()
            released = true
        }

        // ---- window opens
        EnableSecureEventInput()
        defer { release() }
        let readInsideWindow = IsSecureEventInputEnabled()
        observer.handle(type: .mouseMoved, event: event)
        let observations = collector.observations
        let diagnostics = observer.diagnostics
        release()
        // ---- window closed

        check(readInsideWindow,
              "EnableSecureEventInput() actually took effect — without this the rest measures nothing")
        check(!IsSecureEventInputEnabled(),
              "the probe released secure input again before asserting anything")
        check(observations.isEmpty,
              "with the PRODUCTION predicate and secure input genuinely enabled, the observer emitted "
              + "nothing — the default argument is IsSecureEventInputEnabled(), not { false }",
              actual: "\(observations.count) observations", expected: "0")
        check(diagnostics.eventsSuppressedBySecureInput == 1,
              "and the suppressed event was counted, so the silence is attributable",
              actual: "\(diagnostics.eventsSuppressedBySecureInput)", expected: "1")
        check(diagnostics.pointerSamples == 0,
              "no pointer sample was recorded even in the diagnostics",
              actual: "\(diagnostics.pointerSamples)")
    }
}
