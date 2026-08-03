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
// **No permission dump, and no permission read, belongs in this probe.**
//
// `CapturePermissions` (`Soredemo/Capture/CapturePermissions.swift`) IS now
// compiled in, which it was not before Task 10, and the reason is narrow: it
// is the default argument of `AXObserver.init`'s `accessibilityIsGranted`
// predicate, and a default argument has to compile whether or not it is ever
// evaluated. Every `AXObserver` in § 8 passes its own predicate, so nothing
// here ever calls it — which is what the paragraph below requires, and it is
// now a property of the checks rather than of the compile list. If a check
// ever lets that default be evaluated, the value it gets back is about the
// shell, not about this app.
//
// This binary is `swiftc`-compiled straight to a temp path — a bare
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
// `AVAssetWriter`, `AVAssetImageGenerator`, `AVURLAsset`, `CMTime` for § 11 — building a real
// source movie and reading a real composited frame back through `CompositionBuilder`, the same
// two AVFoundation-facing steps `StageWindow.load()` performs.
import AVFoundation
// `kVK_ANSI_*` for § 7's keyboard fixtures — the same layout-independent key
// positions `InputObserver.approvedShortcuts` is written against, so the two
// cannot drift into disagreeing about which key is which.
import Carbon.HIToolbox
import CoreGraphics
// `CVPixelBuffer` for § 10 — the compositor seam's own vocabulary.
import CoreVideo
import Foundation
import Geometry
import Graph
import Project
// `RenderPlan`, `StageRect`, `StageStyle` for § 10 — `Soredemo/Render/*.swift`
// depends on this module and no package test can drive the real
// `CoreImageFrameRenderer` without it.
import Render
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
        // **The crash child, before any check runs.** § 9.8 re-launches this
        // same binary with `--append-until-killed <package>`; the child opens a
        // log and appends forever until its parent SIGKILLs it. It must be
        // handled here rather than by a second executable, because the claim is
        // about the bytes THIS writer produces.
        if CommandLine.arguments.count >= 3,
           CommandLine.arguments[1] == "--append-until-killed" {
            try appendUntilKilled(packagePath: CommandLine.arguments[2])
        }

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
        print("7.8 the observation path and the capture path agree on a display's revision")
        await theTwoDerivationsOfADisplayAgree()
        print("7.9 a disabled tap produces an interval, not a count (D6a)")
        aDisabledTapProducesAnInterval()
        print("7.10 the poll finds what the notification cannot, from a thread of its own")
        thePollFindsADisabledTap()
        thePollRunsWhileTheMainThreadIsStuck()

        print("8. AXObserver — the bounded walk that records and does not judge (Task 10)")
        print("8.1 the reverse conversion is the exact inverse of the forward one")
        theReverseConversion()
        print("8.2 the AXValue decoders, against real AXValues")
        theAXValueDecoders()
        print("8.2b an AX frame becomes a NormalizedFrame anchored on its BOTTOM edge")
        theFrameConversion()
        print("8.3 the walk is bounded, and says which bound stopped it")
        theWalkIsBounded()
        print("8.4 the recorded element is checkable against where the click was")
        theRecordedElementIsCheckableAgainstTheClick()
        print("8.5 the diagnostics balance")
        theAXDiagnosticsBalance()
        print("8.6 every counter that partitions a decision, driven both ways")
        theAXCountersAreDrivenInBothDirections()
        print("8.7 the AX work is off the callback thread, and the delay that buys is recorded")
        theAXWorkIsDeferredAndTheDelayIsRecorded()

        print("9. observation-log — one file per segment, on one clock (Task 11)")
        print("9.1 one log per segment, header first, trailer last")
        try oneLogPerSegment()
        print("9.2 the log's own boot epoch, and the records that must match it")
        try theLogRefusesARecordFromAnotherBootSession()
        print("9.3 a click and its AX chain share an instant")
        try aClickAndItsChainShareAnInstant()
        print("9.4 the log survives a truncated tail, and says how much it lost")
        try theLogSurvivesATruncatedTail()
        print("9.5 the pointer track is not thinned")
        try thePointerTrackIsNotThinned()
        print("9.6 Addition A: zero is distinguishable from never-measured")
        try zeroIsDistinguishableFromNeverMeasured()
        print("9.7 media routed through the document is referenced; media written around it is not")
        try mediaRoutedThroughTheDocumentIsReferenced()
        print("9.8 a real crash: the writer is SIGKILLed mid-recording")
        try aKilledWriterLosesOnlyItsTail()
        print("9.9 concurrent appends from many threads")
        try concurrentAppendsAreNotLost()
        print("9.10 a log naming media the manifest no longer references is a dangling join")
        try aDanglingObservationLogIsReported()

        print("10. FrameRendering — the compositor seam and CoreImageFrameRenderer (Phase 2B Task 3)")
        print("10.1 a frame drawn: the card shows the source, the margin and the cut corner show the background")
        try theCompositorDrawsACardOverABackground()

        print("11. CompositionBuilder — the real AVVideoComposition, end to end (Phase 2B Task 4)")
        print("11.1 a synthetic movie, composed through StageCompositor, and read back with AVAssetImageGenerator")
        try await theRealCompositionRendersACardOverABackground()

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
    ///
    /// **The third display has a NEGATIVE global origin, and that is a second
    /// deliberate non-identity.** A display placed to the left of or above the
    /// main one is an ordinary macOS arrangement, and `DisplayArrangement
    /// .Placement` documents that its origin is a plain `Double` for exactly
    /// that reason — but until Task 10 every fixture in this file put every
    /// display at a non-negative origin, where a conversion that *subtracts*
    /// the origin and one that *adds* it are hard to tell apart by sign, and
    /// where an origin of zero (the main display) makes the step vanish
    /// entirely. `AXObserver.globalPoint` adds the origin back and
    /// `normalizedFrame` subtracts it, so this is the placement that makes
    /// both steps observable. It needs no hardware, which is the same argument
    /// `theAXValueDecoders` makes for decoding a negative AX coordinate.
    @MainActor
    static func fixtureArrangement() -> (arrangement: DisplayArrangement,
                                         main: DisplayGeometry, retina: DisplayGeometry,
                                         left: DisplayGeometry) {
        let main = DisplayGeometry(displayUUID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                                   pixelWidth: 1920, pixelHeight: 1080, scale: 1)
        let retina = DisplayGeometry(displayUUID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                                     pixelWidth: 3840, pixelHeight: 2160, scale: 2)
        // 1440×900 points at scale 2 = 2880×1800 pixels, sitting up and to the
        // left: global points [-1440, 0) on X and [-900, 0) on Y.
        let left = DisplayGeometry(displayUUID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                                   pixelWidth: 2880, pixelHeight: 1800, scale: 2)
        let arrangement = DisplayArrangement(placements: [
            .init(geometry: main, globalOriginX: 0, globalOriginY: 0),
            .init(geometry: retina, globalOriginX: 1920, globalOriginY: 0),
            .init(geometry: left, globalOriginX: -1440, globalOriginY: -900),
        ])
        return (arrangement, main, retina, left)
    }

    @MainActor
    static func theConversionOrder() {
        let (arrangement, main, retina, _) = fixtureArrangement()

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

    /// Collects `AXChainRecord`s from `AXObserver.enqueue`'s `@Sendable`
    /// callback, which is called on the AX queue rather than this one.
    nonisolated final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [AXChainRecord] = []
        var all: [AXChainRecord] { lock.withLock { storage } }
        func append(_ record: AXChainRecord) { lock.withLock { storage.append(record) } }
    }

    /// A `Bool` the probe can flip and a `@Sendable` closure can read — the
    /// stand-in for a tap that goes down mid-run.
    nonisolated final class MutableFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Bool
        init(_ value: Bool) { storage = value }
        var value: Bool {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
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
        let (arrangement, _, retina, _) = fixtureArrangement()
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
        let (arrangement, _, _, _) = fixtureArrangement()
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
        let (arrangement, _, _, _) = fixtureArrangement()
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

        // **D6a's secure-input row gained its companion in Task 11, and this is
        // it driven in both directions.** `secureInputIntervals == 0` had two
        // readings — nobody typed a password, and nothing ever asked — and they
        // were the same zero. The predicate is consulted per event, so a run
        // that received no events asks zero times and reports zero intervals,
        // which reads as a clean recording.
        check(observer.diagnostics.secureInputChecks == 4,
              "every event consulted the secure-input predicate, and the asks are counted at the "
              + "ask rather than at the answer — so 'consulted and always false' is "
              + "distinguishable from 'never consulted'",
              actual: "\(observer.diagnostics.secureInputChecks)", expected: "4")
        check(observer.diagnostics.secureInputCheckSpanNanos == 3_000_000_000,
              "and the span those asks cover is recorded, because a count with no span cannot "
              + "tell four asks over three seconds from four in the first millisecond",
              actual: "\(observer.diagnostics.secureInputCheckSpanNanos)",
              expected: "3000000000")
        check(!observer.diagnostics.secureInputAccounting.contains("NOTHING WAS LOOKING"),
              "an observer that HAS looked does not carry the caveat — the other direction of "
              + "the same check in § 9.6, without which that one is satisfied by a string that "
              + "is always present")

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
        // Stated in the printed text, for the same reason as the mirror checks
        // below: at scale 1 an inverted scale computation (`width / pixelWidth`
        // instead of `pixelWidth / width`) is 1/1 = 1, arithmetically identical
        // to the correct one. No check anywhere can catch that mutation on such
        // a machine. This one catches it at scale 2 — it was verified there —
        // but a reader on scale-1 hardware seeing "ok" must not read it as
        // covering the inversion.
        let scaleCaveat = main.geometry.scale == 1
            ? "  [SCALE IS 1 ON THIS RUN: an inverted scale computation is arithmetically identical "
              + "at scale 1, so this cannot catch that mutation here. Verified on scale-2 hardware.]"
            : ""
        check(derivedPointWidth == Double(screen.frame.width)
                && derivedPointHeight == Double(screen.frame.height),
              "the main display's size in points, derived from CGDisplayMode, equals AppKit's — "
              + "an inverted scale disagrees here by scale squared" + scaleCaveat,
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
        // The limitation goes in the check's PRINTED TEXT, not only in the
        // comment above it. A reader watching the console sees "ok ... mirrored
        // displays are folded" and reasonably concludes the mirror path was
        // exercised. With one display attached it was not — the check is
        // vacuously true over a single placement, and nothing in the output
        // said so. A caveat that lives only in the source is a caveat for
        // people who are already reading the source, who are not the people
        // this check misleads.
        let displayCount = arrangement.placements.count
        let vacuous = displayCount < 2
            ? "  [VACUOUS ON THIS RUN: \(displayCount) display attached — this asserts nothing about "
              + "mirroring. It needs two or more displays, at least two of them mirrored.]"
            : ""
        let identities = Set(arrangement.placements.map(\.geometry.displayUUID))
        check(identities.count == arrangement.placements.count,
              "no display appears twice in the arrangement" + vacuous,
              actual: "\(identities.count) identities for \(arrangement.placements.count) placements")
        let rectangles = arrangement.placements.map {
            "\($0.globalOriginX),\($0.globalOriginY),\(Double($0.geometry.pixelWidth) / $0.geometry.scale),"
                + "\(Double($0.geometry.pixelHeight) / $0.geometry.scale)"
        }
        check(Set(rectangles).count == rectangles.count,
              "no two placements occupy the same global rectangle — mirrored displays are folded "
              + "to the display being mirrored, not both kept" + vacuous,
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
    /// **The two subsystems derive the same display's geometry from different
    /// APIs, and a disagreement is a crash, not a wrong number.**
    ///
    /// `InputObserver.currentArrangement()` takes `pixelWidth` from
    /// `CGDisplayMode.pixelWidth`. `CaptureSource.geometry(scale:displayUUID:)`
    /// takes it as `SCDisplay.width × scale`. Both feed `GeometryRevision`, and
    /// `NormalizationContext.denormalize` **preconditions** on revision
    /// equality — so if a pointer sample and the video segment it belongs to
    /// carry different revisions for one physical display, the failure is a
    /// trap in the compositor, not a coordinate that is slightly off.
    ///
    /// Nothing wires the two together today; `Task 11`'s `observation-log` is
    /// the first place they meet. This check exists so that meeting is not the
    /// first time anyone finds out.
    ///
    /// **Two halves, and the second is what stops the first being vacuous.**
    /// The agreement holds *conditionally* — only when the caller hands
    /// `CaptureSource.geometry` the same scale the display's current mode
    /// implies. So this asserts both that they agree at that scale, and that
    /// they **disagree** at a different one. Without the second half, a
    /// version of `GeometryRevision` that ignored its inputs entirely would
    /// pass.
    ///
    /// Runs without any permission: `SCShareableContent.currentProcess` needs
    /// neither Screen Recording nor a picker, the same route § 6 already uses.
    static func theTwoDerivationsOfADisplayAgree() async {
        let mainID = CGMainDisplayID()
        guard let identity = Minting.displayIdentity(of: mainID) else {
            check(false, "could not read the main display's identity")
            return
        }
        guard let content = try? await SCShareableContent.currentProcess,
              let scDisplay = content.displays.first(where: { $0.displayID == mainID }) else {
            print("        SKIPPED — SCShareableContent.currentProcess did not return the main display")
            return
        }
        let arrangement = InputObserver.currentArrangement()
        guard let observed = arrangement.placements
            .first(where: { $0.geometry.displayUUID == identity })?.geometry else {
            check(false, "the main display is not in currentArrangement()'s output")
            return
        }
        // The scale a real caller would pass: the one the display's CURRENT
        // mode implies, which is what `CaptureSession` re-derives on every
        // reconfiguration (Task 8, finding 6) precisely because a session's
        // constructor value cannot follow a mode change.
        guard let mode = CGDisplayCopyDisplayMode(mainID), mode.width > 0 else {
            check(false, "could not read the main display's current mode")
            return
        }
        let modeScale = Double(mode.pixelWidth) / Double(mode.width)
        let captured = CaptureSource.display(scDisplay).geometry(scale: modeScale, displayUUID: identity)

        print("        observation path : \(observed.pixelWidth)×\(observed.pixelHeight) "
              + "@\(observed.scale)  from CGDisplayMode.pixelWidth")
        print("        capture path     : \(captured.pixelWidth)×\(captured.pixelHeight) "
              + "@\(captured.scale)  from SCDisplay.width × \(modeScale)")
        check(observed.revision == captured.revision,
              "one physical display, two derivations, the SAME GeometryRevision — a mismatch is a "
              + "precondition trap downstream, not a coordinate that is slightly off",
              actual: "\(observed.revision) vs \(captured.revision)")

        // The anti-vacuity half. The agreement above is conditional on the
        // caller's scale; at a different one the revisions MUST differ, or
        // `GeometryRevision` is not reading its inputs at all.
        let wrongScale = modeScale == 1 ? 2.0 : 1.0
        let atWrongScale = CaptureSource.display(scDisplay)
            .geometry(scale: wrongScale, displayUUID: identity)
        check(atWrongScale.revision != observed.revision,
              "and they DIFFER when the capture path is handed scale \(wrongScale) instead of "
              + "\(modeScale) — so the agreement above is a fact about the derivations, not about "
              + "a revision that ignores its inputs",
              actual: "\(atWrongScale.revision) vs \(observed.revision)")
    }

    static func theProductionSecureInputPredicateIsRead() {
        check(!IsSecureEventInputEnabled(),
              "precondition: secure input is off before this check starts — otherwise the toggle "
              + "below measures someone else's state and the release at the end is not ours to make")
        guard !IsSecureEventInputEnabled() else { return }

        // Everything that can be built, built first. Nothing but the three
        // calls between Enable and Disable happens inside the window.
        let (arrangement, _, _, _) = fixtureArrangement()
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

    // MARK: - § 8  AXObserver (Task 10)
    //
    // Why here and not in a test target: `AXObserver` lives in the app, names
    // `AXUIElement`, and reaches CoreGraphics geometry through
    // `CGGeometryBridge` — three things no package test may touch.
    //
    // What is checked here is everything that does NOT need the Accessibility
    // grant, which is everything except one thing: both coordinate
    // conversions, the depth cap, the wall-clock budget, all four truncation
    // reasons, the AX call arithmetic, the empty-versus-absent children
    // distinction, and the containment instrument that separates a coordinate
    // fault from an AX timing fault. The walk runs against a synthetic
    // `AXElementSource`, which is not a mock standing in for a reader that
    // could have been called directly: the real one needs a TCC grant this
    // binary structurally cannot hold (see this file's header on responsible
    // processes) and a running application animating under the pointer.
    //
    // What is left for a person is exactly one claim — that
    // `LiveAXElementSource` asks the real API the right questions, and that
    // the resulting distributions still look like F2-2's.
    // `spikes/2026-08-02-pairing-latency/` is that step.

    /// One node of a synthetic accessibility tree. Deliberately holds the same
    /// shapes `AXElementSource` returns, so the fake cannot answer a question
    /// the real one is not asked.
    struct FakeNode {
        var role: String?
        var title: String?
        var position: (x: Double, y: Double)?
        var size: (width: Double, height: Double)?
        var parent: Int?
        var children: [Int]?
    }

    /// A synthetic AX hierarchy, with an independent count of the IPC round
    /// trips it was asked for and an optional per-call delay.
    ///
    /// **The delay is what makes the wall-clock budget checkable at all.**
    /// Without it every call returns instantly, `budgetExceeded` is
    /// unreachable, and the branch that produces it would be dead code that
    /// three green checks nonetheless report on.
    ///
    /// `calls` is counted here, by the thing making the calls, and compared
    /// against the `axCalls` the observer writes into the record. Two
    /// independent counts of one quantity: if the observer's arithmetic drifts
    /// from what it actually asked for, this disagrees.
    nonisolated final class FakeAXSource: AXElementSource, @unchecked Sendable {
        typealias Element = Int

        let nodes: [FakeNode]
        let hitIndex: Int?
        let microsecondsPerCall: UInt32
        /// Delay only the elements at or past this index.
        ///
        /// **Needed because "slow everywhere" cannot reach some states.** A
        /// uniformly slow source exhausts the budget during the ancestor walk,
        /// so the children phase is never entered and
        /// `childrenReadsCutShortByBudget` and the depth-cap-then-overrun case
        /// are both unreachable — the second of which is the one that shows
        /// `truncation` being overwritten. Children live at the end of the
        /// node array, so an index threshold makes the walk fast and the
        /// children slow without the fake needing to know which phase it is in.
        let slowElementsFrom: Int?
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }

        init(nodes: [FakeNode], hitIndex: Int?, microsecondsPerCall: UInt32 = 0,
             slowElementsFrom: Int? = nil) {
            self.nodes = nodes
            self.hitIndex = hitIndex
            self.microsecondsPerCall = microsecondsPerCall
            self.slowElementsFrom = slowElementsFrom
        }

        private func charge(_ element: Int? = nil) {
            lock.withLock { _calls += 1 }
            guard microsecondsPerCall > 0 else { return }
            if let threshold = slowElementsFrom {
                guard let element, element >= threshold else { return }
            }
            usleep(microsecondsPerCall)
        }

        func hitTest(globalTopLeftX: Double, globalTopLeftY: Double) -> Int? {
            charge(hitIndex); return hitIndex
        }
        func role(of element: Int) -> String? { charge(element); return nodes[element].role }
        func title(of element: Int) -> String? { charge(element); return nodes[element].title }
        func position(of element: Int) -> (x: Double, y: Double)? {
            charge(element); return nodes[element].position
        }
        func size(of element: Int) -> (width: Double, height: Double)? {
            charge(element); return nodes[element].size
        }
        func parent(of element: Int) -> Int? { charge(element); return nodes[element].parent }
        func children(of element: Int) -> [Int]? { charge(element); return nodes[element].children }
    }

    /// A hit element with `ancestorDepth` ancestors above it and `children`
    /// children below it, all with frames on the fixture's `scale: 2` display.
    ///
    /// `childrenAttributeAnswers == false` builds the element whose
    /// `kAXChildrenAttribute` did not answer — the case that must not be
    /// recorded the same way as an element with no children.
    @MainActor
    static func fakeTree(ancestorDepth: Int,
                         children: Int,
                         hitPosition: (x: Double, y: Double)? = (x: 2380, y: 250),
                         hitSize: (width: Double, height: Double)? = (width: 100, height: 100),
                         childrenAttributeAnswers: Bool = true) -> [FakeNode] {
        // 0 is the hit element; 1...ancestorDepth are its ancestors, outermost
        // last; the rest are its children.
        let firstChild = ancestorDepth + 1
        var nodes: [FakeNode] = [
            FakeNode(role: "AXButton", title: "Save",
                     position: hitPosition, size: hitSize,
                     parent: ancestorDepth > 0 ? 1 : nil,
                     children: childrenAttributeAnswers
                        ? (children > 0 ? Array(firstChild..<(firstChild + children)) : [])
                        : nil)
        ]
        for level in 1...max(ancestorDepth, 1) where ancestorDepth > 0 {
            nodes.append(FakeNode(role: level == ancestorDepth ? "AXApplication" : "AXGroup",
                                  title: nil,
                                  position: (x: 1920, y: 0), size: (width: 1920, height: 1080),
                                  parent: level < ancestorDepth ? level + 1 : nil,
                                  children: nil))
        }
        for index in 0..<children {
            nodes.append(FakeNode(role: "AXStaticText", title: nil,
                                  position: (x: 2385 + Double(index) * 10, y: 255),
                                  size: (width: 8, height: 8),
                                  parent: 0, children: []))
        }
        return nodes
    }

    /// An `AXObserver` whose accessibility predicate is **always explicit**.
    ///
    /// Never `AXObserver(arrangement:epoch:)` in this file. That form
    /// evaluates the default argument, which reads TCC — and a TCC read from
    /// this binary reports the shell's grants, not this app's, for the reason
    /// this file's header sets out at length. Routing every construction
    /// through here makes "the probe asks TCC nothing" a property of one
    /// function instead of a habit at nine call sites.
    @MainActor
    static func axObserver(_ arrangement: DisplayArrangement, _ epoch: BootEpoch,
                           accessibilityGranted: Bool = true) -> AXObserver {
        AXObserver(arrangement: arrangement, epoch: epoch,
                   accessibilityIsGranted: { accessibilityGranted })
    }

    /// A `ButtonEvent` at a global point, converted by the REAL forward path.
    ///
    /// Built through `InputObserver.normalizedPosition` rather than by writing
    /// a `NormalizedPoint` literal, because the whole question § 8.1 and § 8.4
    /// ask is whether the reverse conversion undoes the forward one. A
    /// hand-written normalised position would make both sides of that question
    /// the same guess.
    @MainActor
    static func clickEvent(atGlobalX x: Double, y: Double,
                           in arrangement: DisplayArrangement, epoch: BootEpoch) -> ButtonEvent? {
        guard let converted = InputObserver.normalizedPosition(globalTopLeftX: x, globalTopLeftY: y,
                                                               in: arrangement) else { return nil }
        return ButtonEvent(instant: HostInstant(epoch: epoch, hostTime: Minting.hostNow()),
                           position: converted.position, revision: converted.revision,
                           button: .left, phase: .down)
    }

    @MainActor
    static func theReverseConversion() {
        let (arrangement, main, retina, left) = fixtureArrangement()
        check(retina.scale == 2 && main.scale == 1,
              "fixture sanity: the reverse conversion is checked against the scale: 2 display, where "
              + "the pixels→points step is not the identity",
              actual: "main \(main.scale), retina \(retina.scale)", expected: "1 and 2")

        let globalX = 2400.0, globalY = 270.0
        guard let forward = InputObserver.normalizedPosition(globalTopLeftX: globalX,
                                                             globalTopLeftY: globalY,
                                                             in: arrangement) else {
            check(false, "a point on the scale: 2 display must route somewhere")
            return
        }
        guard let back = AXObserver.globalPoint(of: forward.position, revision: forward.revision,
                                                in: arrangement) else {
            check(false, "the reverse conversion must find the display its own revision names")
            return
        }
        print("        forward: (\(globalX), \(globalY)) pt → \(forward.position)")
        print("        reverse: → (\(back.x), \(back.y)) pt")
        check(back.x == globalX && back.y == globalY,
              "the reverse conversion returns the exact global point the forward one started from — "
              + "this is the coordinate AXUIElementCopyElementAtPosition is handed",
              actual: "(\(back.x), \(back.y))", expected: "(\(globalX), \(globalY))")

        // The two ways to get the reverse wrong, computed explicitly — neither
        // fails to compile, neither produces an out-of-range value, and both
        // collapse onto the right answer at scale: 1.
        let pixels = NormalizationContext(geometry: retina).denormalize(
            NormalizedFrame(origin: forward.position, size: NormalizedSize(width: 0, height: 0),
                            revision: retina.revision))
        let skippingThePointStep = (x: 1920 + pixels.x, y: 0 + pixels.y)
        check(back.x != skippingThePointStep.x,
              "handing denormalize's PIXELS straight back into the global space gives a different, "
              + "plausible point — off by exactly the display's scale",
              actual: "correct \(back.x) vs pixel-valued \(skippingThePointStep.x)")
        let points = retina.points(from: pixels)
        check(back.x != points.x,
              "and forgetting the display's global origin gives a point on the wrong display "
              + "entirely, which would still return a real element",
              actual: "correct \(back.x) vs unplaced \(points.x)")

        // A revision this arrangement does not contain: no point, not a
        // nearest-display guess.
        check(AXObserver.globalPoint(of: forward.position,
                                     revision: GeometryRevision(id: 0xdead_beef_dead_beef),
                                     in: arrangement) == nil,
              "a click whose revision names no attached display yields NO point — a guessed one "
              + "would hit-test a real element at a place the click never was")

        // ---- the display placed UP AND LEFT of the main one, where the
        // origin step has a sign. On the two non-negative displays above, a
        // conversion that added the origin where it should subtract is off in
        // a direction that still lands on a plausible desktop coordinate; here
        // it lands on the wrong side of zero.
        let negativeX = -1000.0, negativeY = -500.0
        guard let onLeft = InputObserver.normalizedPosition(globalTopLeftX: negativeX,
                                                            globalTopLeftY: negativeY,
                                                            in: arrangement) else {
            check(false, "a point on the display at (-1440, -900) must route there")
            return
        }
        check(onLeft.revision == left.revision,
              "a negative global point routes to the display placed left of and above the main one",
              actual: "\(onLeft.revision)", expected: "\(left.revision)")
        check((0...1).contains(onLeft.position.x) && (0...1).contains(onLeft.position.y),
              "and normalises into [0, 1] like any other display",
              actual: "(\(onLeft.position.x), \(onLeft.position.y))")
        guard let backOnLeft = AXObserver.globalPoint(of: onLeft.position,
                                                      revision: onLeft.revision,
                                                      in: arrangement) else {
            check(false, "the reverse conversion must find the negative-origin display")
            return
        }
        check(backOnLeft.x == negativeX && backOnLeft.y == negativeY,
              "the round trip returns the NEGATIVE global point unchanged — the origin step is "
              + "signed, and every other fixture display in this file hides that",
              actual: "(\(backOnLeft.x), \(backOnLeft.y))", expected: "(\(negativeX), \(negativeY))")
        // The sign mistake, computed: adding the origin where the forward
        // direction subtracts it. On the main display (origin 0) this is the
        // identity and catches nothing.
        let wrongSign = -1440.0 - (negativeX - -1440.0)
        check(backOnLeft.x != wrongSign,
              "and getting the origin's sign wrong gives a different, plausible desktop coordinate",
              actual: "correct \(backOnLeft.x) vs sign-flipped \(wrongSign)")
    }

    /// `CGGeometryBridge.point(fromAXValue:)` and `.size(fromAXValue:)`, against
    /// values built the way the accessibility API builds them.
    ///
    /// **This is the check the `NSValue` cast next door did not have.**
    /// `pointRect(fromFrameAttachment:)` was `as? NSValue` alone for a whole
    /// task: the cast failed silently on every frame of every recording, and
    /// nothing caught it because the only thing exercising that function was
    /// the live path. These two decoders have exactly the same shape — a
    /// `CFTypeRef` of an opaque type, a type-ID guard, and an out-parameter
    /// that stays zero when the call refuses — and exactly the same failure
    /// mode: a zeroed point is an element at the top-left corner of the main
    /// display, which is a legal-looking answer.
    ///
    /// `AXValueCreate` needs no permission and no running application, so
    /// there is no reason for this to be left to the live path.
    @MainActor
    static func theAXValueDecoders() {
        var point = CGPoint(x: 1234.5, y: -67.25)
        let pointValue = AXValueCreate(.cgPoint, &point)
        var size = CGSize(width: 800.75, height: 600.5)
        let sizeValue = AXValueCreate(.cgSize, &size)

        let decodedPoint = CGGeometryBridge.point(fromAXValue: pointValue)
        check(decodedPoint?.x == 1234.5 && decodedPoint?.y == -67.25,
              "an AXValue holding a position decodes to the exact scalars it was built from — "
              + "including a NEGATIVE origin, which is an ordinary coordinate for a display placed "
              + "left of or above the main one",
              actual: "\(decodedPoint as (x: Double, y: Double)?)", expected: "(1234.5, -67.25)")
        let decodedSize = CGGeometryBridge.size(fromAXValue: sizeValue)
        check(decodedSize?.width == 800.75 && decodedSize?.height == 600.5,
              "and an AXValue holding a size decodes to its own scalars, not the position's",
              actual: "\(decodedSize as (width: Double, height: Double)?)", expected: "(800.75, 600.5)")

        // The wrong AXValue TYPE. `AXValueGetValue` refuses and leaves the
        // out-parameter alone, so a decoder that ignored its return value
        // would hand back (0, 0) — an element at the corner of the display,
        // which is where a wrongly-placed zoom would go.
        check(CGGeometryBridge.point(fromAXValue: sizeValue) == nil,
              "a size AXValue read as a position yields NIL, not the zeroed point AXValueGetValue "
              + "leaves behind when it refuses",
              actual: "\(CGGeometryBridge.point(fromAXValue: sizeValue) as (x: Double, y: Double)?)")
        check(CGGeometryBridge.size(fromAXValue: pointValue) == nil,
              "and the same in the other direction",
              actual: "\(CGGeometryBridge.size(fromAXValue: pointValue) as (width: Double, height: Double)?)")

        // Not an AXValue at all — what an attribute that answered with a
        // string, or a number, would give.
        check(CGGeometryBridge.point(fromAXValue: "AXButton" as CFTypeRef) == nil,
              "a CFTypeRef that is not an AXValue is refused by the type-ID guard, which is the "
              + "guard the NSValue cast one function over did not have")
        check(CGGeometryBridge.point(fromAXValue: nil) == nil
                && CGGeometryBridge.size(fromAXValue: nil) == nil,
              "and an attribute that did not answer at all decodes to nothing")
    }

    @MainActor
    static func theFrameConversion() {
        let (arrangement, _, retina, _) = fixtureArrangement()

        // The expectation, computed from the fixture rather than typed. An AX
        // frame is global top-left POINTS, like CGEventGetLocation.
        let axX = 2400.0, axY = 270.0, axW = 100.0, axH = 50.0
        let localX = axX - 1920, localY = axY
        let pixelX = localX * retina.scale, pixelY = localY * retina.scale
        let pixelW = axW * retina.scale, pixelH = axH * retina.scale
        let expectedOriginX = pixelX / Double(retina.pixelWidth)
        // The BOTTOM edge, which is what makes this different from the point
        // formula: 1 - ((topLeftY + height) / pixelHeight).
        let expectedOriginY = 1 - ((pixelY + pixelH) / Double(retina.pixelHeight))
        print("        expected, computed from the fixture: origin (\(expectedOriginX), \(expectedOriginY))")

        check(axH > 0,
              "fixture sanity: the frame has a non-zero height, which is the only thing that makes "
              + "the bottom-edge anchor distinguishable from the top-edge one",
              actual: "\(axH)")

        guard let frame = AXObserver.normalizedFrame(globalTopLeftX: axX, globalTopLeftY: axY,
                                                     width: axW, height: axH,
                                                     in: arrangement) else {
            check(false, "an AX frame on the scale: 2 display must route somewhere")
            return
        }
        check(frame.origin == NormalizedPoint(x: expectedOriginX, y: expectedOriginY),
              "an AX frame lands at its computed normalised origin",
              actual: "(\(frame.origin.x), \(frame.origin.y))",
              expected: "(\(expectedOriginX), \(expectedOriginY))")
        check(frame.size == NormalizedSize(width: pixelW / Double(retina.pixelWidth),
                                           height: pixelH / Double(retina.pixelHeight)),
              "and at its computed normalised size — the points→pixels step applies to the "
              + "dimensions too, not only to the origin",
              actual: "\(frame.size.width)×\(frame.size.height)")
        check(frame.revision == retina.revision,
              "the frame carries the revision of the display its ORIGIN routed to, which is what "
              + "AXChainRecord.clickContainment compares against the click's own revision",
              actual: "\(frame.revision)", expected: "\(retina.revision)")

        let topEdgeAnchored = 1 - (pixelY / Double(retina.pixelHeight))
        check(frame.origin.y != topEdgeAnchored,
              "anchoring the Y flip on the frame's TOP edge gives a different, plausible answer — "
              + "wrong by exactly the frame's own height, which reads as a rounding bug and lands a "
              + "zoom on the wrong control",
              actual: "correct \(frame.origin.y) vs top-anchored \(topEdgeAnchored)")

        check(AXObserver.normalizedFrame(globalTopLeftX: 9000, globalTopLeftY: 270,
                                         width: axW, height: axH, in: arrangement) == nil,
              "a frame whose origin is on no attached display normalises to nothing, rather than "
              + "against whichever display happens to be first")
        check(AXObserver.normalizedFrame(globalTopLeftX: axX, globalTopLeftY: axY,
                                         width: axW, height: -1, in: arrangement) == nil,
              "a negative dimension from a misbehaving application yields nil — PointRect.init "
              + "would trap on it, and a trap in a walk that reads another process's UI is not a "
              + "failure mode this row can have")

        // ---- an element on the display placed up and to the left. Its AX
        // frame is reported in NEGATIVE global points, which is what a window
        // on that display actually looks like to the accessibility API.
        let (_, _, _, left) = fixtureArrangement()
        guard let onLeft = AXObserver.normalizedFrame(globalTopLeftX: -1000, globalTopLeftY: -500,
                                                      width: 200, height: 100,
                                                      in: arrangement) else {
            check(false, "an AX frame with a negative origin must route to the display it is on")
            return
        }
        let leftLocalX = (-1000.0 - -1440.0) * left.scale
        let leftLocalY = (-500.0 - -900.0) * left.scale
        check(onLeft.revision == left.revision
                && onLeft.origin.x == leftLocalX / Double(left.pixelWidth)
                && onLeft.origin.y == 1 - ((leftLocalY + 100 * left.scale) / Double(left.pixelHeight)),
              "an AX frame in negative global coordinates normalises against the display it is on, "
              + "with the origin subtracted rather than added",
              actual: "(\(onLeft.origin.x), \(onLeft.origin.y)) on \(onLeft.revision)",
              expected: "(\(leftLocalX / Double(left.pixelWidth)), "
                      + "\(1 - ((leftLocalY + 100 * left.scale) / Double(left.pixelHeight)))) on \(left.revision)")
    }

    @MainActor
    static func theWalkIsBounded() {
        let (arrangement, _, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        guard let click = clickEvent(atGlobalX: 2400, y: 270, in: arrangement, epoch: epoch) else {
            check(false, "the fixture click must convert"); return
        }

        // ---- a complete walk, and the call arithmetic.
        let plainSource = FakeAXSource(nodes: fakeTree(ancestorDepth: 3, children: 2), hitIndex: 0)
        guard let complete = axObserver(arrangement, epoch)
            .chain(at: click, source: plainSource) else {
            check(false, "a hit element must produce a record"); return
        }
        check(complete.truncation == .reachedRoot,
              "a walk that runs out of ancestors reports reachedRoot, not a cap",
              actual: "\(complete.truncation)")
        check(complete.ancestors.count == 3,
              "all three ancestors are recorded, innermost first",
              actual: "\(complete.ancestors.count)", expected: "3")
        check(complete.ancestors.last?.role == "AXApplication",
              "and the outermost one is the top of the tree — F2-3's tell that a walk completed",
              actual: complete.ancestors.last?.role ?? "nil")
        check(complete.children?.count == 2,
              "one level down is recorded too (D2-3), or the row's preference for well-bounded "
              + "descendants is unimplementable in derivation",
              actual: "\(complete.children?.count as Int?)")
        // 1 hit-test + 4 for the hit element + 3×(1 parent + 4) + 1 parent
        // lookup that came back empty + 1 children attribute + 2×4 children.
        let expectedCalls = 1 + 4 + 3 * 5 + 1 + 1 + 2 * 4
        check(complete.axCalls == expectedCalls,
              "the recorded AX call count is the round trips actually made — a frame costs TWO of "
              + "them, which is where a walk's budget goes",
              actual: "\(complete.axCalls)", expected: "\(expectedCalls)")
        check(plainSource.calls == complete.axCalls,
              "and the source's own independent count agrees with the record's",
              actual: "source \(plainSource.calls) vs record \(complete.axCalls)")
        check(complete.depthCap == AXObserver.depthCap
                && complete.walkBudgetNanos == AXObserver.walkBudgetNanos,
              "the bounds in force are recorded per observation, because the budget is a D4 "
              + "placeholder and a log written under a different one is a different measurement",
              actual: "depth \(complete.depthCap), budget \(complete.walkBudgetNanos) ns")

        // ---- the depth cap.
        let deep = axObserver(arrangement, epoch)
        guard let capped = deep.chain(at: click,
                                      source: FakeAXSource(nodes: fakeTree(ancestorDepth: 40, children: 0),
                                                           hitIndex: 0)) else {
            check(false, "a deep tree must still produce a record"); return
        }
        check(capped.truncation == .depthCapReached,
              "a 40-level hierarchy stops at the cap and says so",
              actual: "\(capped.truncation)")
        check(capped.ancestors.count == AXObserver.depthCap,
              "exactly depthCap ancestors were recorded",
              actual: "\(capped.ancestors.count)", expected: "\(AXObserver.depthCap)")
        check(capped.children == [],
              "and the children were still read: the depth cap is not the budget, and a capped walk "
              + "has spent no measurable time (F2-2: capped walks completed in 4–13 ms)",
              actual: "\(capped.children as [AXElementRecord]?)")

        // ---- the wall-clock budget. 5 ms a call against a 35 ms budget, so
        // the walk is cut off after a handful of levels while the depth cap is
        // nowhere near — the two bounds catch different things (F2-2 § 4).
        let slow = axObserver(arrangement, epoch)
        guard let starved = slow.chain(at: click,
                                       source: FakeAXSource(nodes: fakeTree(ancestorDepth: 40, children: 0),
                                                            hitIndex: 0,
                                                            microsecondsPerCall: 5_000)) else {
            check(false, "a slow source must still produce a record"); return
        }
        check(starved.truncation == .budgetExceeded,
              "a source that blocks 5 ms a call exhausts the 35 ms budget and the record says which "
              + "bound stopped it",
              actual: "\(starved.truncation)")
        check(starved.ancestors.count > 0 && starved.ancestors.count < AXObserver.depthCap,
              "it stopped short of the depth cap, which is what makes this the OTHER bound",
              actual: "\(starved.ancestors.count) ancestors of a possible \(AXObserver.depthCap)")
        check(starved.ancestors.last?.role != "AXApplication",
              "and it stopped at a mid-level container, not the top of the tree — F2-3: truncation "
              + "drops the OUTERMOST ancestors, the ones least likely to be the camera's target",
              actual: starved.ancestors.last?.role ?? "nil")

        // ---- the hit-test returning nothing.
        let empty = axObserver(arrangement, epoch)
        guard let nothing = empty.chain(at: click,
                                        source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0),
                                                             hitIndex: nil)) else {
            check(false, "a hit-test that returns nothing must still produce a record — the click "
                  + "happened"); return
        }
        check(nothing.truncation == .hitTestReturnedNothing && nothing.hit == nil,
              "no element under the pointer is a recorded fact with its own reason, not an absent "
              + "record",
              actual: "\(nothing.truncation), hit \(nothing.hit == nil ? "nil" : "present")")
        check(nothing.axCalls == 1,
              "and it cost exactly the one hit-test",
              actual: "\(nothing.axCalls)", expected: "1")
        check(empty.diagnostics.hitTestsReturnedNothingWithoutAccessibility == 0,
              "with the grant present, an empty hit-test is attributed to the CLICK — there was "
              + "nothing under the pointer",
              actual: "\(empty.diagnostics.hitTestsReturnedNothingWithoutAccessibility)", expected: "0")

        // The same click, the same source, the same empty answer — and a
        // different attribution. Both directions, because a counter that only
        // ever goes up on one of them is indistinguishable from one that is
        // wired to a constant.
        let blind = axObserver(arrangement, epoch, accessibilityGranted: false)
        _ = blind.chain(at: click, source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0),
                                                        hitIndex: nil))
        check(blind.diagnostics.hitTestsReturnedNothing == 1
                && blind.diagnostics.hitTestsReturnedNothingWithoutAccessibility == 1,
              "without the grant the identical empty record is attributed to the PERMISSION — "
              + "CapturePermission.accessibility's stated degradation is .noElementIdentity, and "
              + "this is where a whole recording of empty chains says so instead of reading as a "
              + "session where nobody clicked on anything",
              actual: "nothing \(blind.diagnostics.hitTestsReturnedNothing), without the grant "
                    + "\(blind.diagnostics.hitTestsReturnedNothingWithoutAccessibility)")

        // ---- empty children versus absent children, the distinction the
        // record type exists for.
        let leafSource = FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0), hitIndex: 0)
        let leafObserver = axObserver(arrangement, epoch)
        let leaf = leafObserver.chain(at: click, source: leafSource)
        check(leaf?.children == [],
              "an element read and found to have no children records the EMPTY list",
              actual: "\(leaf?.children as [AXElementRecord]??)")

        let silentSource = FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0,
                                                        childrenAttributeAnswers: false),
                                        hitIndex: 0)
        let silentObserver = axObserver(arrangement, epoch)
        let silent = silentObserver.chain(at: click, source: silentSource)
        check(silent?.children == nil,
              "an element whose children attribute did not answer records NO list — on disk that is "
              + "the difference between 'this is a leaf' and 'I never found out'",
              actual: "\(silent?.children as [AXElementRecord]??)")
        check(silentObserver.diagnostics.childrenAttributeUnavailable == 1
                && silentObserver.diagnostics.childrenNotRead == 0,
              "and the two ways to end up with no list are counted apart, even though the record "
              + "spells them the same",
              actual: "unavailable \(silentObserver.diagnostics.childrenAttributeUnavailable), "
                    + "not read \(silentObserver.diagnostics.childrenNotRead)")
    }

    @MainActor
    static func theRecordedElementIsCheckableAgainstTheClick() {
        let (arrangement, main, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        guard let click = clickEvent(atGlobalX: 2400, y: 270, in: arrangement, epoch: epoch) else {
            check(false, "the fixture click must convert"); return
        }

        // ---- the positive direction: the element the hit-test returned
        // really is under the click.
        //
        // The element's frame is global (2380, 250) 100×100 pt, which contains
        // (2400, 270); the click's position is whatever the REAL forward
        // conversion produced. Nothing here is hand-normalised, so the check
        // spans both conversions and the walk.
        let containing = axObserver(arrangement, epoch)
        guard let record = containing.chain(at: click,
                                            source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1,
                                                                                 children: 0),
                                                                 hitIndex: 0)) else {
            check(false, "the click must produce a record"); return
        }
        check(record.hitTestGlobalX == 2400 && record.hitTestGlobalY == 270,
              "the record carries the global point the hit-test was ACTUALLY performed at — without "
              + "it, 'asked at the wrong place' and 'asked at the right place, answered wrongly' are "
              + "the same record",
              actual: "(\(record.hitTestGlobalX), \(record.hitTestGlobalY))", expected: "(2400.0, 270.0)")
        check(record.clickContainment == .containsTheClick,
              "the click falls inside the returned element's own frame, computed from the record "
              + "alone — no re-running, no arrangement needed",
              actual: "\(record.clickContainment)")
        check(containing.diagnostics.clickInsideTheHitFrame == 1
                && containing.diagnostics.clickOutsideTheHitFrame == 0,
              "and the standing instrument agrees with what a reader would recompute",
              actual: containing.diagnostics.accounting)

        // ---- the negative direction, which is the whole point: a click
        // outside the returned element's frame is a COORDINATE fault, and it
        // must not be attributable to AX staleness. The element below sits at
        // global (2000, 250) 50×50 pt — nowhere near the click.
        let elsewhere = axObserver(arrangement, epoch)
        guard let wrong = elsewhere.chain(
            at: click,
            source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0,
                                                 hitPosition: (x: 2000, y: 250),
                                                 hitSize: (width: 50, height: 50)),
                                 hitIndex: 0)) else {
            check(false, "the click must produce a record"); return
        }
        check(wrong.clickContainment == .doesNotContainTheClick,
              "an element that does not contain the click is reported as such — this is the check "
              + "that could not fail if the conversion were wrong in either direction",
              actual: "\(wrong.clickContainment)")
        check(elsewhere.diagnostics.clickOutsideTheHitFrame == 1,
              "and it lands in the counter that reads as 'the coordinate path is wrong' when it "
              + "equals the click count, rather than disappearing into a boolean",
              actual: elsewhere.diagnostics.accounting)

        // ---- neither fault: the element's origin is on the OTHER display, so
        // the two normalised frames are not comparable at all. A window
        // straddling two displays does this legitimately.
        let straddling = axObserver(arrangement, epoch)
        let acrossDisplays = straddling.chain(
            at: click,
            source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0,
                                                 hitPosition: (x: 100, y: 100),
                                                 hitSize: (width: 4000, height: 400)),
                                 hitIndex: 0))
        check(acrossDisplays?.hit?.frame?.revision == main.revision,
              "fixture sanity: that element's frame normalised against the OTHER display",
              actual: "\(acrossDisplays?.hit?.frame?.revision as GeometryRevision??)")
        check(acrossDisplays?.clickContainment == .notComparable,
              "two frames from two displays are not comparable, and the record says so rather than "
              + "trapping the way NormalizedFrame.contains would — this is neither a coordinate "
              + "fault nor a timing one",
              actual: "\(acrossDisplays?.clickContainment as ClickContainment??)")

        // ---- the timing half of the same split, from the same record.
        check(record.clickToHitTestAnswerNanos.map { $0 >= 0 } == true,
              "the record also carries the timing exposure — click stamp to hit-test answer — so "
              + "the two candidate explanations are separable from one record",
              actual: "\(record.clickToHitTestAnswerNanos as Int64?) ns")
        check(record.hitTestInterval.duration.rawValue >= 0
                && record.hitTestInterval.epoch == click.instant.epoch,
              "and the interval is on the click's own clock, which is what makes that subtraction "
              + "mean anything",
              actual: "\(record.hitTestInterval.duration.rawValue) ns")
    }

    @MainActor
    static func theAXDiagnosticsBalance() {
        let (arrangement, _, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        let observer = axObserver(arrangement, epoch)
        guard let click = clickEvent(atGlobalX: 2400, y: 270, in: arrangement, epoch: epoch) else {
            check(false, "the fixture click must convert"); return
        }

        // Four clicks over three different outcomes, plus one that cannot be
        // converted back to a global point at all.
        _ = observer.chain(at: click, source: FakeAXSource(nodes: fakeTree(ancestorDepth: 2, children: 1),
                                                           hitIndex: 0))
        _ = observer.chain(at: click, source: FakeAXSource(nodes: fakeTree(ancestorDepth: 40, children: 0),
                                                           hitIndex: 0))
        _ = observer.chain(at: click, source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0),
                                                           hitIndex: nil))
        let stale = ButtonEvent(instant: click.instant, position: click.position,
                                revision: GeometryRevision(id: 0x5747_0000_0000_0001),
                                button: .left, phase: .down)
        let noRecord = observer.chain(at: stale,
                                      source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0),
                                                           hitIndex: 0))

        let d = observer.diagnostics
        print("        " + d.accounting.replacingOccurrences(of: "\n", with: "\n        "))
        check(noRecord == nil,
              "a click whose revision names no attached display produces NO record — not one "
              + "hit-tested at a guessed point")
        check(d.clicksObserved == 4 && d.chainsRecorded == 3 && d.clicksWithNoGlobalPoint == 1,
              "every click is accounted for: three recorded, one unconvertible",
              actual: "observed \(d.clicksObserved), recorded \(d.chainsRecorded), "
                    + "no point \(d.clicksWithNoGlobalPoint)")
        check(d.everyClickIsAccountedFor,
              "clicks = records + clicks with no global point — accumulated over four calls, which "
              + "is where a dropped line in merge would show up")
        check(d.everyRecordHasATruncationReason,
              "records = reachedRoot + depthCapReached + budgetExceeded + hitTestReturnedNothing",
              actual: d.accounting)
        check(d.everyRecordHasAContainmentVerdict,
              "records = inside + outside + not comparable + no frame + no element. Within one "
              + "call this is structurally true (finish switches exhaustively); what it checks is "
              + "merge's hand-copied accumulation across the four calls above",
              actual: d.accounting)
        check(d.hitTestsReturnedNothing == 1 && d.recordsWithNoHitElement == 1,
              "the empty hit-test appears in both laws, once each",
              actual: "\(d.hitTestsReturnedNothing) and \(d.recordsWithNoHitElement)")
        check(d.nonMonotonicClockReadings == 0,
              "and no interval was measured backwards — the readings come from one monotonic clock",
              actual: "\(d.nonMonotonicClockReadings)")
    }

    /// **Every counter in `AXObserver.Diagnostics` that partitions a real
    /// decision, driven to non-zero — and its neighbour held at zero in the
    /// same call.**
    ///
    /// Six of these counters had no check in either direction after the first
    /// round of this task, and two more were only ever asserted at zero, which
    /// passes trivially. The concrete cost, and the reason this section exists
    /// rather than a note: `describe`'s unusable/unroutable split is what
    /// tells "an Electron app reported a NaN size" from "the element is on a
    /// display this arrangement does not cover" — two different faults with
    /// two different fixes — and **inverting that condition turned nothing
    /// red**. Every real run would then have attributed both to the wrong
    /// cause, which is coordinate-fault-versus-timing-fault (§ 8.4) one level
    /// down.
    ///
    /// So each check below pins the counter that must fire **and** the ones
    /// that must not. A counter checked only in the direction that fires
    /// cannot tell a partition from a constant.
    @MainActor
    static func theAXCountersAreDrivenInBothDirections() {
        let (arrangement, _, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        guard let click = clickEvent(atGlobalX: 2400, y: 270, in: arrangement, epoch: epoch) else {
            check(false, "the fixture click must convert"); return
        }

        // ---- elementsDescribed: exact, not merely non-zero.
        let counted = axObserver(arrangement, epoch)
        _ = counted.chain(at: click,
                          source: FakeAXSource(nodes: fakeTree(ancestorDepth: 3, children: 2),
                                               hitIndex: 0))
        check(counted.diagnostics.elementsDescribed == 6,
              "one hit element + three ancestors + two children were described, and the counter "
              + "says exactly that rather than merely being non-zero",
              actual: "\(counted.diagnostics.elementsDescribed)", expected: "6")

        // ---- the three ways a frame fails, each pinned against the other two.
        //
        // The hit element is the only node varied; the ancestor above it keeps
        // a good frame, so a counter that fired for the wrong element would
        // show up as a count of 2 rather than 1.
        func hitElementFrame(position: (x: Double, y: Double)?,
                             size: (width: Double, height: Double)?) -> [FakeNode] {
            var nodes = fakeTree(ancestorDepth: 1, children: 0)
            nodes[0].position = position
            nodes[0].size = size
            return nodes
        }

        let unavailable = axObserver(arrangement, epoch)
        let noFrame = unavailable.chain(at: click,
                                        source: FakeAXSource(nodes: hitElementFrame(position: nil,
                                                                                    size: (100, 100)),
                                                             hitIndex: 0))
        check(unavailable.diagnostics.elementFramesUnavailable == 1
                && unavailable.diagnostics.elementFramesUnusable == 0
                && unavailable.diagnostics.elementFramesUnroutable == 0,
              "an element whose position attribute did not answer counts as UNAVAILABLE and as "
              + "neither of the other two",
              actual: "unavailable \(unavailable.diagnostics.elementFramesUnavailable), "
                    + "unusable \(unavailable.diagnostics.elementFramesUnusable), "
                    + "unroutable \(unavailable.diagnostics.elementFramesUnroutable)")
        check(noFrame?.hit?.frame == nil && noFrame?.clickContainment == .noFrameRecorded,
              "and the record carries no frame at all — never a zero rectangle, which would be an "
              + "element at the corner of the main display",
              actual: "\(noFrame?.clickContainment as ClickContainment??)")

        let unusable = axObserver(arrangement, epoch)
        _ = unusable.chain(at: click,
                           source: FakeAXSource(nodes: hitElementFrame(position: (2380, 250),
                                                                       size: (.nan, 100)),
                                                hitIndex: 0))
        check(unusable.diagnostics.elementFramesUnusable == 1
                && unusable.diagnostics.elementFramesUnroutable == 0
                && unusable.diagnostics.elementFramesUnavailable == 0,
              "an element that answered with a NaN dimension counts as UNUSABLE — the target "
              + "application misreported itself, which is not the same fault as being off-display",
              actual: "unavailable \(unusable.diagnostics.elementFramesUnavailable), "
                    + "unusable \(unusable.diagnostics.elementFramesUnusable), "
                    + "unroutable \(unusable.diagnostics.elementFramesUnroutable)")

        let unroutable = axObserver(arrangement, epoch)
        _ = unroutable.chain(at: click,
                             source: FakeAXSource(nodes: hitElementFrame(position: (9000, 9000),
                                                                         size: (100, 100)),
                                                  hitIndex: 0))
        check(unroutable.diagnostics.elementFramesUnroutable == 1
                && unroutable.diagnostics.elementFramesUnusable == 0
                && unroutable.diagnostics.elementFramesUnavailable == 0,
              "an element whose frame is on no display in this arrangement counts as UNROUTABLE — "
              + "a well-formed frame somewhere this observer cannot place",
              actual: "unavailable \(unroutable.diagnostics.elementFramesUnavailable), "
                    + "unusable \(unroutable.diagnostics.elementFramesUnusable), "
                    + "unroutable \(unroutable.diagnostics.elementFramesUnroutable)")

        // ---- a click stamped in another boot session.
        let otherEpoch = BootEpoch(id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        let crossEpoch = axObserver(arrangement, epoch)
        let fromAnotherBoot = ButtonEvent(
            instant: HostInstant(epoch: otherEpoch, hostTime: Minting.hostNow()),
            position: click.position, revision: click.revision, button: .left, phase: .down)
        let crossRecord = crossEpoch.chain(at: fromAnotherBoot,
                                           source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1,
                                                                                children: 0),
                                                                hitIndex: 0))
        check(crossEpoch.diagnostics.clicksFromAnotherEpoch == 1,
              "a click stamped in a different boot session is counted, not corrected",
              actual: "\(crossEpoch.diagnostics.clicksFromAnotherEpoch)", expected: "1")
        check(crossRecord?.hitTestInterval.epoch == otherEpoch,
              "and the record is stamped with the CLICK's epoch, not the observer's — otherwise "
              + "clickToHitTestAnswerNanos would subtract two instants from two clocks",
              actual: "\(crossRecord?.hitTestInterval.epoch as BootEpoch??)")
        check(crossRecord?.clickToHitTestAnswerNanos != nil,
              "so the timing exposure is still computable for it",
              actual: "\(crossRecord?.clickToHitTestAnswerNanos as Int64??)")

        // ---- the depth cap reached AND the budget exhausted afterwards.
        //
        // This is the case where the record's single `truncation` field cannot
        // hold both facts: it ends as `.budgetExceeded`, so the final-verdict
        // counter never sees the cap. `ancestorWalksStoppedAtTheDepthCap` is
        // counted at the walk instead, which is the only place the fact
        // exists.
        //
        // 40 ancestors walked at full speed, then children at 5 ms a call:
        // children live from index 41 upward in `fakeTree`'s layout.
        let both = axObserver(arrangement, epoch)
        let cappedThenStarved = both.chain(
            at: click,
            source: FakeAXSource(nodes: fakeTree(ancestorDepth: 40, children: 4),
                                 hitIndex: 0, microsecondsPerCall: 5_000, slowElementsFrom: 41))
        let d = both.diagnostics
        check(cappedThenStarved?.truncation == .budgetExceeded,
              "the record's truncation is the LAST thing that stopped it — the children read",
              actual: "\(cappedThenStarved?.truncation as ChainTruncation??)")
        check(cappedThenStarved?.ancestors.count == AXObserver.depthCap,
              "and the walk did reach the cap: \(AXObserver.depthCap) ancestors are recorded",
              actual: "\(cappedThenStarved?.ancestors.count as Int??)")
        check(d.truncatedDepthCapReached == 0 && d.truncatedBudgetExceeded == 1,
              "the final-verdict counters see only .budgetExceeded, which is why they are not the "
              + "place to read 'is the depth cap starting to bind'",
              actual: "depth \(d.truncatedDepthCapReached), budget \(d.truncatedBudgetExceeded)")
        check(d.ancestorWalksStoppedAtTheDepthCap == 1,
              "the walk-phase counter sees the cap anyway — the instrument that would show "
              + "hierarchies outgrowing 30, which a field another phase overwrites cannot",
              actual: "\(d.ancestorWalksStoppedAtTheDepthCap)", expected: "1")
        check(d.childrenReadsCutShortByBudget == 1 && d.childrenNotRead == 0,
              "and the children list was read but not finished — 'cut short' rather than 'never "
              + "asked', which are different facts about the same nil-shaped absence",
              actual: "cut short \(d.childrenReadsCutShortByBudget), not read \(d.childrenNotRead)")
        check((cappedThenStarved?.children?.count ?? 4) < 4,
              "the recorded children are fewer than the element has, and truncation says so rather "
              + "than the list quietly claiming to be complete",
              actual: "\(cappedThenStarved?.children?.count as Int??) of 4")
        check(d.everyRecordHasATruncationReason && d.everyRecordHasAContainmentVerdict,
              "and the conservation laws still balance with the walk-phase counter outside them",
              actual: d.accounting)

        // ---- the other nil-shaped absence: the budget gone before the
        // children attribute was even asked for.
        let starvedBeforeChildren = axObserver(arrangement, epoch)
        let noAsk = starvedBeforeChildren.chain(
            at: click,
            source: FakeAXSource(nodes: fakeTree(ancestorDepth: 40, children: 4),
                                 hitIndex: 0, microsecondsPerCall: 5_000))
        check(starvedBeforeChildren.diagnostics.childrenNotRead == 1
                && starvedBeforeChildren.diagnostics.childrenReadsCutShortByBudget == 0,
              "a walk that spends the whole budget on ancestors never asks for children, and that "
              + "is counted apart from asking and stopping",
              actual: "not read \(starvedBeforeChildren.diagnostics.childrenNotRead), cut short "
                    + "\(starvedBeforeChildren.diagnostics.childrenReadsCutShortByBudget)")
        check(noAsk?.children == nil,
              "both spell the same nil in the record, which is why the counters carry the split",
              actual: "\(noAsk?.children as [AXElementRecord]??)")
    }

    /// **`ARCHITECTURE.md` D6a's last unclosed row.** The tap being switched
    /// off used to be recorded as `tapReArmedCount` — a count, which says the
    /// loss happened N times and cannot say for how long, so a recording that
    /// lost 400 ms of pointer track read identically to one that lost 4 ms.
    /// `framing-gates`' `observation stale` refusal needs a range to test a
    /// beat against; a count gives it nothing.
    ///
    /// Checked here rather than in the spike because it needs no tap: `handle`
    /// is driven directly with the two out-of-band event types, which is the
    /// same seam `§ 7.2` uses. What it cannot check is that the system ever
    /// sends them — that is the human half, and the sweep that looked for them
    /// (10 ms to 1600 ms of deliberate callback stall, seven rungs) received
    /// **zero** notifications on a `.listenOnly` tap at every rung, including
    /// the rungs where the tap really was disabled. So this path is checked
    /// for correctness and is not expected to fire for this app's own tap;
    /// `§ 7.10` covers the channel that does.
    @MainActor
    static func aDisabledTapProducesAnInterval() {
        let (arrangement, _, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        let collector = Collector()
        let observer = InputObserver(arrangement: arrangement, epoch: epoch,
                                     secureInputIsEnabled: { false })
        observer.setObservationSink(collector.append)

        // One real event first: it is the lower bound of any window that
        // follows, because the tap cannot have been disabled before the last
        // event it delivered.
        let firstStamp = Minting.hostNow()
        observer.handle(type: .mouseMoved,
                        event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270), stamp: firstStamp))
        observer.handle(type: .tapDisabledByTimeout,
                        event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270),
                                          stamp: Minting.hostNow()))

        let windows = collector.observations.compactMap { observation -> TapDisabledInterval? in
            if case .tapDisabled(let interval) = observation { return interval }
            return nil
        }
        guard windows.count == 1 else {
            check(false, "a disabled tap emits exactly one interval", actual: "\(windows.count)")
            return
        }
        check(windows[0].detectedBy == .notification,
              "this one came from the notification channel — which the control in the coordinator's "
              + "sweep proved is real for a .defaultTap, and which a .listenOnly tap was measured "
              + "never to receive",
              actual: "\(windows[0].detectedBy)")
        check(windows[0].disabledBy == .timeout,
              "the reason is recorded: .timeout is THIS app's fault (a slow callback — which "
              + "ax-observation is what makes possible) and .userInput is not",
              actual: "\(windows[0].disabledBy)")
        check(windows[0].lowerBoundFrom == .lastObservedEvent,
              "and the lower edge came from a real event, so its width is close to the true window",
              actual: "\(windows[0].lowerBoundFrom)")
        check(windows[0].interval.start == firstStamp,
              "the interval starts at the last event the tap delivered — the earliest instant the "
              + "disable could have happened",
              actual: "\(windows[0].interval.start.rawValue)", expected: "\(firstStamp.rawValue)")
        check(windows[0].interval.duration.rawValue > 0,
              "and it has a width, which is the whole difference from the count it replaced",
              actual: "\(windows[0].interval.duration.rawValue) ns")
        check(observer.diagnostics.tapDisabledIntervals == 1
                && observer.diagnostics.tapBlindNanos == windows[0].interval.duration.rawValue
                && observer.diagnostics.tapDisabledIntervalsWithNoObservedLowerBound == 0,
              "the run-level summary is the sum of the intervals, in the unit that was lost",
              actual: "\(observer.diagnostics.tapDisabledIntervals) windows, "
                    + "\(observer.diagnostics.tapBlindNanos) ns, "
                    + "\(observer.diagnostics.tapDisabledIntervalsWithNoObservedLowerBound) unbounded")

        // ---- a second window must not reach back past the first. If
        // `lastObservedInstant` were not moved forward on re-arming, every
        // subsequent window would start at the same stale event and
        // `tapBlindNanos` would grow quadratically while looking plausible.
        observer.handle(type: .tapDisabledByUserInput,
                        event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270),
                                          stamp: Minting.hostNow()))
        let second = collector.observations.compactMap { observation -> TapDisabledInterval? in
            if case .tapDisabled(let interval) = observation { return interval }
            return nil
        }
        guard second.count == 2 else {
            check(false, "the second disable emits its own interval", actual: "\(second.count)")
            return
        }
        check(second[1].disabledBy == .userInput,
              "the second window records the OTHER reason — user input is not this app being slow, "
              + "and reading it as such would send someone to optimise the wrong thing",
              actual: "\(second[1].disabledBy)")
        check(second[1].interval.start.rawValue >= second[0].interval.end.rawValue,
              "and it starts at or after the first one ended, rather than reaching back to the "
              + "stale event before it",
              actual: "second starts \(second[1].interval.start.rawValue), first ended "
                    + "\(second[0].interval.end.rawValue)")

        // ---- an event suppressed by secure input still proves the tap was
        // delivering. If `lastObservedInstant` were updated after the
        // secure-input branch instead of before it, a password field would
        // masquerade as a blind window — two different gaps in D6a, conflated.
        let suppressed = Collector()
        let secure = InputObserver(arrangement: arrangement, epoch: epoch,
                                   secureInputIsEnabled: { true })
        secure.setObservationSink(suppressed.append)
        let duringPassword = Minting.hostNow()
        secure.handle(type: .mouseMoved,
                      event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270), stamp: duringPassword))
        secure.handle(type: .tapDisabledByTimeout,
                      event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270), stamp: Minting.hostNow()))
        let secureWindows = suppressed.observations.compactMap { observation -> TapDisabledInterval? in
            if case .tapDisabled(let interval) = observation { return interval }
            return nil
        }
        check(secureWindows.first?.interval.start == duringPassword,
              "an event suppressed by secure input still bounds the next blind window — it is the "
              + "TAP's liveness this records, not whether anything was emitted",
              actual: "\(secureWindows.first?.interval.start.rawValue as Int64??)",
              expected: "\(duringPassword.rawValue)")
    }

    /// **The channel that actually works for this app's tap kind.**
    ///
    /// Measured, and it overturned the previous version of this section: a
    /// `.listenOnly` tap is disabled by the system **without**
    /// `kCGEventTapDisabledByTimeout` being delivered to its callback — 0
    /// notifications at every rung of a 10/50/100/200/400/800/1600 ms stall
    /// sweep, while `CGEvent.tapIsEnabled(tap:)` read false from 50 ms upward,
    /// with a `.defaultTap` control receiving the notification in the same run.
    ///
    /// (The rungs at which that sweep saw the tap go down are **sustained
    /// overload** — it stalled every `mouseMoved` at 60–120 Hz — and not a
    /// per-callback budget. That correction does not touch these checks: the
    /// notification was absent at every rung either way, which is the fact the
    /// poll exists for.)
    ///
    /// So `§ 7.9`'s interval, which is fed by the notification, is guaranteed
    /// empty in exactly the situation it was built for — and an empty list of
    /// gaps reads as "no gaps". These checks cover the poll, which is what
    /// finds it.
    ///
    /// The tap itself cannot exist here (Input Monitoring), so the enabled
    /// flag is read through `tapIsEnabledOverride`. That is the same seam, for
    /// the same reason, as `secureInputIsEnabled` — and the reason it is worth
    /// having is this whole episode: the previous two runs of the sweep
    /// concluded "the concern disappears quantitatively" from a number that
    /// counted notifications, which is the channel that does not fire.
    @MainActor
    static func thePollFindsADisabledTap() {
        let (arrangement, _, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        let collector = Collector()
        // The tap reads as enabled until this flips, which is what a stall in
        // the callback does to a real one.
        let enabled = MutableFlag(true)
        let observer = InputObserver(arrangement: arrangement, epoch: epoch,
                                     secureInputIsEnabled: { false },
                                     tapIsEnabledOverride: { enabled.value })
        observer.setObservationSink(collector.append)

        // Two polls while it is up: these are the evidence of looking, and the
        // second one is the tight lower bound for the window below.
        observer.pollTapEnabled()
        observer.pollTapEnabled()
        check(observer.diagnostics.tapEnabledPolls == 2
                && observer.diagnostics.tapDisabledIntervals == 0,
              "polls while the tap is up are counted and produce no window — 'nothing was wrong' "
              + "and 'nothing was looking' are different numbers now",
              actual: observer.diagnostics.tapAccounting)

        enabled.value = false
        observer.pollTapEnabled()

        let windows = collector.observations.compactMap { observation -> TapDisabledInterval? in
            if case .tapDisabled(let interval) = observation { return interval }
            return nil
        }
        guard windows.count == 1 else {
            check(false, "the poll must emit exactly one window for one disable",
                  actual: "\(windows.count)")
            return
        }
        check(windows[0].detectedBy == .enabledPoll,
              "the window is attributed to the POLL — for this app's .listenOnly tap that is the "
              + "only channel that ever fires, so this is the expected shape and not a fallback",
              actual: "\(windows[0].detectedBy)")
        check(windows[0].disabledBy == nil,
              "and no reason is invented: the poll saw that the tap was off, nothing told it why, "
              + "and .timeout would be an accusation that this app's own callback was too slow",
              actual: "\(windows[0].disabledBy as TapDisableReason??)")
        check(windows[0].lowerBoundFrom == .lastEnabledPoll,
              "the lower edge came from the last poll that read ENABLED — not from the last event, "
              + "which is the bound that stops improving the moment the tap goes off, because a "
              + "disabled tap delivers no events",
              actual: "\(windows[0].lowerBoundFrom)")
        check(observer.diagnostics.tapDisabledIntervalsFoundByPolling == 1,
              "and the run-level summary says how it was found",
              actual: observer.diagnostics.tapAccounting)

        // ---- the warning that makes an empty window list legible to a
        // person, in both directions. It is the one line in `tapAccounting`
        // aimed at a human reading a spike's output rather than at a check,
        // which is exactly why nothing was checking it: delete it and every
        // other assertion in this file stays green while the single output a
        // human reads loses the sentence that says the zero above it means
        // nothing.
        check(!observer.diagnostics.tapAccounting.contains("NOTHING WAS LOOKING"),
              "with polls on the clock, the accounting does NOT warn that nothing was looking",
              actual: observer.diagnostics.tapAccounting)
        let neverPolled = InputObserver(arrangement: arrangement, epoch: epoch,
                                        secureInputIsEnabled: { false },
                                        tapIsEnabledOverride: { true })
        check(neverPolled.diagnostics.tapEnabledPolls == 0
                && neverPolled.diagnostics.tapAccounting.contains("NOTHING WAS LOOKING"),
              "and an observer that has never polled says so IN THE OUTPUT — 'tapDisabledIntervals "
              + "0' is otherwise the same zero whether the tap stayed up or nothing ever checked",
              actual: neverPolled.diagnostics.tapAccounting)

        // The tap was re-enabled by the poll that found it, so the next poll
        // reads up again and produces no second window for the same outage.
        enabled.value = true
        observer.pollTapEnabled()
        let after = collector.observations.compactMap { observation -> TapDisabledInterval? in
            if case .tapDisabled(let interval) = observation { return interval }
            return nil
        }
        check(after.count == 1,
              "one outage is one window: the poll re-enables what it finds disabled, so a recovered "
              + "tap does not keep reporting the same gap",
              actual: "\(after.count)")

        // ---- the anti-vacuity half. A poll that never reads the flag would
        // pass every check above by producing nothing at all.
        let blind = InputObserver(arrangement: arrangement, epoch: epoch,
                                  secureInputIsEnabled: { false },
                                  tapIsEnabledOverride: { false })
        let blindCollector = Collector()
        blind.setObservationSink(blindCollector.append)
        blind.pollTapEnabled()
        check(blind.diagnostics.tapDisabledIntervals == 1,
              "a tap that is already down when the first poll runs is still found — the detection "
              + "does not depend on having seen it up first")
        check(blind.diagnostics.tapDisabledIntervalsWithNoObservedLowerBound == 1,
              "and with no event, no earlier poll and no start() behind it, it is flagged as "
              + "having no lower bound at all rather than reporting a width it cannot know",
              actual: blind.diagnostics.tapAccounting)
        check(blindCollector.observations.isEmpty,
              "with nothing to anchor it, NO interval is emitted — a zero-width one anchored at "
              + "'now' would read as 'no time was lost', which is the reading this whole mechanism "
              + "exists to make impossible",
              actual: "\(blindCollector.observations.count) observations")
    }

    /// **The check that fails when the poll is put on the wrong thread**, which
    /// is the mistake this mechanism exists to survive and the one that is
    /// invisible in every green run.
    ///
    /// What is being detected is the callback thread being stuck. A poll
    /// scheduled on the main run loop — where the tap's own callback runs — is
    /// blocked at exactly the moment it is needed, and is never blocked while
    /// anyone is testing, because nothing is stuck then. So this holds the
    /// main thread for several poll intervals and asserts that the count went
    /// up anyway. On a main-queue timer it does not move at all.
    @MainActor
    static func thePollRunsWhileTheMainThreadIsStuck() {
        let (arrangement, _, _, _) = fixtureArrangement()
        let observer = InputObserver(arrangement: arrangement, epoch: Minting.bootEpoch(),
                                     secureInputIsEnabled: { false },
                                     tapIsEnabledOverride: { true })
        observer.startPolling()
        defer { observer.stopPolling() }

        let before = observer.diagnostics.tapEnabledPolls
        // 500 ms of a completely blocked main thread — five poll intervals,
        // and about four times the worst hit-test Spike A measured. `usleep`
        // rather than a run-loop spin on purpose: a spin would keep servicing
        // main-queue work and the wrong design would pass.
        usleep(500_000)
        let after = observer.diagnostics.tapEnabledPolls

        print("        polls during 500 ms of a blocked main thread: \(after - before)")
        check(after - before >= 3,
              "the poll kept running while the main thread was stuck — it is on a queue of its "
              + "own, and a main-queue timer would have recorded ZERO polls across this window, "
              + "which is precisely when the tap is disabled",
              actual: "\(after - before) polls", expected: "at least 3 in 500 ms")
        check(observer.diagnostics.tapPollingSpanNanos > 0,
              "and the span those polls cover is recorded, so 'N polls' cannot be read without "
              + "knowing over how long",
              actual: "\(Double(observer.diagnostics.tapPollingSpanNanos) / 1e9) s")

        observer.stopPolling()
        let stopped = observer.diagnostics.tapEnabledPolls
        usleep(300_000)
        check(observer.diagnostics.tapEnabledPolls == stopped,
              "and stopPolling() actually stops it — a timer that outlives its observer polls a "
              + "port that has been invalidated",
              actual: "\(observer.diagnostics.tapEnabledPolls) vs \(stopped)")
    }

    /// **The consequence of the tap-timeout measurement, checked.**
    ///
    /// AX runs behind a bounded queue rather than on the tap callback thread,
    /// because of the asymmetry in `AXObserver`'s header: on the callback
    /// thread a hung target costs the **whole pointer track**, behind the
    /// queue it costs the **AX chains of the affected clicks**, counted. Not
    /// because a slow callback disables the tap — measured, 125 ms on clicks
    /// only across 18 such stalls does not, and the 10–50 ms figure this
    /// comment used to cite was an artefact of stalling every `mouseMoved`.
    ///
    /// What the queue costs is a hit-test later than the click, and the point
    /// of these checks is that the cost is **recorded** rather than absorbed
    /// into an unexplained drift between the verb and the object.
    @MainActor
    static func theAXWorkIsDeferredAndTheDelayIsRecorded() {
        let (arrangement, _, _, _) = fixtureArrangement()
        let epoch = Minting.bootEpoch()
        guard let click = clickEvent(atGlobalX: 2400, y: 270, in: arrangement, epoch: epoch) else {
            check(false, "the fixture click must convert"); return
        }

        // ---- the delay is a recorded quantity, and it is the queue's, not the
        // target application's.
        // **Through the source-taking overload, always.** `enqueue(_:onRecord:)`
        // hard-codes `LiveAXElementSource`, and this probe issuing a real
        // `AXUIElementCopyElementAtPosition` would be wrong twice over: the
        // timings below would be a fact about a mach round trip rather than
        // about the queue, so replacing the source with a fast fake — the
        // obvious later cleanup — would turn them red with nothing broken; and
        // if the launching shell happens to hold Accessibility, the probe
        // would walk a third-party application's tree, against the no-grant
        // premise this file states everywhere else.
        let observer = axObserver(arrangement, epoch)
        let records = Collected()
        // 3 ms a call, so the AX half of the wait is measurably distinct from
        // the queue half rather than lost in scheduling noise.
        observer.enqueue(click,
                         source: FakeAXSource(nodes: fakeTree(ancestorDepth: 2, children: 0),
                                              hitIndex: 0, microsecondsPerCall: 3_000),
                         onRecord: records.append)
        observer.waitForQueuedClicks()

        guard let record = records.all.first else {
            check(false, "the enqueued click must produce a record"); return
        }
        check(records.all.count == 1, "one click, one record", actual: "\(records.all.count)")
        guard let toStart = record.clickToHitTestStartNanos,
              let toAnswer = record.clickToHitTestAnswerNanos else {
            check(false, "both delays must be computable from the record"); return
        }
        print("        click → hit-test start \(Double(toStart) / 1e6) ms, "
              + "→ answer \(Double(toAnswer) / 1e6) ms")
        check(toStart >= 0 && toAnswer >= toStart,
              "the record decomposes the wait into the part this app chose (the queue) and the "
              + "part the target imposed (the IPC) — a gate that rejects stale observations needs "
              + "them apart, because raising a budget fixes one and not the other",
              actual: "start \(toStart) ns, answer \(toAnswer) ns")
        check(toAnswer - toStart == record.hitTestInterval.duration.rawValue,
              "and the two parts sum to the whole, so neither can drift without the other showing "
              + "it",
              actual: "\(toAnswer - toStart) vs \(record.hitTestInterval.duration.rawValue)")

        // ---- the caller's thread is not where the AX work happened.
        let threads = MutableFlag(false)
        let onMain = axObserver(arrangement, epoch)
        onMain.enqueue(click,
                       source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0),
                                            hitIndex: 0)) { _ in
            threads.value = Thread.isMainThread
        }
        onMain.waitForQueuedClicks()
        check(!threads.value,
              "the record is produced OFF the main thread — which is where InputObserver's tap "
              + "callback runs, and where a hung target would cost the whole pointer track rather "
              + "than one click's AX chain",
              actual: "isMainThread \(threads.value)")

        // ---- the backlog is bounded and the drop is counted.
        //
        // One hung target: every AX call blocks for 40 ms, so the queue cannot
        // keep up with a burst of clicks and the ones past the cap must be
        // refused rather than accumulated.
        let hung = axObserver(arrangement, epoch)
        let hungRecords = Collected()
        let burst = AXObserver.maximumQueuedClicks + 6
        // **The fixture the comment above always claimed and the code did not
        // have.** Without a slow source the drop happened only because a real
        // mach round trip is slower than a lock plus a dispatch — true today,
        // a fact about neither the queue nor the cap, and red the moment
        // anyone made the source fast.
        let hungSource = FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0),
                                      hitIndex: 0, microsecondsPerCall: 40_000)
        for _ in 0..<burst {
            hung.enqueue(click, source: hungSource, onRecord: hungRecords.append)
        }
        hung.waitForQueuedClicks()
        let d = hung.diagnostics
        print("        " + d.accounting.replacingOccurrences(of: "\n", with: "\n        "))
        check(d.clicksDroppedByBacklog > 0,
              "a burst deeper than the cap drops clicks rather than growing without bound — one "
              + "beachballed application and a person still clicking is the case",
              actual: "\(d.clicksDroppedByBacklog) of \(burst) dropped")
        check(d.clicksObserved == burst,
              "every click in the burst is counted as having HAPPENED, including the dropped ones",
              actual: "\(d.clicksObserved)", expected: "\(burst)")
        check(d.everyClickIsAccountedFor,
              "clicks = recorded + no global point + dropped by backlog — the third term is what "
              + "stops the law balancing by simply not counting the drops",
              actual: d.accounting)
        check(d.deepestBacklog > 1 && d.deepestBacklog <= AXObserver.maximumQueuedClicks,
              "the queue really did back up — deeper than one, and never deeper than the cap. The "
              + "upper half alone is satisfied by a counter that is never updated at all",
              actual: "\(d.deepestBacklog)",
              expected: "between 2 and \(AXObserver.maximumQueuedClicks)")
    }

    // MARK: - § 9  observation-log (Task 11)
    //
    // **What this section can and cannot reach, said before the checks rather
    // than after.** Every record type here is built by hand and handed to
    // `ObservationWriter` directly. Nothing below records a screen, creates an
    // event tap or hit-tests a real element — all three need a TCC grant this
    // probe cannot hold (see the header). So these checks are about the LOG:
    // one file per segment, one clock, the header and trailer that bracket it,
    // and what survives a crash. That the live observers feed it is the human
    // step's job, and the report says exactly what that step must assert.
    //
    // The fixture is a three-segment recording on one boot epoch, mirroring
    // § 6's ledger: paused, then a display reconfiguration, then stopped.

    /// A fixture recording: a segment table plus one written log per segment.
    struct FixtureRecording {
        let packageURL: URL
        let table: SegmentTable
        let logURLs: [URL]
        let epoch: BootEpoch
        let anchor: EpochAnchor
        /// Pointer samples appended per segment, at `pointerHz`.
        let pointerCounts: [Int]
        let pointerHz: Int
        let clickInstants: [HostInstant]
    }

    /// Builds the fixture. Kept in one place so § 9's checks are all about the
    /// same bytes rather than each rebuilding a slightly different recording.
    @MainActor
    static func writeFixtureRecording(pointerHz: Int = 120) throws -> FixtureRecording {
        let fm = FileManager.default
        let packageURL = fm.temporaryDirectory
            .appending(path: "t11-probe-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(), mediaFilenames: []),
            to: packageURL)

        // `Minting.epochAnchor()`, not `bootEpoch()`: the header dates the
        // recording, and this is the call that reads a wall clock at the one
        // audited boundary. It had no caller in the repository before Task 11.
        let recordingAnchor = Minting.epochAnchor()
        let epoch = recordingAnchor.epoch
        let revisionA = GeometryRevision(id: 0xAAAA_AAAA)
        let revisionB = GeometryRevision(id: 0xBBBB_BBBB)
        func instant(_ nanos: Int64) -> HostInstant {
            HostInstant(epoch: epoch, hostTime: Nanoseconds(nanos))
        }

        // Three segments, one second each, with a one-second pause gap between
        // 0 and 1 — the shape § 6 already pins, so a change to the ledger
        // reddens there first and here second.
        var ledger = SegmentLedger()
        ledger.openSegment(at: instant(0), revision: revisionA, mediaFilename: "master-00.mov")
        _ = ledger.closeSegment(at: instant(1_000_000_000), endedBy: .paused)
        ledger.openSegment(at: instant(2_000_000_000), revision: revisionA, mediaFilename: "master-01.mov")
        _ = ledger.closeSegment(at: instant(3_000_000_000),
                                endedBy: .displayReconfigured(newRevision: revisionB))
        ledger.openSegment(at: instant(3_000_000_000), revision: revisionB, mediaFilename: "master-02.mov")
        _ = ledger.closeSegment(at: instant(4_000_000_000), endedBy: .stopped)
        let table = try ledger.finish()

        var logURLs: [URL] = []
        var pointerCounts: [Int] = []
        var clickInstants: [HostInstant] = []
        let step = Int64(1_000_000_000 / pointerHz)

        for segment in table.segments {
            let header = ObservationLogHeader(anchor: recordingAnchor, segmentIndex: segment.index,
                                              mediaFilename: segment.mediaFilename,
                                              revision: segment.revision,
                                              blindness: [])
            let writer = try ObservationWriter.open(segment: header, in: packageURL)
            // Declared even where none is written, so the trailer says "this
            // producer emits shortcuts and saw none" rather than nothing.
            writer.declareRecordKind("key")

            var appended = 0
            var t = segment.hostRange.start.rawValue
            while t < segment.hostRange.end.rawValue {
                let fraction = Double(t - segment.hostRange.start.rawValue)
                    / Double(max(segment.hostRange.duration.rawValue, 1))
                try writer.append(PointerSample(
                    instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(t)),
                    position: NormalizedPoint(x: 0.1 + 0.8 * fraction, y: 0.2 + 0.5 * fraction),
                    revision: segment.revision))
                appended += 1
                t += step
            }
            pointerCounts.append(appended)

            // One click per segment, a third of the way in, with the AX chain
            // that is its object half — stamped with the SAME instant, which is
            // the join key (D2-1).
            let clickAt = HostInstant(
                epoch: epoch,
                hostTime: Nanoseconds(segment.hostRange.start.rawValue
                                      + segment.hostRange.duration.rawValue / 3))
            clickInstants.append(clickAt)
            let clickPosition = NormalizedPoint(x: 0.42, y: 0.37)
            try writer.append(ButtonEvent(instant: clickAt, position: clickPosition,
                                          revision: segment.revision,
                                          button: .left, phase: .down))
            // The hit-test starts AFTER the click — the queue hop
            // `AXChainRecord.clickToHitTestStartNanos` exists to record — and
            // the element is read after that again.
            let hitTest = HostRange(epoch: epoch,
                                    start: Nanoseconds(clickAt.hostTime.rawValue + 2_000_000),
                                    duration: Nanoseconds(1_050_000))
            let elementRead = HostRange(epoch: epoch,
                                        start: Nanoseconds(hitTest.end.rawValue),
                                        duration: Nanoseconds(4_200_000))
            let hit = AXElementRecord(
                role: "AXButton", title: "Save",
                frame: NormalizedFrame(origin: NormalizedPoint(x: 0.40, y: 0.35),
                                       size: NormalizedSize(width: 0.06, height: 0.04),
                                       revision: segment.revision),
                readInterval: elementRead)
            try writer.append(AXChainRecord(
                instant: clickAt,
                clickPosition: clickPosition,
                clickRevision: segment.revision,
                hitTestGlobalX: 812, hitTestGlobalY: 494,
                hitTestInterval: hitTest,
                hit: hit,
                ancestors: [AXElementRecord(role: "AXWindow", title: nil, frame: nil,
                                            readInterval: elementRead)],
                children: [],
                truncation: .reachedRoot,
                axCalls: 41, depthCap: 30, walkBudgetNanos: 35_000_000))

            let url = try writer.close(
                endedBy: segment.endedBy,
                hostRange: segment.hostRange,
                gapWatches: fixtureGapWatches(segment: segment, chainsAppended: 1))
            logURLs.append(url)
        }

        return FixtureRecording(packageURL: packageURL, table: table, logURLs: logURLs,
                                epoch: epoch, anchor: recordingAnchor, pointerCounts: pointerCounts,
                                pointerHz: pointerHz, clickInstants: clickInstants)
    }

    /// One `GapWatch` per producer-measurable D6a site, through the **named**
    /// constructors.
    ///
    /// **The first version of this function was the review finding.** It wrote
    /// `looks: 1` for `.jsonlTruncatedTail` over a fixture in which not one byte
    /// had been scanned — a fabricated measurement, which § 9.6 then asserted
    /// *was* one — and `looks: pointerSamples` for the video and tap rows, a
    /// proxy standing in for its subject. The site no longer exists (it is
    /// `ObservationLogReadReport`'s, because a producer has no reader) and the
    /// named constructors' parameter labels are each producer's own counter
    /// names, so passing a proxy now costs a visible rename here.
    ///
    /// This fixture has no live observers, so the numbers below are the
    /// fixture's own: `chainsRecorded` is the one chain it appended, and the
    /// tap row's `looks` is the poll count a 100 ms poll would have made across
    /// the segment. The secure-input row is deliberately left at zero looks, so
    /// § 9.6 has a negative control that is a real row rather than a synthetic
    /// one.
    static func fixtureGapWatches(segment: MasterSegment, chainsAppended: Int) -> [GapWatch] {
        let span = segment.hostRange.duration.rawValue
        return [
            // The one row this fixture genuinely measured: it appended these
            // chains itself.
            GapWatch.axAncestorWalk(chainsRecorded: chainsAppended,
                                    observationSpanNanos: span, truncatedWalks: 0),
            // Three zeros, and they are the honest values. This fixture runs no
            // `CaptureSession`, no secure-input predicate and no `InputObserver`
            // poll, so nothing looked at any of these sites.
            //
            // The tap row carried `Int(span / 100_000_000)` — "the polls a
            // 100 ms timer would have made" — until the second review round,
            // and § 9.6 asserted that row WAS a measurement. That is the shape
            // `jsonlTruncatedTail` was condemned for, surviving one site over:
            // a number that never came from a poll, in the field that says
            // whether a poll happened. A regression stopping `InputObserver`
            // polling entirely would have left it green.
            GapWatch.videoFramesNotProduced(frameCallbacksObserved: 0,
                                            observationSpanNanos: span, idleFrames: 0),
            GapWatch.secureInput(secureInputChecks: 0, secureInputCheckSpanNanos: 0,
                                 secureInputIntervals: 0, suppressedNanos: 0),
            GapWatch.tapDisabled(tapEnabledPolls: 0, tapPollingSpanNanos: 0,
                                 tapDisabledIntervals: 0, tapBlindNanos: 0),
        ]
    }

    /// Reads one log back, splitting it into its header, its trailer and the
    /// records between, and reporting what `JSONLReader` said about the bytes.
    struct ReadLog {
        let header: ObservationLogHeader?
        let trailer: ObservationLogTrailer?
        let lines: [(kind: String, bytes: Data)]
        let droppedBytes: Int
        let bytesScanned: Int
    }

    static func readLog(at url: URL) throws -> ReadLog {
        // The package's own reader is exercised alongside, so § 9 checks the
        // type a caller will actually use rather than only this local copy.
        let report = try ObservationLogReadReport.read(logAt: url)
        let result = try JSONLReader.linesOfFile(at: url)
        var header: ObservationLogHeader?
        var trailer: ObservationLogTrailer?
        var lines: [(kind: String, bytes: Data)] = []
        for line in result.lines {
            let kind = try ObservationLog.kind(of: line)
            switch kind {
            case "logHeader": header = try ObservationLog.decode(line)
            case "logTrailer": trailer = try ObservationLog.decode(line)
            default: lines.append((kind, line))
            }
        }
        precondition(report.recordLines == lines.count
                     && report.droppedBytes == result.droppedBytes
                     && report.bytesScanned == result.bytesScanned
                     && report.closedCleanly == (trailer != nil),
                     "ObservationLogReadReport disagrees with this section's own reader — one of "
                     + "them is wrong and neither may be trusted")
        return ReadLog(header: header, trailer: trailer, lines: lines,
                       droppedBytes: result.droppedBytes, bytesScanned: result.bytesScanned)
    }

    /// Every instant a record of this kind carries, for the containment check.
    static func instants(inRecordOfKind kind: String, bytes: Data) throws -> [HostInstant] {
        switch kind {
        case "pointer": [try (ObservationLog.decode(bytes) as PointerSample).instant]
        case "button": [try (ObservationLog.decode(bytes) as ButtonEvent).instant]
        case "key": [try (ObservationLog.decode(bytes) as KeySample).instant]
        case "axChain": [try (ObservationLog.decode(bytes) as AXChainRecord).instant]
        case "secureInput":
            [HostInstant(epoch: try (ObservationLog.decode(bytes) as SecureInputInterval).interval.epoch,
                         hostTime: try (ObservationLog.decode(bytes) as SecureInputInterval).interval.start)]
        default: []
        }
    }

    @MainActor
    static func oneLogPerSegment() throws {
        let fixture = try writeFixtureRecording()
        defer { try? FileManager.default.removeItem(at: fixture.packageURL) }

        check(Set(fixture.logURLs).count == fixture.table.segments.count,
              "one observation log per segment, and no more — DISTINCT urls, because the plan's "
              + "`logURLs.count == segments.count` is satisfied by three handles onto one file, "
              + "measured: a writer mutated to name every log `segment.jsonl` passes that form "
              + "of the check and fails this one",
              actual: "\(Set(fixture.logURLs).count) distinct log(s) from \(fixture.logURLs.count) writer(s)",
              expected: "\(fixture.table.segments.count) segment(s)")

        // Not just the count: the NAMES have to pair with the media, or a
        // reader holding a segment table cannot find its log. Two logs and two
        // segments is satisfied by two logs for one segment.
        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: fixture.packageURL.appending(path: "observations").path)
            .sorted()
        check(onDisk == fixture.table.segments.map { ObservationWriter.logFilename(forSegment: $0.index) },
              "each log is named for the segment it belongs to, in index order",
              actual: "\(onDisk)")

        // **This check used to be unfalsifiable and shipped that way.** It
        // switched exhaustively over `SegmentBoundary` and answered `true` in
        // every case — `endedBy` is non-optional, so it is always some case,
        // and the check could not fail for any input. "Silence is not a value"
        // is enforced by the type, not by a runtime assertion, and a runtime
        // assertion restating a type's guarantee reads like evidence and is
        // not. What IS falsifiable is that each boundary is the RIGHT one, and
        // that it reached the trailer on disk.
        check(fixture.table.segments.map(\.endedBy)
                == [.paused, .displayReconfigured(newRevision: fixture.table.segments[2].revision),
                    .stopped],
              "each segment carries the specific boundary the ledger closed it with, in order — "
              + "a pause, a reconfiguration naming the new revision, and a stop",
              actual: "\(fixture.table.segments.map(\.endedBy))")

        // **Everything below counts what it examined and requires it non-zero.**
        // The first version of this block initialised two booleans to `true`
        // and only ever assigned them inside a loop body that a
        // `guard let header, let trailer … else { continue }` skipped — so
        // moving the header write from `open` to `close` (a plausible refactor,
        // and one the writer's own comment argues against, which is exactly why
        // someone might try it) made every `log.header` nil, every iteration
        // `continue`, and both checks pass having looked at nothing, one of
        // them printing `actual: all inside`. Presence and correspondence are
        // also separated: they were one boolean, so a failure named the wrong
        // thing.
        var headersPresent = 0
        var trailersPresent = 0
        var headersMatching = 0
        var trailersMatching = 0
        var instantsExamined = 0
        var outside: [String] = []
        for (index, url) in fixture.logURLs.enumerated() {
            let segment = fixture.table.segments[index]
            let log = try readLog(at: url)
            if let header = log.header {
                headersPresent += 1
                if header.segmentIndex == segment.index
                    && header.mediaFilename == segment.mediaFilename
                    && header.revision == segment.revision {
                    headersMatching += 1
                }
            }
            if let trailer = log.trailer {
                trailersPresent += 1
                if trailer.segmentIndex == segment.index
                    && trailer.hostRange == segment.hostRange
                    && trailer.endedBy == segment.endedBy {
                    trailersMatching += 1
                }
            }
            for line in log.lines {
                for instant in try instants(inRecordOfKind: line.kind, bytes: line.bytes) {
                    instantsExamined += 1
                    if !segment.hostRange.contains(instant) {
                        outside.append("\(line.kind) at \(instant.hostTime.rawValue)")
                    }
                }
            }
        }
        let segmentCount = fixture.table.segments.count
        check(headersPresent == segmentCount,
              "every log HAS a header — counted, so a writer that stopped writing one fails here "
              + "rather than making every check below examine nothing",
              actual: "\(headersPresent)", expected: "\(segmentCount)")
        check(trailersPresent == segmentCount,
              "every log HAS a trailer — separately from whether its fields match, which was one "
              + "boolean and so named the wrong fault",
              actual: "\(trailersPresent)", expected: "\(segmentCount)")
        check(headersMatching == segmentCount,
              "every log's header names the segment, the media file and the revision it belongs to",
              actual: "\(headersMatching) of \(headersPresent) headers read",
              expected: "\(segmentCount)")
        check(trailersMatching == segmentCount,
              "every trailer's segment index, host range and boundary reason are the segment's "
              + "own — a log that cannot be joined back to its segment is a log about nothing",
              actual: "\(trailersMatching) of \(trailersPresent) trailers read",
              expected: "\(segmentCount)")
        check(instantsExamined > 0,
              "instants were actually examined — without this the containment check below passes "
              + "over an empty set and prints `all inside`",
              actual: "\(instantsExamined)")
        check(outside.isEmpty,
              "every record's instant lies inside its segment's host range",
              actual: outside.isEmpty ? "all \(instantsExamined) inside" : "\(outside.prefix(5))")

        // The `.window`-source caveat, made explicit rather than assumed: the
        // fixture's pointer samples carry the segment's revision because a
        // DISPLAY source normalises against the same display. A window source
        // mints its own revision and these would differ — which is why nothing
        // above asserts equality of a record's revision and the header's.
        let firstLog = try readLog(at: fixture.logURLs[0])
        check(firstLog.header?.blindness == [],
              "a header with everything granted records an EMPTY blindness list, not an absent one "
              + "— an absent one would not decode, which is the third state",
              actual: "\(String(describing: firstLog.header?.blindness))")

        // The SAME anchor, index, media name and revision as the log's own
        // header — only `blindness` differs. Built from `firstLog.header`'s own
        // fields rather than from fresh ones, because a second
        // `Minting.epochAnchor()` would differ in `hostTime` and make this
        // comparison true whatever `blindness` did.
        if let granted = firstLog.header {
            let blindHeader = ObservationLogHeader(anchor: granted.anchor,
                                                   segmentIndex: granted.segmentIndex,
                                                   mediaFilename: granted.mediaFilename,
                                                   revision: granted.revision,
                                                   blindness: [.inputMonitoringUnavailable])
            let sameHeader = ObservationLogHeader(anchor: granted.anchor,
                                                  segmentIndex: granted.segmentIndex,
                                                  mediaFilename: granted.mediaFilename,
                                                  revision: granted.revision,
                                                  blindness: granted.blindness)
            check(sameHeader == granted,
                  "the control: a header rebuilt from the log's own fields equals it, so the "
                  + "inequality below is about `blindness` and not about a field that differs "
                  + "for an unrelated reason")
            check(blindHeader != granted,
                  "a segment recorded with Input Monitoring denied does not encode identically to "
                  + "one recorded with it granted — the whole reason "
                  + "CaptureError.inputMonitoringUnavailable has somewhere to go")
        } else {
            check(false, "the fixture log has a header to compare blindness against")
        }
        check(CaptureError.inputMonitoringUnavailable.blindness == .inputMonitoringUnavailable,
              "CaptureError maps to the header field, in one place")
        check(CaptureError.alreadyObserving.blindness == nil,
              "a programming error in this app's own state machine is NOT recorded as blindness — "
              + "it would put a bug in the field a reader uses to judge a user's permissions")
    }

    @MainActor
    static func theLogRefusesARecordFromAnotherBootSession() throws {
        let fm = FileManager.default
        let packageURL = fm.temporaryDirectory
            .appending(path: "t11-epoch-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: packageURL) }
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(), mediaFilenames: []),
            to: packageURL)

        let otherEpoch = BootEpoch(id: UUID())
        let revision = GeometryRevision(id: 0xC0FFEE)
        let anchor = Minting.epochAnchor()
        let epoch = anchor.epoch
        let header = ObservationLogHeader(anchor: anchor, segmentIndex: 0,
                                          mediaFilename: "master-00.mov",
                                          revision: revision, blindness: [])
        let writer = try ObservationWriter.open(segment: header, in: packageURL)

        // Positive control first: the writer accepts a record on its own clock.
        // Without it, the refusals below would be satisfied by a writer that
        // refuses everything.
        var acceptedOwnEpoch = true
        do {
            try writer.append(PointerSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(1)),
                                            position: NormalizedPoint(x: 0.5, y: 0.5),
                                            revision: revision))
        } catch { acceptedOwnEpoch = false }
        check(acceptedOwnEpoch,
              "the writer accepts a record stamped with the log's own epoch — the control, without "
              + "which the two refusals below are satisfied by a writer that refuses everything")

        var refusedForeign = false
        do {
            try writer.append(PointerSample(
                instant: HostInstant(epoch: otherEpoch, hostTime: Nanoseconds(2)),
                position: NormalizedPoint(x: 0.5, y: 0.5), revision: revision))
        } catch { refusedForeign = true }
        check(refusedForeign,
              "a record from another boot session is refused at append — the last moment the "
              + "producer that made the mistake is still on the stack")

        // The `AXChainRecord` case: the click is on the log's clock and one
        // element read is not. A guard reading only the primary instant lets
        // this through.
        let straddling = AXChainRecord(
            instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(3)),
            clickPosition: NormalizedPoint(x: 0.3, y: 0.3), clickRevision: revision,
            hitTestGlobalX: 100, hitTestGlobalY: 100,
            hitTestInterval: HostRange(epoch: epoch, start: Nanoseconds(4), duration: Nanoseconds(1)),
            hit: AXElementRecord(role: "AXButton", title: nil, frame: nil,
                                 readInterval: HostRange(epoch: otherEpoch,
                                                         start: Nanoseconds(5),
                                                         duration: Nanoseconds(1))),
            ancestors: [], children: nil, truncation: .reachedRoot,
            axCalls: 4, depthCap: 30, walkBudgetNanos: 35_000_000)
        var refusedStraddling = false
        do { try writer.append(straddling) } catch { refusedStraddling = true }
        check(refusedStraddling,
              "a chain whose element read landed in another boot session is refused too — "
              + "`epochs` reports every interval a record holds, not just its primary instant")

        _ = try writer.close(endedBy: .stopped,
                             hostRange: HostRange(epoch: epoch, start: Nanoseconds(0),
                                                  duration: Nanoseconds(10)),
                             gapWatches: fixtureGapWatches(
                                segment: MasterSegment(index: 0, mediaFilename: "master-00.mov",
                                                       hostRange: HostRange(epoch: epoch,
                                                                            start: Nanoseconds(0),
                                                                            duration: Nanoseconds(10)),
                                                       revision: revision, endedBy: .stopped),
                                chainsAppended: 0))

        // A second `open` for the same segment must refuse: append-only means
        // the file is opened once, and two writers would interleave two
        // segments' records invisibly.
        var refusedSecondOpen = false
        do { _ = try ObservationWriter.open(segment: header, in: packageURL) }
        catch { refusedSecondOpen = true }
        check(refusedSecondOpen,
              "a second open for a segment that already has a log is refused, not appended to")
    }

    @MainActor
    static func aClickAndItsChainShareAnInstant() throws {
        let fixture = try writeFixtureRecording()
        defer { try? FileManager.default.removeItem(at: fixture.packageURL) }

        var pairs = 0
        var mismatched = 0
        var positionsAgree = true
        var containment: [ClickContainment] = []
        var queueHops: [Int64] = []
        for url in fixture.logURLs {
            let log = try readLog(at: url)
            let buttons: [ButtonEvent] = try log.lines.filter { $0.kind == "button" }
                .map { try ObservationLog.decode($0.bytes) }
            let chains: [AXChainRecord] = try log.lines.filter { $0.kind == "axChain" }
                .map { try ObservationLog.decode($0.bytes) }
            for chain in chains {
                guard let button = buttons.first(where: { $0.instant == chain.instant }) else {
                    mismatched += 1
                    continue
                }
                pairs += 1
                if button.position != chain.clickPosition || button.revision != chain.clickRevision {
                    positionsAgree = false
                }
                containment.append(chain.clickContainment)
                if let hop = chain.clickToHitTestStartNanos { queueHops.append(hop) }
            }
        }
        check(pairs == fixture.clickInstants.count && mismatched == 0,
              "every AX chain is joined to a button event at the identical instant — the instant "
              + "IS the join key (D2-1), so an off-by-a-nanosecond copy is an unjoinable record",
              actual: "\(pairs) paired, \(mismatched) unpaired",
              expected: "\(fixture.clickInstants.count) paired, 0 unpaired")
        check(positionsAgree,
              "the chain's copy of the click's position and revision is byte-identical to the "
              + "button event's — stored rather than re-derived so a reader can check the pair")
        check(containment.allSatisfy { $0 == .containsTheClick },
              "the fixture's click falls inside the element the chain recorded, computed from the "
              + "record alone rather than stored by the producer",
              actual: "\(containment)")
        check(queueHops.count == pairs && queueHops.allSatisfy { $0 > 0 },
              "every pair's queue hop is recoverable and positive — the hit-test starts after the "
              + "click, which is the price of keeping AX off the tap callback thread",
              actual: "\(queueHops)")
    }

    @MainActor
    static func theLogSurvivesATruncatedTail() throws {
        let fixture = try writeFixtureRecording()
        defer { try? FileManager.default.removeItem(at: fixture.packageURL) }

        let url = fixture.logURLs[0]
        let before = try readLog(at: url)
        check(before.droppedBytes == 0 && before.bytesScanned > 0,
              "a cleanly closed log drops nothing, and something was read — the pair, because "
              + "`droppedBytes == 0` over `bytesScanned == 0` is no file, not a clean one",
              actual: "dropped \(before.droppedBytes) of \(before.bytesScanned) scanned")

        // A crash mid-write: a partial record, no trailing newline. Appended to
        // the real file rather than to a copy, because the claim is about what
        // `JSONLReader` does to a log this writer produced.
        let partial = Data(#"{"kind":"pointer","instant":{"epoch":{"id":"#.utf8)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: partial)
        try handle.close()

        let after = try readLog(at: url)
        check(after.droppedBytes == partial.count,
              "the truncated tail is dropped and its exact byte count is reported",
              actual: "\(after.droppedBytes)", expected: "\(partial.count)")
        check(after.lines.count == before.lines.count,
              "every complete record before the crash survives it",
              actual: "\(after.lines.count)", expected: "\(before.lines.count)")
        check(after.header != nil && after.trailer != nil,
              "the header and the trailer both survive a tail appended after them")
        check(after.bytesScanned == before.bytesScanned + partial.count,
              "the dropped tail is counted as examined — it WAS looked at, and a `bytesScanned` "
              + "that excluded it would be a second name for `lines`",
              actual: "\(after.bytesScanned)",
              expected: "\(before.bytesScanned + partial.count)")

        // The other half of the crash story: a log with no trailer is a log
        // whose segment never closed, and that must be visible rather than
        // read as an empty recording.
        let fm = FileManager.default
        let orphanPackage = fm.temporaryDirectory
            .appending(path: "t11-crash-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: orphanPackage) }
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(), mediaFilenames: []),
            to: orphanPackage)
        let crashAnchor = Minting.epochAnchor()
        let epoch = crashAnchor.epoch
        let crashed = try ObservationWriter.open(
            segment: ObservationLogHeader(anchor: crashAnchor, segmentIndex: 0,
                                          mediaFilename: "master-00.mov",
                                          revision: GeometryRevision(id: 0xDEAD), blindness: []),
            in: orphanPackage)
        try crashed.append(PointerSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(1)),
                                         position: NormalizedPoint(x: 0.1, y: 0.1),
                                         revision: GeometryRevision(id: 0xDEAD)))
        // No `close()` — the process died.
        let crashedLog = try readLog(at: ObservationWriter.logURL(forSegment: 0, in: orphanPackage))
        check(crashedLog.header != nil && crashedLog.trailer == nil,
              "a log whose process died before the segment closed has a header and NO trailer — "
              + "which is how a reader tells a crashed recording from an empty one",
              actual: "header \(crashedLog.header != nil), trailer \(crashedLog.trailer != nil)")
        check(crashedLog.lines.count == 1,
              "the records written before the crash are all there",
              actual: "\(crashedLog.lines.count)")
    }

    /// **The check that catches a well-meant optimisation later** (D2-7): the
    /// whole pointer track is kept, never thinned. How dense is dense enough is
    /// a property of `cursor-render`'s spring, which will be tuned, and a
    /// thinned track cannot be re-tuned.
    @MainActor
    static func thePointerTrackIsNotThinned() throws {
        let hz = 120
        let fixture = try writeFixtureRecording(pointerHz: hz)
        defer { try? FileManager.default.removeItem(at: fixture.packageURL) }

        var readBack: [Int] = []
        for url in fixture.logURLs {
            readBack.append(try readLog(at: url).lines.filter { $0.kind == "pointer" }.count)
        }
        check(readBack == fixture.pointerCounts,
              "every pointer sample appended comes back out — nothing is dropped between the "
              + "writer and the reader",
              actual: "\(readBack)", expected: "\(fixture.pointerCounts)")

        // Against the segment's own duration and the fixture's own rate — not
        // a hand-typed constant, which is the expectation-table mistake this
        // project has made three times, always with the identity element.
        var everySegmentAtFullRate = true
        var detail: [String] = []
        for (index, segment) in fixture.table.segments.enumerated() {
            let seconds = Double(segment.hostRange.duration.rawValue) / 1e9
            let expected = Int((seconds * Double(hz)).rounded())
            // One sample of slack: the loop stops at the first instant at or
            // past the segment end, so a duration that is not an exact multiple
            // of the step lands one either side.
            if abs(readBack[index] - expected) > 1 { everySegmentAtFullRate = false }
            detail.append("segment \(index): \(readBack[index]) of ~\(expected)")
        }
        check(everySegmentAtFullRate,
              "each segment holds about duration × \(hz) Hz pointer samples — a thinning "
              + "optimisation in the WRITER or the READER shows up here as a fraction of this. "
              + "NOT the observer: this fixture builds PointerSamples by hand from the same rate "
              + "constant the expectation uses, so InputObserver is not in the path and a "
              + "thinning added there would pass this check. That half needs the human step",
              actual: "\(detail)")
        check(readBack.allSatisfy { $0 > 1 },
              "the rate check is not vacuous — every segment really does hold more than one "
              + "sample, so a writer that dropped everything would fail the check above rather "
              + "than satisfy it at zero",
              actual: "\(readBack)")
    }

    @MainActor
    static func zeroIsDistinguishableFromNeverMeasured() throws {
        let fixture = try writeFixtureRecording()
        defer { try? FileManager.default.removeItem(at: fixture.packageURL) }

        let log = try readLog(at: fixture.logURLs[0])
        guard let trailer = log.trailer else {
            check(false, "the fixture log has a trailer to read gap watches from")
            return
        }
        check(Set(trailer.gapWatches.map(\.site)) == Set(GapSite.allCases),
              "every D6a site has a row in the trailer, every time — an absent site reads as "
              + "'no gaps there' and is indistinguishable from 'this version did not look'",
              actual: "\(trailer.gapWatches.map(\.site.rawValue).sorted())")

        // The three states, on one recording.
        // `.axAncestorWalk` is the fixture's one genuinely-watched site: it
        // appended the chains itself. The tap row used to stand here on a
        // fabricated poll count — see `fixtureGapWatches`.
        let watching = trailer.gapWatches.first { $0.site == .axAncestorWalk }
        let notWatching = trailer.gapWatches.first { $0.site == .secureInput }
        check(watching?.gapsFound == 0 && watching?.isAMeasurement == true,
              "a site that was watched and found nothing reports zero gaps AND says something "
              + "was looking",
              actual: "\(String(describing: watching))")
        check(notWatching?.gapsFound == 0 && notWatching?.isAMeasurement == false,
              "a site that nothing watched reports the SAME zero and says nothing was looking — "
              + "the two rows are the distinction Addition A exists for",
              actual: "\(String(describing: notWatching))")
        check(watching?.gapsFound == notWatching?.gapsFound,
              "the two rows above carry the identical gap count, which is exactly why the count "
              + "alone was never a measurement")
        // **Three sites, and all three are honest.** This fixture runs no
        // `CaptureSession`, no secure-input predicate and no `InputObserver`
        // poll. It used to claim the tap row as watched, on a poll count no
        // poll produced; that was the `jsonlTruncatedTail` fabrication
        // surviving one site over, and it is gone.
        check(trailer.sitesNothingWasWatching
                == [.secureInput, .tapDisabled, .videoFramesNotProduced],
              "the trailer names the sites nothing was watching — three of them here, because "
              + "this fixture drives none of those three producers and says so instead of "
              + "inventing a number for them",
              actual: "\(trailer.sitesNothingWasWatching.map(\.rawValue))")
        check(trailer.gapWatches.filter(\.isAMeasurement).map(\.site) == [GapSite.axAncestorWalk],
              "and the complement — the sites something DID watch — is named too, so this is a "
              + "partition of the four rows rather than a one-sided list that an all-zero "
              + "producer would also satisfy. Exactly one here: the fixture appended the chains "
              + "itself, which is the only thing in it that looked at anything",
              actual: "\(trailer.gapWatches.filter(\.isAMeasurement).map(\.site.rawValue))")
        check(trailer.accounting.contains("NOTHING WAS LOOKING"),
              "and the printed form says so where a person will read it")

        // D6a site 4's companion, on the live observer rather than on a
        // fixture: `secureInputChecks` over `secureInputCheckSpanNanos`.
        let arrangement = fixtureArrangementForSecureInputCheck()
        let observer = InputObserver(arrangement: arrangement, epoch: Minting.bootEpoch(),
                                     secureInputIsEnabled: { false })
        check(observer.diagnostics.secureInputChecks == 0,
              "a fresh observer has consulted the secure-input predicate zero times — and that "
              + "zero is now sayable, which is the point",
              actual: "\(observer.diagnostics.secureInputChecks)")
        check(observer.diagnostics.secureInputAccounting.contains("NOTHING WAS LOOKING"),
              "and it says so, rather than reporting zero intervals as a clean result")

        // The record counts: a declared kind with no records, versus a kind
        // this producer does not emit at all.
        check(trailer.recordCounts["key"] == 0,
              "a kind the producer declared and never saw is `0`, not absent",
              actual: "\(String(describing: trailer.recordCounts["key"]))")
        check(trailer.recordCounts["secureInput"] == nil,
              "a kind this producer does not emit has no key at all — a different fact from zero",
              actual: "\(String(describing: trailer.recordCounts["secureInput"]))")
        check(trailer.recordCounts["pointer"] == fixture.pointerCounts[0],
              "and the counts that ARE there match what was appended",
              actual: "\(String(describing: trailer.recordCounts["pointer"]))",
              expected: "\(fixture.pointerCounts[0])")
    }

    /// A single-display arrangement for the secure-input companion check. Built
    /// here rather than reaching for `currentArrangement()`, which reads
    /// ambient AppKit state — § 7.6 is where that is exercised.
    static func fixtureArrangementForSecureInputCheck() -> DisplayArrangement {
        let geometry = DisplayGeometry(displayUUID: UUID(), pixelWidth: 2560, pixelHeight: 1600,
                                       scale: 2)
        return DisplayArrangement(placements: [
            .init(geometry: geometry, globalOriginX: 0, globalOriginY: 0)
        ])
    }

    /// **Phase 1's dead symbols get their first callers, and the difference is
    /// a delete.**
    ///
    /// `CaptureSession` wrote each finished segment through
    /// `ProjectPackageIO.writeSidecar` directly until Task 11. That puts the
    /// file in `media/` and records nothing — so the recording is unreferenced
    /// by the manifest, and the next `compactMedia()` correctly identifies it
    /// as an orphan and deletes it. Both halves are exercised here on one
    /// package, because either alone is satisfied by a `compactMedia` that
    /// deletes nothing.
    @MainActor
    static func mediaRoutedThroughTheDocumentIsReferenced() throws {
        let fm = FileManager.default
        let packageURL = fm.temporaryDirectory
            .appending(path: "t11-media-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: packageURL) }
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(), mediaFilenames: []),
            to: packageURL)

        let document = ProjectDocument()
        document.fileURL = packageURL
        try document.read(from: packageURL, ofType: ProjectDocument.contentTypeIdentifier)

        let routedBytes = Data(repeating: 0x11, count: 4096)
        let aroundBytes = Data(repeating: 0x22, count: 4096)
        // The path this task introduced: through the document, under a name the
        // caller minted (the ledger mints it at `beginSegment`, long before the
        // bytes exist).
        // Called by name, not through the `MediaSink` requirement, so this is a
        // real call site for `ProjectDocument.addMedia` — which `ROADMAP.md`'s
        // `project-format` row names as one of five app-side symbols with zero
        // callers anywhere.
        let routedName = try document.addMedia(routedBytes, named: "master-00.mov")
        check(routedName == "master-00.mov",
              "addMedia returns the name it was given — the caller stores it in whatever "
              + "references the media, and for capture that is already on the SegmentLedger",
              actual: routedName)
        // The path `CaptureSession` used to take.
        try ProjectPackageIO.writeSidecar(aroundBytes, named: "master-01.mov", into: packageURL)

        // And the `MediaSink` requirement itself, which is the shape
        // `CaptureSession.finalizeCurrentSegment` calls: a third file, routed
        // the way the shipping path routes it, to establish that the conformance
        // reaches the same method rather than a second implementation.
        try document.acceptMedia(Data(repeating: 0x33, count: 2048), named: "master-02.mov")
        check(document.snapshot.mediaFilenames == ["master-00.mov", "master-02.mov"],
              "MediaSink.acceptMedia reaches addMedia — the conformance is a route, not a "
              + "second implementation that could drift",
              actual: "\(document.snapshot.mediaFilenames)")

        check(!document.snapshot.mediaFilenames.contains("master-01.mov"),
              "media routed through the document is referenced by the manifest; media written "
              + "around it is not",
              actual: "\(document.snapshot.mediaFilenames)")
        check(document.isDocumentEdited,
              "and the document is marked dirty, without which closing it takes the "
              + "no-unsaved-changes path and the reference is lost before it is ever saved")

        let orphans = try document.unreferencedMedia()
        check(orphans == ["master-01.mov"],
              "unreferencedMedia names exactly the sidecar that went around the document",
              actual: "\(orphans)")

        let deleted = try document.compactMedia()
        check(deleted == ["master-01.mov"],
              "compactMedia deletes it — which is what made the old path a defect with a delete "
              + "at the end of it rather than untidiness",
              actual: "\(deleted)")
        check(fm.fileExists(atPath: packageURL.appending(path: "media/master-00.mov").path),
              "the routed recording survives the same compaction")
        check(!fm.fileExists(atPath: packageURL.appending(path: "media/master-01.mov").path),
              "the unrouted one does not")
        // Guarded because an unguarded read traps, and a probe that dies
        // mid-section prints no verdict for the checks below it.
        //
        // The guard used to name its mutation — "under the mutation that
        // reverts `acceptMedia` to a bare `writeSidecar`, compaction has
        // already deleted this file" — and that was measured false during the
        // Task 12 red-certificate sampling. `master-00.mov` goes through
        // `addMedia` directly, three lines up; `acceptMedia` writes
        // `master-02.mov`. Under exactly the named mutation this file survives
        // and this check stays green, while three others redden. The mutation
        // that reddens THIS check is one that corrupts what `addMedia` writes
        // (`writeSidecar(data.dropLast(), …)` was used), which is the claim it
        // actually makes: the bytes stored are the bytes handed over.
        let survivorBytes = try? Data(contentsOf: packageURL.appending(path: "media/master-00.mov"))
        check(survivorBytes == routedBytes,
              "and its bytes are the ones that were handed over",
              actual: survivorBytes == nil ? "the file is gone" : "\(survivorBytes!.count) bytes")
    }

    // MARK: - § 9.8  a real crash

    /// The child. Opens a log in `packagePath` and appends until it is killed.
    ///
    /// Prints one line and flushes as soon as the log exists, so the parent
    /// waits for a fact rather than for a duration — a `sleep` here would make
    /// the test flaky on a loaded machine in the direction that passes.
    @MainActor
    static func appendUntilKilled(packagePath: String) throws -> Never {
        let packageURL = URL(filePath: packagePath, directoryHint: .isDirectory)
        let anchor = Minting.epochAnchor()
        let revision = GeometryRevision(id: 0x5150)
        let writer = try ObservationWriter.open(
            segment: ObservationLogHeader(anchor: anchor, segmentIndex: 0,
                                          mediaFilename: "master-00.mov",
                                          revision: revision, blindness: []),
            in: packageURL)
        var n: Int64 = 0
        while true {
            try writer.append(PointerSample(
                instant: HostInstant(epoch: anchor.epoch, hostTime: Nanoseconds(n)),
                position: NormalizedPoint(x: 0.5, y: 0.5), revision: revision))
            n += 1
            if n == 200 { print("READY"); fflush(stdout) }
        }
    }

    /// **§ 7.4 of the Task 11 report claimed a process crash costs the tail
    /// rather than the segment. § 9.4 tested the reader's half of that by
    /// appending a partial line by hand. This tests the writer's half, by
    /// actually killing one.**
    ///
    /// `SIGKILL`, not `SIGTERM`: the claim is that nothing in this app's own
    /// shutdown path is load-bearing for the log's readability, and a signal
    /// the process can handle would let a handler quietly do the work the
    /// design says is unnecessary.
    @MainActor
    static func aKilledWriterLosesOnlyItsTail() throws {
        let fm = FileManager.default
        let packageURL = fm.temporaryDirectory
            .appending(path: "t11-kill-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: packageURL) }
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(), mediaFilenames: []),
            to: packageURL)

        guard let executable = Bundle.main.executableURL ?? CommandLine.arguments.first
            .map({ URL(filePath: $0) }) else {
            check(false, "the probe can locate its own executable to re-launch as the crash child")
            return
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--append-until-killed", packageURL.path(percentEncoded: false)]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        try child.run()

        // Wait for the child's own "READY", not for a duration.
        var sawReady = false
        var seen = Data()
        while child.isRunning, !sawReady {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            seen.append(chunk)
            sawReady = String(decoding: seen, as: UTF8.self).contains("READY")
        }
        check(sawReady,
              "the child reached a state where records are on disk — without this the kill below "
              + "could land before the first byte and the whole check would be about an empty file")
        guard sawReady else { child.terminate(); return }

        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        check(child.terminationReason == .uncaughtSignal,
              "the child died of an uncaught signal, not of its own accord — a child that exited "
              + "normally would have run shutdown code the design says is not load-bearing",
              actual: "\(child.terminationReason.rawValue)")

        let url = ObservationWriter.logURL(forSegment: 0, in: packageURL)
        let report = try ObservationLogReadReport.read(logAt: url)
        check(report.header != nil,
              "the header written at open survives the kill — which is why it is written at open")
        check(report.recordLines >= 200,
              "every record the child completed before the kill is readable — the tail is what a "
              + "crash costs, not the segment",
              actual: "\(report.recordLines) record line(s)", expected: "at least 200")
        check(!report.closedCleanly,
              "and there is no trailer, so a reader knows the producer died rather than reading "
              + "this as a recording that simply ended")
        // **No bound is asserted on the tail, and that is a retraction.** This
        // check used to be `droppedBytes <= 512`, which `0` satisfies — and `0`
        // is the overwhelmingly likely outcome, because a ~150-byte `write(2)`
        // to a regular file is not interrupted by a signal, so the kill lands
        // *between* writes almost every time. The case the check was named for
        // has probably never run here, and a bound that cannot fail is a claim
        // with nothing behind it.
        //
        // What replaces it is falsifiable: the reader examined every byte the
        // file actually holds. A torn write during `write(2)` remains
        // unproven; see the report for what proving it would take.
        let sizeOnDisk = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int
        check(sizeOnDisk != nil && report.bytesScanned == sizeOnDisk,
              "the reader examined every byte the killed writer left on disk — so the dropped "
              + "count below is over the whole file and not over part of it",
              actual: "scanned \(report.bytesScanned), file is "
                      + (sizeOnDisk.map(String.init) ?? "unreadable"))
        check(report.isAMeasurement,
              "and something was actually read, so `droppedBytes` is a measurement. Observed "
              + "here: \(report.droppedBytes) byte(s) dropped — NOT asserted against a bound, "
              + "because the kill lands between writes rather than inside one and the torn-write "
              + "case is not exercised",
              actual: "\(report.droppedBytes) dropped of \(report.bytesScanned) scanned")

        // Every surviving record decodes. A tail that damaged an EARLIER line
        // would show up here and nowhere else.
        var decoded = 0
        for line in try JSONLReader.linesOfFile(at: url).lines
        where (try? ObservationLog.kind(of: line)) == "pointer" {
            _ = try ObservationLog.decode(line) as PointerSample
            decoded += 1
        }
        check(decoded == report.recordLines,
              "every surviving record decodes — a crash that damaged a line other than the last "
              + "would appear here",
              actual: "\(decoded)", expected: "\(report.recordLines)")
    }

    // MARK: - § 9.9  concurrent appends

    /// **The check that would have caught the `close`/`append` race.**
    ///
    /// The intended load is exactly this: `InputObserver`'s tap callback thread
    /// and `AXObserver`'s queue both calling `append`, with `close` arriving on
    /// a third. Before review, `close` snapshotted `recordCounts` under the
    /// lock, released it, encoded the trailer, then took the lock again to
    /// write — so an `append` in that gap landed before the trailer and was
    /// missing from its counts, and the trailer reported loss that had not
    /// happened.
    @MainActor
    static func concurrentAppendsAreNotLost() throws {
        let fm = FileManager.default
        let packageURL = fm.temporaryDirectory
            .appending(path: "t11-race-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: packageURL) }
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(), mediaFilenames: []),
            to: packageURL)

        let threads = 8
        let perThread = 500
        let anchor = Minting.epochAnchor()
        let revision = GeometryRevision(id: 0xC0DE)
        let writer = try ObservationWriter.open(
            segment: ObservationLogHeader(anchor: anchor, segmentIndex: 0,
                                          mediaFilename: "master-00.mov",
                                          revision: revision, blindness: []),
            in: packageURL)

        nonisolated(unsafe) let sharedWriter = writer
        // Hopped out of the main actor deliberately. `concurrentPerform`'s
        // closure parameter is not `Sendable`, so under this target's
        // `-default-isolation MainActor` the closure below would inherit main
        // actor isolation and running it on a worker thread traps — which is
        // exactly the fault this check exists to catch one layer down, and it
        // would be indistinguishable from it if the probe made the same mistake.
        // A tiny counter of its own rather than `Synchronization.Mutex`: this
        // probe is a standalone file compiled without that module, and the
        // point of the box is only that the failure count survives eight
        // concurrent writers.
        final class FailureCount: @unchecked Sendable {
            private nonisolated let lock = NSLock()
            private nonisolated(unsafe) var value = 0
            nonisolated func increment() { lock.withLock { value += 1 } }
            nonisolated var count: Int { lock.withLock { value } }
        }
        let failures = FailureCount()
        let appendBatch: @Sendable (Int) -> Void = { thread in
            for i in 0..<perThread {
                let n = Int64(thread * perThread + i)
                do {
                    try sharedWriter.append(PointerSample(
                        instant: HostInstant(epoch: anchor.epoch, hostTime: Nanoseconds(n)),
                        position: NormalizedPoint(x: 0.25, y: 0.75), revision: revision))
                } catch {
                    failures.increment()
                }
            }
        }
        DispatchQueue.concurrentPerform(iterations: threads, execute: appendBatch)
        check(failures.count == 0,
              "no append failed under \(threads) concurrent writers",
              actual: "\(failures.count) failure(s)")

        let expected = threads * perThread
        _ = try writer.close(endedBy: .stopped,
                             hostRange: HostRange(epoch: anchor.epoch, start: Nanoseconds(0),
                                                  duration: Nanoseconds(Int64(expected))),
                             gapWatches: fixtureGapWatches(
                                segment: MasterSegment(index: 0, mediaFilename: "master-00.mov",
                                                       hostRange: HostRange(epoch: anchor.epoch,
                                                                            start: Nanoseconds(0),
                                                                            duration: Nanoseconds(Int64(expected))),
                                                       revision: revision, endedBy: .stopped),
                                chainsAppended: 0))

        let report = try ObservationLogReadReport.read(logAt:
            ObservationWriter.logURL(forSegment: 0, in: packageURL))
        check(report.recordLines == expected,
              "\(threads) × \(perThread) concurrent appends produce exactly that many record "
              + "lines — no interleaved write tore another one",
              actual: "\(report.recordLines)", expected: "\(expected)")
        check(report.droppedBytes == 0,
              "and no line was left partial",
              actual: "\(report.droppedBytes)")

        var decoded = 0
        var distinct = Set<Int64>()
        for line in try JSONLReader.linesOfFile(at:
            ObservationWriter.logURL(forSegment: 0, in: packageURL)).lines
        where (try? ObservationLog.kind(of: line)) == "pointer" {
            let sample = try ObservationLog.decode(line) as PointerSample
            distinct.insert(sample.instant.hostTime.rawValue)
            decoded += 1
        }
        check(decoded == expected && distinct.count == expected,
              "every one of them decodes, and every one is a DIFFERENT sample — a count alone is "
              + "satisfied by the same record written twice while another was lost",
              actual: "\(decoded) decoded, \(distinct.count) distinct", expected: "\(expected)")

        // **The race the review found, stated as the check that catches it.**
        check(report.trailer?.recordCounts["pointer"] == expected,
              "the trailer's count equals the record lines on disk. An append landing between a "
              + "count snapshot and the trailer write is a trailer that reports loss which did "
              + "not happen, in the field a reader trusts to find real loss",
              actual: "\(String(describing: report.trailer?.recordCounts["pointer"]))",
              expected: "\(expected)")
        check(report.trailerCount == 1,
              "exactly ONE trailer was written — `trailer != nil` is satisfied by two, because a "
              + "reader keeps the last one it sees, and two concurrent closes produce exactly "
              + "that",
              actual: "\(report.trailerCount)", expected: "1")
        check(report.trailerIsLastCompleteLine,
              "and it is the last complete line — without which 'a missing trailer is the crash "
              + "signal' says nothing, since a record after the trailer means the log kept "
              + "growing after the segment closed")
        check(report.closedCleanly && report.closeFault == nil,
              "so the log closed cleanly, by all three clauses rather than by the first",
              actual: report.closeFault ?? "clean")

        // ---- the same law, with `close` arriving WHILE appends are in flight
        //
        // The block above settles every append before closing, so it cannot
        // reach the gap the two-lock `close` had. This one closes mid-flight.
        // Under one critical section an append either completes before the
        // trailer — and is therefore counted in it — or is refused; there is no
        // third outcome, and "landed before the trailer, missing from its
        // counts" was the third outcome.
        let racePackage = fm.temporaryDirectory
            .appending(path: "t11-close-race-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: racePackage) }
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(), mediaFilenames: []),
            to: racePackage)
        let raceAnchor = Minting.epochAnchor()
        let raceWriter = try ObservationWriter.open(
            segment: ObservationLogHeader(anchor: raceAnchor, segmentIndex: 0,
                                          mediaFilename: "master-00.mov",
                                          revision: revision, blindness: []),
            in: racePackage)
        nonisolated(unsafe) let sharedRaceWriter = raceWriter
        let accepted = FailureCount()
        let refused = FailureCount()
        let inFlight: @Sendable (Int) -> Void = { thread in
            for i in 0..<perThread {
                let n = Int64(thread * perThread + i)
                do {
                    try sharedRaceWriter.append(PointerSample(
                        instant: HostInstant(epoch: raceAnchor.epoch, hostTime: Nanoseconds(n)),
                        position: NormalizedPoint(x: 0.25, y: 0.75), revision: revision))
                    accepted.increment()
                } catch {
                    refused.increment()
                }
            }
        }
        let racingQueue = DispatchQueue(label: "t11-close-race", attributes: .concurrent)
        let group = DispatchGroup()
        for thread in 0..<threads { racingQueue.async(group: group) { inFlight(thread) } }
        // Close while they are still going. The wait is a floor on how much
        // work is in flight, not a timing assumption: the checks below hold
        // whether the close lands after two appends or after two thousand.
        _ = group.wait(timeout: .now() + 0.004)
        let raceRange = HostRange(epoch: raceAnchor.epoch, start: Nanoseconds(0),
                                  duration: Nanoseconds(Int64(expected)))
        _ = try raceWriter.close(endedBy: .stopped, hostRange: raceRange,
                                 gapWatches: fixtureGapWatches(
                                    segment: MasterSegment(index: 0, mediaFilename: "master-00.mov",
                                                           hostRange: raceRange, revision: revision,
                                                           endedBy: .stopped),
                                    chainsAppended: 0))
        group.wait()

        let raceReport = try ObservationLogReadReport.read(logAt:
            ObservationWriter.logURL(forSegment: 0, in: racePackage))
        check(refused.count > 0 && accepted.count > 0,
              "the close really did land mid-flight — some appends were accepted and some refused. "
              + "Without both, this block measures the settled case again and the law below holds "
              + "for the wrong reason",
              actual: "\(accepted.count) accepted, \(refused.count) refused")
        check(raceReport.trailer?.recordCounts["pointer"] == raceReport.recordLines,
              "the trailer's count equals the record lines on disk even when close arrives "
              + "mid-flight — measured against the two-lock version, which reported 279 for 295 "
              + "lines: sixteen appends landed before the trailer and were missing from its counts",
              actual: "trailer \(String(describing: raceReport.trailer?.recordCounts["pointer"])) "
                      + "vs \(raceReport.recordLines) on disk")
        check(raceReport.recordLines == accepted.count,
              "and every append the writer ACCEPTED is on disk — a refusal is a refusal, not a "
              + "silent drop",
              actual: "\(raceReport.recordLines) on disk, \(accepted.count) accepted")
        check(raceReport.droppedBytes == 0,
              "no line was torn by the close",
              actual: "\(raceReport.droppedBytes)")
        check(raceReport.trailerCount == 1 && raceReport.trailerIsLastCompleteLine,
              "and the trailer is still the last line, and the only one, with appends arriving "
              + "either side of the close — an append that lands AFTER the trailer means the log "
              + "kept growing after the segment closed, which is the other half of what "
              + "`closedCleanly` used not to check",
              actual: raceReport.closeFault ?? "one trailer, last")
    }

    // MARK: - § 9.10  the join field, dangling

    /// `ObservationLogHeader.mediaFilename` is how a log found on its own says
    /// which recording it describes. A segment whose media was discarded or
    /// compacted away leaves the log behind pointing at a file that is gone.
    @MainActor
    static func aDanglingObservationLogIsReported() throws {
        let fm = FileManager.default
        let packageURL = fm.temporaryDirectory
            .appending(path: "t11-dangle-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: packageURL) }
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(), mediaFilenames: []),
            to: packageURL)

        let anchor = Minting.epochAnchor()
        let revision = GeometryRevision(id: 0xDA46)
        for index in 0...1 {
            let writer = try ObservationWriter.open(
                segment: ObservationLogHeader(anchor: anchor, segmentIndex: index,
                                              mediaFilename: "master-0\(index).mov",
                                              revision: revision, blindness: []),
                in: packageURL)
            let range = HostRange(epoch: anchor.epoch, start: Nanoseconds(0),
                                  duration: Nanoseconds(1))
            _ = try writer.close(endedBy: .stopped, hostRange: range,
                                 gapWatches: fixtureGapWatches(
                                    segment: MasterSegment(index: index,
                                                           mediaFilename: "master-0\(index).mov",
                                                           hostRange: range, revision: revision,
                                                           endedBy: .stopped),
                                    chainsAppended: 0))
        }

        // Only segment 0's media reached the package — segment 1's writer
        // failed, which is `CaptureSession.Diagnostics.discardedSegments`.
        let snapshot = ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                                       geometries: GeometryRegistry(),
                                       mediaFilenames: ["master-00.mov"])
        let dangling = try ProjectPackageIO.danglingObservationLogs(in: packageURL,
                                                                   snapshot: snapshot)
        check(dangling == ["segment-01.jsonl"],
              "a log whose header names media the manifest does not reference is reported — a "
              + "dangling key in the format's own join field, which nothing else in the package "
              + "would notice",
              actual: "\(dangling)")

        // Reported, never deleted: `compact`'s contract is that it removes
        // exactly what `unreferencedSidecars` names and nothing else, and a
        // compaction that quietly grew a second kind of delete is the failure
        // D-P3 exists to prevent, by a different door.
        _ = try ProjectPackageIO.compact(packageURL, snapshot: snapshot)
        check(fm.fileExists(atPath: ObservationWriter.logURL(forSegment: 1, in: packageURL).path),
              "compact does not delete it — reporting and deleting are separate, as they are for "
              + "media")

        let clean = ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                                    geometries: GeometryRegistry(),
                                    mediaFilenames: ["master-00.mov", "master-01.mov"])
        check(try ProjectPackageIO.danglingObservationLogs(in: packageURL, snapshot: clean) == [],
              "and a package whose manifest references both reports none — the control, without "
              + "which the check above is satisfied by a function that reports everything")
    }

    // MARK: - § 10  FrameRendering — the compositor seam (Phase 2B Task 3)

    /// `Tests/AppSourceTests` cannot import the app target, so it cannot instantiate
    /// `CoreImageFrameRenderer` or drive it against a real `CVPixelBuffer` — that is what this probe
    /// exists for. `RenderSeamTests.swift` already proves `FrameRenderer.swift` names neither Core
    /// Image nor Metal; this proves the implementation BEHIND the seam actually draws.
    enum FrameRenderProbeError: Error { case pixelBufferCreateFailed(CVReturn) }

    /// A `width` × `height` BGRA `CVPixelBuffer`, every pixel set to the same colour — byte-exact,
    /// so § 10.1 can assert on the exact channel values a solid-red SOURCE frame produces, not on
    /// "looks red".
    @MainActor
    static func makeSolidPixelBuffer(width: Int, height: Int,
                                     r: UInt8, g: UInt8, b: UInt8) throws -> CVPixelBuffer {
        var raw: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &raw)
        guard status == kCVReturnSuccess, let buffer = raw else {
            throw FrameRenderProbeError.pixelBufferCreateFailed(status)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw FrameRenderProbeError.pixelBufferCreateFailed(status)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bgra: [UInt8] = [b, g, r, 255]
        for row in 0..<height {
            let rowBase = base.advanced(by: row * bytesPerRow)
            for column in 0..<width {
                rowBase.advanced(by: column * 4).copyMemory(from: bgra, byteCount: 4)
            }
        }
        return buffer
    }

    /// One BGRA pixel, read at a point given in `StageRect`'s own coordinate space — OUTPUT
    /// PIXELS, bottom-left origin (`RenderPlan.swift`'s header) — and converted to
    /// `CVPixelBuffer`'s memory layout, which is top-down (row 0 = the top of the image).
    ///
    /// **Measured, not assumed:** a throwaway fixture rendered a red rectangle covering Core
    /// Image y ∈ [0, 20) — near the BOTTOM of Core Image's bottom-left-origin space — into a
    /// `CVPixelBuffer` over a green background, then read raw bytes at buffer row 0 and row
    /// `height - 1`. Row 0 (the first bytes in memory) came back green; row `height - 1` came
    /// back red. So a small `y` in `StageRect`'s space lands at a LARGE row index in the
    /// buffer's memory, which is exactly `row = height - 1 - y` below — this is that
    /// measurement, not the untested "obviously bottom-left flips" guess.
    @MainActor
    static func pixel(in buffer: CVPixelBuffer, atStageX x: Int, y: Int, outputHeight: Int)
        -> (r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = outputHeight - 1 - y
        let pointer = base.advanced(by: row * bytesPerRow + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        // BGRA in memory.
        return (r: Int(pointer[2]), g: Int(pointer[1]), b: Int(pointer[0]))
    }

    /// Renders one `RenderPlan` through the real `CoreImageFrameRenderer` and samples three
    /// points chosen so each isolates one thing the compositor must get right:
    ///
    ///   * the CENTRE of the card — deep inside the rounded rect and far from any edge — must be
    ///     the SOURCE frame's colour, or the card was never drawn at all.
    ///   * a point in the INSET MARGIN, outside the card's bounding box entirely, must be the
    ///     background colour, or the card was drawn oversized (or the background never drawn).
    ///   * a point INSIDE the card's bounding box but in its extreme corner — `(card.x + 2,
    ///     card.y + 2)`, at Euclidean distance ≈ 31 from the rounded rect's corner arc centre
    ///     while `cornerRadius` is 24 — must ALSO be the background colour, or the corners were
    ///     drawn square rather than rounded.
    ///
    /// `style: .default` deliberately: its background is `.solid(red: 0.09, green: 0.09, blue:
    /// 0.11)`, which is `(23, 23, 28)` at 8-bit precision — the exact triple this check asserts —
    /// so this drives the real default a caller would use, not a color chosen to make the test
    /// pass.
    @MainActor
    static func theCompositorDrawsACardOverABackground() throws {
        let outputWidth = 320
        let outputHeight = 180
        let card = StageRect(x: 40, y: 30, width: 240, height: 120)
        let plan = RenderPlan(outputWidth: outputWidth, outputHeight: outputHeight,
                              card: card, cornerRadius: 24, style: .default, pointer: nil)

        // The source frame: solid red, a different size from the card, so the renderer's own
        // scale-to-fit is what makes the card's centre red — not a coincidence of matching sizes.
        let source = try makeSolidPixelBuffer(width: 64, height: 64, r: 255, g: 0, b: 0)
        let destination = try makeSolidPixelBuffer(width: outputWidth, height: outputHeight,
                                                    r: 0, g: 0, b: 0)

        let renderer = try CoreImageFrameRenderer()
        try renderer.render(plan, source: source, into: destination)

        let centrePixel = pixel(in: destination, atStageX: 160, y: 90, outputHeight: outputHeight)
        let marginPixel = pixel(in: destination, atStageX: 10, y: 10, outputHeight: outputHeight)
        let cardCornerPixel = pixel(in: destination, atStageX: 42, y: 32, outputHeight: outputHeight)

        // the centre of the card is the source colour
        check(centrePixel == (r: 255, g: 0, b: 0), "the card shows the source frame's pixels",
              actual: "\(centrePixel)")
        // a pixel in the inset margin is the background colour, not the source
        check(marginPixel == (r: 23, g: 23, b: 28), "outside the card is the background",
              actual: "\(marginPixel)")
        // the extreme corner of the card is background — the radius cut it
        check(cardCornerPixel == (r: 23, g: 23, b: 28), "the corner radius removed the card's corner",
              actual: "\(cardCornerPixel)")
    }

    // MARK: - § 11  CompositionBuilder — the real AVVideoComposition, end to end (Phase 2B Task 4)

    /// § 10 drives `CoreImageFrameRenderer` directly against a hand-built `RenderPlan` and a bare
    /// `CVPixelBuffer` pair — real, but it never proves `CompositionBuilder`, `StageCompositor`, or
    /// the `AVVideoComposition`/`AVAssetWriter`/`AVAssetImageGenerator` wiring between them, which
    /// is everything `StageWindow.load()` actually does. **Nobody has eyes on the app window this
    /// task adds** (`Soredemo/UI/StageWindow.swift`), so this is the only mechanical check of that
    /// wiring: it builds a real source movie, builds the real composition through
    /// `CompositionBuilder.composition(for:outputWidth:outputHeight:frameDuration:)`, applies it to
    /// the source through the real `StageCompositor` (`AVVideoComposition.customVideoCompositorClass`,
    /// not a stand-in), and reads a composed frame back with `AVAssetImageGenerator` — which is
    /// what makes `videoComposition` apply at all; `AVAssetImageGenerator.image(at:)` on a plain
    /// `AVURLAsset` with no `videoComposition` set would read the SOURCE movie's own pixels and this
    /// check would still pass for the wrong reason.
    enum CompositionProbeError: Error {
        case pixelBufferPoolUnavailable
        case cgContextUnavailable
        case writerFailed(String)
    }

    /// Writes a short, solid-colour movie to `url` — two frames of `width`×`height` BGRA, byte-exact
    /// like § 10's `makeSolidPixelBuffer`, through a real `AVAssetWriter`/
    /// `AVAssetWriterInputPixelBufferAdaptor` pair. Two frames, not one, so the track has a real
    /// (non-zero) duration for `CompositionBuilder`'s `CMTimeRange` to cover — a single zero-duration
    /// sample left `AVAssetImageGenerator.image(at:)` with no frame to find.
    ///
    /// **`AVVideoColorPropertiesKey` pinned to ITU_R_709_2 — measured, not the brief's concern (the
    /// brief says nothing about this file at all).** The first version of this function wrote no
    /// colour tag, and reading a pure red (255, 0, 0) source back — with `videoComposition` UNSET,
    /// bypassing the compositor entirely, to isolate the write/read round trip from anything this
    /// task's own code does — measured `(231, 33, 0)`: a real colour shift from ambiguous tagging, the
    /// same class of defect `CaptureSession`'s own header (D2-15) already warns about for the capture
    /// side. Pinning the same three keys `CaptureSession.beginSegment` pins for its `AVVideoSettings`
    /// made the round trip exact — measured at `(255, 0, 0)` afterwards, over five consecutive runs.
    @MainActor
    static func writeSolidColorMovie(to url: URL, width: Int, height: Int,
                                     r: UInt8, g: UInt8, b: UInt8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                            sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else {
            throw CompositionProbeError.writerFailed("canAdd(_:) refused the video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw CompositionProbeError.writerFailed(
                "startWriting() returned false: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw CompositionProbeError.pixelBufferPoolUnavailable
        }
        let frameDuration = CMTime(value: 1, timescale: 30)
        let bgra: [UInt8] = [b, g, r, 255]
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var raw: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &raw)
            guard let buffer = raw else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                let rowBase = base.advanced(by: row * bytesPerRow)
                for column in 0..<width {
                    rowBase.advanced(by: column * 4).copyMemory(from: bgra, byteCount: 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw CompositionProbeError.writerFailed("append(_:withPresentationTime:) returned false")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CompositionProbeError.writerFailed(
                "writer finished with status \(writer.status.rawValue), error \(String(describing: writer.error))")
        }
    }

    /// One RGB pixel out of a `CGImage`, at a point given in `StageRect`'s own coordinate space —
    /// OUTPUT PIXELS, bottom-left origin, exactly like § 10's `pixel(in buffer:atStageX:y:
    /// outputHeight:)` — via a fresh `CGContext` redraw into a raw RGBA buffer.
    ///
    /// **The row convention was measured again here, not assumed to carry over from § 10's
    /// `CVPixelBuffer` measurement**, because this is a different boundary: `CVPixelBuffer` →
    /// `CGImage` (AVFoundation's own conversion) → this function's own `CGContext.draw(_:in:)`
    /// redraw. A throwaway fixture built a 4×4 `CVPixelBuffer` with memory rows 0–1 red and rows
    /// 2–3 green (the already-established § 10 convention: row 0 = top), converted it to a
    /// `CGImage` via `CIContext.createCGImage` — the same conversion `AVAssetImageGenerator`
    /// performs internally — then redrew that `CGImage` into a raw buffer the way this function
    /// does and read its rows directly: rows 0–1 came back red, rows 2–3 green. So `CGContext
    /// .draw(_:in:)` into a buffer built this way preserves the SAME top-down convention § 10
    /// already established for `CVPixelBuffer` — the same `row = outputHeight - 1 - y` formula
    /// applies unchanged.
    @MainActor
    static func pixel(in image: CGImage, x: Int, y: Int, outputHeight: Int) throws -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &data, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CompositionProbeError.cgContextUnavailable
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let row = outputHeight - 1 - y
        let offset = (row * image.width + x) * 4
        return (r: Int(data[offset]), g: Int(data[offset + 1]), b: Int(data[offset + 2]))
    }

    /// Within `tolerance` on every channel. **Not exact equality, and that is a measured choice, not
    /// a loosened one.** § 10's direct `CoreImageFrameRenderer` → `CVPixelBuffer` path reproduces the
    /// brief's literal expected triples exactly; this path adds a real `AVAssetWriter` encode, a real
    /// decode, and a real `CVPixelBuffer` → `CGImage` conversion on top of the identical renderer —
    /// three more real steps, each a place a colour-managed pipeline can round a value. Measured over
    /// five runs with `AVVideoColorPropertiesKey` pinned (see `writeSolidColorMovie`): the card centre
    /// came back exactly `(255, 0, 0)` every time; the background points came back `(24, 24, 30)`
    /// against an expected `(23, 23, 28)` — every channel within 2. `tolerance: 6` is comfortably
    /// above that measured drift and nowhere close to the ≈230-per-channel gap between red and this
    /// background, so it cannot turn "wrong region" into a pass.
    static func closeEnough(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int), tolerance: Int) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    /// Builds a solid-red source movie, the real composition, and reads one composed frame back —
    /// see this section's own header for why each of those three has to be real for this check to
    /// mean anything. Card geometry comes from calling the real `StagePlanner.plan` with the same
    /// inputs `StageCompositor.startRequest` will use, rather than a second, hand-copied set of
    /// numbers that could drift from what the compositor actually computes.
    @MainActor
    static func theRealCompositionRendersACardOverABackground() async throws {
        let outputWidth = 320
        let outputHeight = 180
        let sourceWidth = 64
        let sourceHeight = 64

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soredemo-probe-composition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Never committed, never under `media/` — a probe-owned scratch file, deleted on every exit
        // path including a thrown error.
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")

        try await writeSolidColorMovie(to: sourceURL, width: sourceWidth, height: sourceHeight,
                                       r: 255, g: 0, b: 0)

        StageCompositor.renderer = try CoreImageFrameRenderer()
        StageCompositor.style = .default

        let asset = AVURLAsset(url: sourceURL)
        let composition = try await CompositionBuilder.composition(
            for: asset, outputWidth: outputWidth, outputHeight: outputHeight,
            frameDuration: CMTime(value: 1, timescale: 30))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: .zero)

        // The exact plan `StageCompositor.startRequest` will compute for these inputs — read, not
        // re-derived by hand, so a future change to `StagePlanner`'s geometry cannot silently make
        // these sample points stop meaning what their names say.
        let plan = StagePlanner.plan(outputWidth: outputWidth, outputHeight: outputHeight,
                                     sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                     style: .default)
        let centreX = Int((plan.card.x + plan.card.width / 2).rounded())
        let centreY = Int((plan.card.y + plan.card.height / 2).rounded())
        // Inside the card's bounding box, in its extreme corner — outside the rounded arc the same
        // way § 10's own corner point is (offset 2 from the card's own origin, well past a radius of
        // 18 here).
        let cornerX = Int(plan.card.x.rounded()) + 2
        let cornerY = Int(plan.card.y.rounded()) + 2

        let centrePixel = try pixel(in: image, x: centreX, y: centreY, outputHeight: outputHeight)
        // Fixed at (10, 10), same as § 10: outside the card's bounding box on every measured plan
        // this task's geometry produces, so it stays in the margin regardless of exactly where
        // `StagePlanner` centres the card.
        let marginPixel = try pixel(in: image, x: 10, y: 10, outputHeight: outputHeight)
        let cardCornerPixel = try pixel(in: image, x: cornerX, y: cornerY, outputHeight: outputHeight)

        check(closeEnough(centrePixel, (255, 0, 0), tolerance: 6),
              "the card's centre carries the source colour, through a real AVVideoComposition",
              actual: "\(centrePixel)", expected: "(255, 0, 0) ± 6")
        check(closeEnough(marginPixel, (23, 23, 28), tolerance: 6),
              "a point in the inset margin carries the background colour",
              actual: "\(marginPixel)", expected: "(23, 23, 28) ± 6")
        check(closeEnough(cardCornerPixel, (23, 23, 28), tolerance: 6),
              "a point inside the card's bounding box but outside its rounded corner carries the "
              + "background colour",
              actual: "\(cardCornerPixel)", expected: "(23, 23, 28) ± 6")
    }
}
