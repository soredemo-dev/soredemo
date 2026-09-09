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
// `Soredemo/Capture/CGGeometryBridge.swift` and `Soredemo/Project/ProjectDocument.swift`
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
// is the default argument of `Capture.AXObserver.init`'s `accessibilityIsGranted`
// predicate, and a default argument has to compile whether or not it is ever
// evaluated. Every `Capture.AXObserver` in § 8 passes its own predicate, so nothing
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
// SHELL's grants, not `dev.soredemo.mac`'s — four confident-looking
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
// `@testable` since Phase 3A-4: the capture and compositing sources are package targets
// now, and Task 3 narrowed to `internal` every type the app tier does not name. This probe
// is not the app tier — it exercises the seams from outside, including ones the product
// deliberately does not export (`InputObserver`, `AXElementSource`). Testability is enabled
// on SwiftPM debug builds, which is what this links against.
@testable import Capture
import Carbon.HIToolbox
import CoreGraphics
// `CIImage` and `CIContext` for § 22 — reading back what the person cut-out actually produced,
// which is the only way to tell a mask that was applied from one that evaporated.
import CoreImage
// `CMSampleBuffer`, `CMReadySampleBuffer`, `CMAudioFormatDescription` for § 13 — building the
// synthetic video and audio sample buffers `MasterWriting`'s two conformances both append.
import CoreMedia
// `CVPixelBuffer` for § 10 — the compositor seam's own vocabulary.
import CoreVideo
import Foundation
import Geometry
import Graph
// § 18 reads `IOSurfaceGetID` — the identity a frame dedup would compare.
import IOSurface
import Overlays
import Project
// `RenderPlan`, `StageRect`, `StageStyle` for § 10 — `Soredemo/Render/*.swift`
// depends on this module and no package test can drive the real
// `CoreImageFrameRenderer` without it.
@testable import Compositing
import Render
@preconcurrency import ScreenCaptureKit
// `Nanoseconds.rawValue` (§ 4, epochAndClock) is `Timeline`'s, reached until
// now only transitively through `Project` → `Graph` → `Timeline`. Harmless
// under a plain `swiftc` invocation; `-enable-upcoming-feature
// MemberImportVisibility` (added to this probe's flags alongside the app's
// other isolation semantics) no longer allows it — a real, pre-existing gap
// this flag surfaced rather than introduced.
import Timeline

/// A viewport spanning the probe's WHOLE arrangement — every display's union.
///
/// The checks that construct an `InputObserver` are about its sink, its tap and its
/// suppression rules, not about which rectangle it normalises against; they synthesise
/// events anywhere in global space, including on a second display at x = 2400. Handing them
/// one display's viewport silently dropped those events as "outside the recording", and
/// three checks went red — correctly: the observer's `nil`-not-clamp rule working exactly as
/// designed, on a viewport that did not describe what those checks meant to record.
///
/// The union is the honest stand-in for "a recording that covers everything the probe
/// synthesises". A real capture never uses one, which is why this lives in the probe rather
/// than in `CaptureViewport`.
func probeDisplayViewport(_ arrangement: DisplayArrangement) -> CaptureViewport {
    let placement = arrangement.placements[0]
    var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
    for p in arrangement.placements {
        let w = Double(p.geometry.pixelWidth) / p.geometry.scale
        let h = Double(p.geometry.pixelHeight) / p.geometry.scale
        minX = min(minX, p.globalOriginX); minY = min(minY, p.globalOriginY)
        maxX = max(maxX, p.globalOriginX + w); maxY = max(maxY, p.globalOriginY + h)
    }
    return CaptureViewport(geometry: placement.geometry,
                           globalOriginX: minX, globalOriginY: minY,
                           widthInPoints: maxX - minX, heightInPoints: maxY - minY)
}


/// Routes a global point to the display containing it and normalises within that display —
/// what `InputObserver.normalizedPosition(…, in: arrangement)` did before the
/// window-capture repair (2026-08-20) gave the observer a `CaptureViewport` instead. These
/// checks are about MULTI-DISPLAY ROUTING, which is now
/// `DisplayArrangement.viewport(forDisplayContaining:)`'s job, so the probe composes the
/// two rather than asserting against a signature that no longer models the question.
func probeNormalised(globalTopLeftX: Double, globalTopLeftY: Double,
                     in arrangement: DisplayArrangement)
    -> (position: NormalizedPoint, revision: GeometryRevision)? {
    guard let viewport = arrangement.viewport(forDisplayContaining: globalTopLeftX,
                                              globalTopLeftY: globalTopLeftY) else { return nil }
    return InputObserver.normalizedPosition(globalTopLeftX: globalTopLeftX,
                                            globalTopLeftY: globalTopLeftY, in: viewport)
}


/// The viewport for the display `revision` names, or `nil` when no attached display carries it.
///
/// **The mirror of `probeNormalised`, and it has to be.** § 8 asks whether the reverse
/// conversion undoes the forward one exactly; the forward one routes to the display containing
/// the point and normalises within it, so the reverse has to reach the SAME display's viewport.
/// Handing it `probeDisplayViewport`'s union would use `placements[0]`'s scale for a point on a
/// scale-2 display, and the round trip would be off by exactly that factor — the defect this
/// section exists to catch, reintroduced by the fixture.
func probeViewport(revision: GeometryRevision, in arrangement: DisplayArrangement) -> CaptureViewport? {
    guard let placement = arrangement.placements
        .first(where: { $0.geometry.revision == revision }) else { return nil }
    return CaptureViewport(
        geometry: placement.geometry,
        globalOriginX: placement.globalOriginX, globalOriginY: placement.globalOriginY,
        widthInPoints: Double(placement.geometry.pixelWidth) / placement.geometry.scale,
        heightInPoints: Double(placement.geometry.pixelHeight) / placement.geometry.scale)
}

/// `AXObserver.normalizedFrame` composed with the same routing, for the element side.
func probeNormalizedFrame(globalTopLeftX: Double, globalTopLeftY: Double,
                          width: Double, height: Double,
                          in arrangement: DisplayArrangement) -> NormalizedFrame? {
    guard let viewport = arrangement.viewport(forDisplayContaining: globalTopLeftX,
                                              globalTopLeftY: globalTopLeftY) else { return nil }
    return Capture.AXObserver.normalizedFrame(globalTopLeftX: globalTopLeftX,
                                              globalTopLeftY: globalTopLeftY,
                                              width: width, height: height, in: viewport)
}

/// `AXObserver.globalPoint` composed with the routing that used to be inside it — the reverse
/// of `probeNormalised`, step for step.
func probeGlobalPoint(of position: NormalizedPoint, revision: GeometryRevision,
                      in arrangement: DisplayArrangement) -> (x: Double, y: Double)? {
    guard let viewport = probeViewport(revision: revision, in: arrangement) else { return nil }
    return Capture.AXObserver.globalPoint(of: position, revision: revision, in: viewport)
}

/// Builds a `.window` source the way `CaptureSource.init(pickerFilter:availableDisplays:)`
/// does, so these checks keep exercising the production shape after the source-rect repair
/// (2026-08-20) replaced `bufferSize`-on-the-case with a `WindowCapture`. Takes the display
/// the caller already obtained rather than re-deriving it, so the probe cannot disagree
/// with itself about which display the window is on.
func probeWindowSource(_ window: SCWindow, on display: SCDisplay,
                       bufferSize: (width: Int, height: Int)) -> CaptureSource {
    let frame = CGGeometryBridge.pointRect(from: window.frame)
    let bounds = CGGeometryBridge.pointRect(from: display.frame)
    return .window(WindowCapture(
        window: window,
        display: display,
        sourceRect: PointRect(x: frame.x - bounds.x, y: frame.y - bounds.y,
                              width: frame.width, height: frame.height),
        bufferWidth: bufferSize.width, bufferHeight: bufferSize.height))
}


/// `<repo>/scripts/cross-boundary-digest-probe.swift` → `<repo>/Core`, the PACKAGE root.
/// Two `deletingLastPathComponent()` calls reach the repository root — this file sits directly
/// under `scripts/` — and `Core` is appended because the fixtures it wants live in the package,
/// which stopped being the repository root when the package moved there. Used by § 15/§ 16
/// (Phase 2B Task 8) to find the committed fixture at `Tests/RenderParityFixtures/`.
let probePackageRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Core")

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
/// Sections that did not run, and why.
///
/// **A skipped section used to be invisible.** The count is the only thing the
/// verdict line carried, and a run that measured seventy checks fewer than the
/// last one still said PROBE PASSED — a number nobody was comparing against
/// anything. `count-tests.sh` states the rule this file was missing: a gate that
/// passes having measured nothing is worse than one that fails.
@MainActor var skipped: [String] = []

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

        print("8. Capture.AXObserver — the bounded walk that records and does not judge (Task 10)")
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

        print("12. the drawn pointer — StageCompositor reads the observation log (Phase 2B Task 5)")
        print("12.1 a real ObservationWriter log, all four PointerReading cases and the ripple, sampled as real pixels")
        try await theDrawnPointerFollowsARealObservationLogThroughARealComposition()
        print("12.2 ObservationWriter.expectedLogURL(forMediaURL:) — the media↔log naming convention, both directions")
        observationLogURLIsDerivedFromTheMediaURLsOwnConvention()

        print("13. SuccessorMasterWriter — the differential test across the MasterWriting seam (Phase 2B Task 6)")
        print("13.1 identical input into both conformances; compare the FINISHED FILES, never either writer's own account")
        // A `do`/`catch` here, unlike every other numbered section: this is the one section
        // whose measured failure mode is a genuine, reproducible append stall (see this
        // function's own header for the measurement), and a probe that crashes on section 13
        // reports NOTHING about the twelve sections before it were it not for them having
        // already printed — this still turns a stall into one failed check with a diagnostic,
        // rather than an uncaught-error trap that discards the summary line at the very end.
        do {
            try await theSuccessorMasterWriterAgreesWithTheLegacyOneOnTheFinishedFile()
        } catch {
            check(false, "§13 completed without throwing — see the error for where it stopped",
                  actual: "\(error)")
        }

        print("14. MP4Exporter — export never drops a frame, and the exported file IS the composed one (Phase 2B Task 7)")
        print("14.1 a synthetic movie, exported, and read back independently — never MP4Exporter's own account of itself")
        try await theExportedFileDropsNoFrameAndCarriesTheFraming()

        print("15. render-parity — the preview path and the export path share one composition (Phase 2B Task 8)")
        print("15.1 the SAME composition time, sampled through two different AVFoundation consumers — "
              + "tests the wiring has not come apart, not that two renderers agree (there is one)")
        try await theSameCompositionTimeMatchesThroughPreviewAndExport()

        print("16. StageCompositor.diagnostics — the preview's dropped-frame count (Phase 2B Task 8)")
        print("16.1-16.3 both causes of a drop, driven directly, plus a clean run that drops nothing")
        try await theDropCounterIsDrivenByBothOfItsTwoCauses()

        print("17. RecordingCoordinator — the app tier's first executing instrument (2026-08-26)")
        print("17.1-17.5 the four persisted preferences: their defaults, their keys, and what a "
              + "stored value this build cannot read falls back to")
        recordingCoordinatorPreferences()

        print("18. the idle-frame question — is a duplicate frame findable by IOSurface identity?")
        print("18.1-18.3 a real SCStream over this process's own window, still, measured twice over")
        try await duplicateFramesAreContentIdenticalNotSurfaceIdentical()

        print("28. what a recording costs in memory, and whether it grows while it runs")
        try await aRecordingDoesNotGrowWhileItRuns()

        // The count is printed, never written down: a hand-maintained total in
        // a report goes stale the first time a check is added and nobody
        // notices, which is what happened to this one.
        if !skipped.isEmpty {
            print("")
            print("SKIPPED \(skipped.count) section(s) — the count below is smaller than a "
                  + "full run's by however many checks they hold:")
            for reason in skipped { print("  - \(reason)") }
        }
        let verdict = failures == 0
            ? "PROBE PASSED (\(checksRun) checks)"
            : "PROBE FAILED (\(failures) of \(checksRun) checks)"
        // The skip is named in the verdict itself, not only above it: a person
        // reading the last line of a log is reading the whole answer as far as
        // they are concerned.
        print(skipped.isEmpty ? verdict : "\(verdict), \(skipped.count) SECTION(S) SKIPPED")
        if failures != 0 { exit(1) }
    }

    // MARK: - § 17. RecordingCoordinator

    /// **The app tier's first executing check, and what it took to reach it.**
    ///
    /// `RecordingCoordinator` lives in `Soredemo/Editor/ContentView.swift`, in the Xcode app target,
    /// which has no test target — `ROADMAP.md`'s `project-format` row has said so since Phase 1.
    /// This probe was the app tier's only instrument and it could not reach the coordinator
    /// either: its own header used to record the recording surfaces as unreachable because they
    /// "depend on RecordingCoordinator, which lives in ContentView.swift with the app lifecycle
    /// this probe does not compile". That turned out to be false. The lifecycle was never the
    /// obstacle; two string constants were. `MenuBarRecorder` named `SoredemoApp` for its two
    /// window ids, `RecordingBar` names `MenuBarRecorderPanel`, and `ContentView` names
    /// `RecordingBarPresenter` — so four files were transitively out of reach over two lines that
    /// had no business being on the `@main` struct. They live in `WindowID` now, and this binary
    /// compiles every app source but `SoredemoApp.swift` itself, which it cannot: two `@main`
    /// declarations do not link.
    ///
    /// **What is checked here is the persistence, because that is what is deterministic.** The
    /// coordinator's interesting behaviour — a self-view that must disappear when the camera is
    /// switched off mid-recording — needs a camera device, a TCC grant and a running capture, and
    /// a check that needs those three is not a check. `init()` is the opposite: four preferences
    /// read from `UserDefaults`, each with a defaulting rule whose own comment states the defect
    /// it exists to prevent, and none of them had ever been executed by anything.
    ///
    /// **Two things about touching `UserDefaults` from a probe.** The domain is printed rather
    /// than assumed — this is a bare executable with no bundle identifier, so its preferences do
    /// not land in the shipping app's domain — and every key is snapshotted and restored anyway,
    /// so the claim does not rest on that being true.
    @MainActor
    static func recordingCoordinatorPreferences() {
        let defaults = UserDefaults.standard
        let countdownKey = RecordingCoordinator.countdownKey
        let frameRateKey = RecordingCoordinator.frameRateKey
        let qualityKey = RecordingCoordinator.cameraQualityKey
        let styleKey = RecordingCoordinator.cameraStyleKey
        let iconsKey = RecordingCoordinator.hidesDesktopIconsKey
        let dockKey = RecordingCoordinator.hidesDockKey
        let menuBarKey = RecordingCoordinator.hidesMenuBarKey
        let scrubKey = RecordingCoordinator.scrubAudioKey
        let systemAudioKey = RecordingCoordinator.capturesSystemAudioKey
        let widgetsKey = RecordingCoordinator.hidesDesktopWidgetsKey
        let keys = [countdownKey, frameRateKey, qualityKey, styleKey, iconsKey, dockKey,
                    menuBarKey, scrubKey, systemAudioKey, widgetsKey]

        print("        preferences domain: "
              + (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
              + " (not the app's — this binary has no bundle identifier)")

        let saved = keys.map { (key: $0, value: defaults.object(forKey: $0)) }
        defer {
            for entry in saved {
                if let value = entry.value { defaults.set(value, forKey: entry.key) }
                else { defaults.removeObject(forKey: entry.key) }
            }
        }

        // ---- 17.1 nothing stored: the stated defaults, not the zero values.
        for key in keys { defaults.removeObject(forKey: key) }
        let firstLaunch = RecordingCoordinator()
        // The one `init()` names outright: `integer(forKey:)` answers 0 for a key never set, and
        // 0 is a legitimate countdown meaning "off" — so the obvious spelling ships a first
        // launch with the countdown silently disabled.
        check(firstLaunch.countdownSeconds == 3,
              "17.1 a first launch counts down 3 seconds, not 0",
              actual: "\(firstLaunch.countdownSeconds)", expected: "3")
        // Same trap, worse consequence: 0 is not a frame rate at all, and `CaptureFrameRate`'s
        // own initialiser refuses it — so the fallback is what keeps a first launch from having
        // no rate rather than a bad one.
        check(firstLaunch.frameRate == .sixty,
              "17.1 a first launch records at 60, not at a rate no initialiser would accept",
              actual: "\(firstLaunch.frameRate.rawValue)", expected: "60")
        check(firstLaunch.cameraQuality == .best,
              "17.1 a first launch's camera quality is .best",
              actual: "\(firstLaunch.cameraQuality.rawValue)", expected: "best")
        check(firstLaunch.cameraStyle == .default,
              "17.1 a first launch's camera sits where CameraOverlayStyle.default puts it")
        // **Both switches are off on a first launch, and for two different reasons.** Hiding the
        // desktop icons restarts Finder and closes somebody's windows, so it must be asked for.
        // Hiding the Dock costs nothing at all — it is excluded from the capture filter and the
        // machine is not touched — and is still off, because a recording that quietly omits part
        // of the screen is not what pressing Record is understood to mean.
        check(!firstLaunch.hidesDesktopIcons,
              "17.1 a first launch does not restart Finder to hide desktop icons")
        check(!firstLaunch.hidesDock,
              "17.1 a first launch records the Dock rather than silently omitting it")
        check(!firstLaunch.hidesMenuBar,
              "17.1 a first launch records the menu bar rather than silently omitting it")
        // **The one switch here that defaults ON**, and the reason is what it touches: the three
        // above change what a recording CONTAINS, so a surprising default would be in somebody's
        // file. This changes only what the person editing hears. `bool(forKey:)` answers false
        // for a key never written, which is the trap 17.1 exists for.
        check(firstLaunch.scrubAudio,
              "17.1 a first launch plays audio while the playhead is dragged")

        // The second switch that defaults ON, and for the opposite reason to the one above: this
        // one DOES change what a recording contains, and a demo of anything that makes a sound
        // is worse without it. What it must not do is be unaskable, which it was until now.
        check(firstLaunch.capturesSystemAudio,
              "17.1 a first launch records the machine's own output")

        // ---- 17.2 each preference reaches disk, under the key the app has always used.
        //
        // **The four literals below are spelled out HERE, and that is the whole check.** The
        // first version of this section read each key through `RecordingCoordinator`'s own
        // constant and asserted the value landed under it — which is self-referential: renaming
        // the constant renames both sides at once. Measured, not reasoned about: renaming
        // `frameRateKey` to `"captureFrameRateV2"` left all 371 checks green. A renamed key does
        // not fail anywhere else either; it silently resets every existing user's preference to
        // its default on the next launch. So the string is pinned on this side of the boundary,
        // where changing the app cannot change the expectation.
        let pinnedKeys = [("countdown", countdownKey, "countdownSeconds"),
                          ("frame rate", frameRateKey, "captureFrameRate"),
                          ("camera quality", qualityKey, "cameraQuality"),
                          ("camera style", styleKey, "cameraOverlayStyle"),
                          ("desktop-icon switch", iconsKey, "hidesDesktopIcons"),
                          ("Dock switch", dockKey, "hidesDock"),
                          ("menu-bar switch", menuBarKey, "hidesMenuBar"),
                          ("scrub-audio switch", scrubKey, "scrubAudio"),
                          ("system-audio switch", systemAudioKey, "capturesSystemAudio"),
                          ("desktop-widget switch", widgetsKey, "hidesDesktopWidgets")]
        for (what, declared, pinned) in pinnedKeys {
            check(declared == pinned,
                  "17.2 the \(what) is stored under the key it has always been stored under",
                  actual: declared, expected: pinned)
        }
        firstLaunch.countdownSeconds = 5
        firstLaunch.frameRate = .thirty
        firstLaunch.cameraQuality = .hd720
        let moved = CameraOverlayStyle(widthFraction: 0.25, x: 0.2, y: 0.8, shape: .square,
                                       cornerFraction: 0.1, isMirrored: false,
                                       borderOpacity: 0.1, shadowOpacity: 0.2)
        firstLaunch.cameraStyle = moved
        firstLaunch.hidesDesktopIcons = true
        firstLaunch.hidesDock = true
        firstLaunch.hidesMenuBar = true
        firstLaunch.scrubAudio = false
        firstLaunch.capturesSystemAudio = false
        firstLaunch.hidesDesktopWidgets = true

        check(defaults.object(forKey: countdownKey) as? Int == 5,
              "17.2 the countdown is written under '\(countdownKey)'",
              actual: String(describing: defaults.object(forKey: countdownKey)), expected: "5")
        check(defaults.object(forKey: frameRateKey) as? Int == 30,
              "17.2 the frame rate is written under '\(frameRateKey)'",
              actual: String(describing: defaults.object(forKey: frameRateKey)), expected: "30")
        check(defaults.string(forKey: qualityKey) == "hd720",
              "17.2 the camera quality is written under '\(qualityKey)'",
              actual: String(describing: defaults.string(forKey: qualityKey)), expected: "hd720")
        check(defaults.data(forKey: styleKey) != nil,
              "17.2 the camera style is written under '\(styleKey)'")
        check(defaults.object(forKey: iconsKey) as? Bool == true,
              "17.2 the desktop-icon switch is written under '\(iconsKey)'",
              actual: String(describing: defaults.object(forKey: iconsKey)), expected: "true")
        check(defaults.object(forKey: dockKey) as? Bool == true,
              "17.2 the Dock switch is written under '\(dockKey)'",
              actual: String(describing: defaults.object(forKey: dockKey)), expected: "true")
        check(defaults.object(forKey: menuBarKey) as? Bool == true,
              "17.2 the menu-bar switch is written under '\(menuBarKey)'",
              actual: String(describing: defaults.object(forKey: menuBarKey)), expected: "true")
        check(defaults.object(forKey: scrubKey) as? Bool == false,
              "17.2 the scrub-audio switch is written under '\(scrubKey)'",
              actual: String(describing: defaults.object(forKey: scrubKey)), expected: "false")

        // ---- 17.3 and a relaunch reads them back. A separate check from 17.2 on purpose: a
        // preference that reaches disk and is not read on the way back up is still lost, and the
        // two failures have different causes — a `didSet` that stopped firing, against an `init`
        // that stopped looking.
        let relaunched = RecordingCoordinator()
        check(relaunched.countdownSeconds == 5, "17.3 a relaunch counts down 5",
              actual: "\(relaunched.countdownSeconds)", expected: "5")
        check(relaunched.frameRate == .thirty, "17.3 a relaunch records at 30",
              actual: "\(relaunched.frameRate.rawValue)", expected: "30")
        check(relaunched.cameraQuality == .hd720, "17.3 a relaunch keeps the camera quality",
              actual: relaunched.cameraQuality.rawValue, expected: "hd720")
        check(relaunched.cameraStyle == moved,
              "17.3 a relaunch puts the camera back where it was dragged to")
        check(relaunched.hidesDesktopIcons,
              "17.3 a relaunch still hides the desktop icons")
        check(relaunched.hidesDock,
              "17.3 a relaunch still keeps the Dock out of the picture")
        check(relaunched.hidesMenuBar,
              "17.3 a relaunch still keeps the menu bar out of the picture")
        // **Deliberately turned OFF above**, which is the distinction 17.4 makes for the
        // countdown: a switch whose default is on must remember being turned off.
        check(relaunched.hidesDesktopWidgets,
              "17.3 a desktop-widget switch deliberately turned on stays on across a relaunch")
        check(!relaunched.capturesSystemAudio,
              "17.3 system audio deliberately turned off stays off across a relaunch")
        check(!relaunched.scrubAudio,
              "17.3 a scrub-audio switch deliberately turned off stays off")

        // ---- 17.4 zero is a stored answer, not an absent key. This is the distinction 17.1's
        // default rests on, from the other side: if the two collapsed, somebody who deliberately
        // turned the countdown off would get three seconds back on every launch.
        relaunched.countdownSeconds = 0
        check(RecordingCoordinator().countdownSeconds == 0,
              "17.4 a countdown deliberately set to off stays off across a relaunch",
              actual: "\(RecordingCoordinator().countdownSeconds)", expected: "0")

        // ---- 17.5 a stored value this build cannot read falls back rather than trapping.
        // These are not hypothetical: a downgrade, a hand-edited plist, and a shape enum that
        // gains a case all produce exactly this. `CaptureFrameRate.init(rawValue:)` refuses a
        // non-positive rate, so a stored 0 must not become a `CMTime` timescale of zero.
        defaults.set(0, forKey: frameRateKey)
        defaults.set("a-quality-this-build-does-not-have", forKey: qualityKey)
        defaults.set(Data("not JSON at all".utf8), forKey: styleKey)
        defaults.set("three", forKey: countdownKey)
        let recovered = RecordingCoordinator()
        check(recovered.frameRate == .sixty,
              "17.5 a stored frame rate of 0 falls back to 60 rather than becoming a timescale",
              actual: "\(recovered.frameRate.rawValue)", expected: "60")
        check(recovered.cameraQuality == .best,
              "17.5 a camera quality this build does not know falls back to .best",
              actual: recovered.cameraQuality.rawValue, expected: "best")
        check(recovered.cameraStyle == .default,
              "17.5 a camera style that will not decode falls back to the default")
        check(recovered.countdownSeconds == 3,
              "17.5 a countdown stored as text falls back to 3",
              actual: "\(recovered.countdownSeconds)", expected: "3")
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

        // THE UNIT, AGAINST A CLOCK THAT IS NOT `Minting`'s.
        //
        // Everything else in this file that touches the host clock reads it through
        // `Minting.hostNow()`, so every one of those checks holds just as well if the
        // `mach_timebase_info` multiply inside `hostNow` regressed and it started returning raw
        // mach TICKS instead of nanoseconds: "advances" is true of ticks, "continuousNow >=
        // hostNow" is true of ticks, and § 7.2 — which calls itself the standing check on this
        // unit — mints its synthetic `CGEventTimestamp` FROM `hostNow()` itself, so a regression
        // would move stamp and clock together and leave the skew at ≈0. On Apple Silicon the
        // timebase is 125/3, so the failure is a factor of ~41.67, not a rounding error.
        //
        // `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` is the independent instrument: nanoseconds by
        // definition, same origin (boot, not counting sleep) as `mach_absolute_time`, and it does
        // not go through `Minting`. Agreement to a millisecond over two reads taken microseconds
        // apart is far tighter than the ~41x a lost timebase multiply would produce.
        //
        // This is the last known instance in this tree of the shape that hid `1a98402` for a
        // phase: a check whose expected value is computed by the code it is checking. See
        // AGENTS.md, "Every automatic check inherits the implementation's misunderstanding".
        let mintedNanos = Minting.hostNow().rawValue
        let independentNanos = Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let unitSkew = abs(independentNanos - mintedNanos)
        check(unitSkew < 1_000_000,
              "hostNow() is in NANOSECONDS, measured against clock_gettime_nsec_np(CLOCK_UPTIME_RAW) "
              + "— an instrument Minting does not own. A lost mach_timebase multiply would show here "
              + "as a ~41.67x disagreement and nowhere else in this file",
              actual: "hostNow=\(mintedNanos) CLOCK_UPTIME_RAW=\(independentNanos) "
              + "skew=\(unitSkew) ns (< 1_000_000 required)")

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

        // ---- 0. the menu bar switch reaches the filter it is supposed to reach.
        //
        // **Here because a filter needs a real `SCDisplay`**, which no unit test can build.
        // `CaptureExclusions.hidesMenuBar` is one boolean travelling through three files to land
        // on `SCContentFilter.includeMenuBar`, and every step of that is the kind that compiles
        // perfectly while doing nothing: a defaulted argument left off at the call site, a
        // property set on a copy. Nothing else in the project would notice — the recording would
        // simply still have a menu bar in it, which looks exactly like nobody asked.
        //
        // Also checked: the frame does not change size. A property that CROPPED rather than hid
        // would change the output's dimensions, and every geometry downstream is built on those.
        let menuBarSource = CaptureSource.display(display)
        let withMenuBar = menuBarSource.filter(showsMenuBar: true)
        let withoutMenuBar = menuBarSource.filter(showsMenuBar: false)
        check(withMenuBar.includeMenuBar,
              "5.0 a filter asked to show the menu bar includes it",
              actual: "\(withMenuBar.includeMenuBar)", expected: "true")
        check(!withoutMenuBar.includeMenuBar,
              "5.0 a filter asked to hide the menu bar excludes it",
              actual: "\(withoutMenuBar.includeMenuBar)", expected: "false")
        check(withMenuBar.contentRect == withoutMenuBar.contentRect,
              "5.0 hiding the menu bar hides it rather than cropping the frame",
              actual: "\(withoutMenuBar.contentRect)", expected: "\(withMenuBar.contentRect)")
        // The default is to show it: a caller that forgets the argument must not silently start
        // omitting part of somebody's screen.
        check(menuBarSource.filter().includeMenuBar,
              "5.0 the menu bar is shown unless somebody asks otherwise")

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
        let windowSourceBeforeMove = probeWindowSource(scWindowBeforeMove, on: display, bufferSize: bufferSize)
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

        let windowSourceAfterMove = probeWindowSource(scWindowAfterMove, on: display, bufferSize: bufferSize)
        let geometryAfterMove = windowSourceAfterMove.geometry(scale: 2, displayUUID: windowSourceID)
        check(geometryBeforeMove.revision == geometryAfterMove.revision,
              ".window: dragging to a different screen frame does not change the revision (D2-13)",
              actual: "\(geometryBeforeMove.revision) vs \(geometryAfterMove.revision)")

        // ---- 3. .window — resized output buffer, same window, different revision.
        let smallerBufferSource = probeWindowSource(scWindowAfterMove, on: display, bufferSize: (width: 800, height: 600))
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

        // **The precondition, checked before the thing that depends on it.**
        //
        // `setFrameOrigin` is a REQUEST. Observed 2026-09-10: the probe asked for x = 700 and
        // the window server put the window at x = 2094 — past the right edge of the only
        // display — and the derivation below correctly returned nil, because
        // `CaptureSource.init(pickerFilter:)` refuses a window no display hosts (see its own
        // comment: a window with no host is a capture that cannot start). The probe then
        // reported that refusal as "CaptureSource does not derive a .window from a window-style
        // filter", which is a fact about the WINDOW PLACEMENT stated as a fact about the code
        // under test — and it took a stashed-tree comparison to find that out.
        //
        // So the placement is asserted here, by name, and the remainder is skipped rather than
        // blamed on the derivation. A skip is honest; a red check pointing at the wrong file is
        // worse than no check at all, because somebody spends an afternoon in that file.
        let placed = CGGeometryBridge.pointRect(from: scWindowAfterMove.frame)
        let screen = CGGeometryBridge.pointRect(from: display.frame)
        let onADisplay = placed.x < screen.x + screen.width && placed.x + placed.width > screen.x
            && placed.y < screen.y + screen.height && placed.y + placed.height > screen.y
        guard onADisplay else {
            print("        SKIPPED remainder — the window server did not honour the placement: "
                  + "asked for x = 700, the window is at \(placed), and the display is \(screen). "
                  + "Nothing below can be decided about CaptureSource from a window no display hosts.")
            return
        }

        guard let derivedWindowSource = CaptureSource(pickerFilter: windowFilter, availableDisplays: [display])
        else {
            check(false, "CaptureSource(pickerFilter:) derives a .window from a window-style filter")
            return
        }
        if case .window(let derived) = derivedWindowSource {
            check(derived.window.windowID == scWindowAfterMove.windowID,
                  "CaptureSource(pickerFilter:) picked the same SCWindow the filter names")

            // **This check was inverted by the source-rect repair (2026-08-20), and the
            // inversion is the point.** It used to pin a DISPLAY-sized buffer — D2-13a's
            // decision — and that decision produced a real recording whose output was
            // display-resolution with the window occupying a fraction of it. The buffer is
            // now sized to the WINDOW, at the filter's own pointPixelScale.
            //
            // Pinned to a computed expectation, not to "positive": a regression back to
            // display-sizing would still be positive and would pass a weaker check. On a
            // multi-display machine the two differ by construction; on a single display
            // they differ whenever the window is not full-screen, which the probe's own
            // 500×360 window guarantees.
            let expectedWidth = Int((windowFilter.contentRect.width
                                     * CGFloat(windowFilter.pointPixelScale)).rounded())
            let expectedHeight = Int((windowFilter.contentRect.height
                                      * CGFloat(windowFilter.pointPixelScale)).rounded())
            check(derived.bufferWidth == expectedWidth && derived.bufferHeight == expectedHeight,
                  "CaptureSource(pickerFilter:) derives a WINDOW-sized buffer, not a display-sized one",
                  actual: "\(derived.bufferWidth)x\(derived.bufferHeight)",
                  expected: "\(expectedWidth)x\(expectedHeight)")

            // And it is strictly SMALLER than the display, which is the discriminating
            // half: a regression to display-sizing makes these equal and reddens this.
            let displayPixelWidth = Int((Double(display.width)
                                         * Double(windowFilter.pointPixelScale)).rounded())
            check(derived.bufferWidth < displayPixelWidth,
                  "the derived buffer is strictly narrower than the display — a display-sized regression makes them equal",
                  actual: "\(derived.bufferWidth) vs display \(displayPixelWidth)")

            // The window's place on its display is still derived — the POINTER is normalised
            // against the rectangle actually recorded — it is just no longer the stream's
            // crop. Same arithmetic, different consumer, so it is still checked here.
            let hostBounds = CGGeometryBridge.pointRect(from: derived.display.frame)
            let windowFrame = CGGeometryBridge.pointRect(from: derived.window.frame)
            check(abs(derived.sourceRect.x - (windowFrame.x - hostBounds.x)) < 0.001
                  && abs(derived.sourceRect.y - (windowFrame.y - hostBounds.y)) < 0.001,
                  "the window's rect is its frame rebased onto its own display's origin",
                  actual: "\(derived.sourceRect.x),\(derived.sourceRect.y)")
            check(derived.sourceRect.width == windowFrame.width
                  && derived.sourceRect.height == windowFrame.height,
                  "and it keeps the window's own extent")

            // **A WINDOW filter, against a real `SCWindow` handle.** This probe is the only
            // place that can check the filter's type at all — a package test cannot construct
            // an `SCWindow`. It asserted `.display` for one phase, which is exactly how long
            // a window recording captured whatever overlapped the window: the Dock, in a
            // user's recording. This filter is what comparable recorders use; the
            // arguments for the display one are answered in `CaptureSource.filter()`.
            check(derivedWindowSource.filter().style == .window,
                  "a window source captures through a WINDOW filter, so nothing overlapping "
                  + "the window is captured with it",
                  actual: "\(derivedWindowSource.filter().style.rawValue)")
            check(derivedWindowSource.sourceRect == nil,
                  "and carries no source rect — a crop would cut the window's own content by "
                  + "its offset on the display")
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
    // `input-observation` row. The half that needs a person has no harness
    // in the tree: creating the tap needs Input
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
    /// entirely. `Capture.AXObserver.globalPoint` adds the origin back and
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

        guard let converted = probeNormalised(globalTopLeftX: globalX,
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
        guard let onMain = probeNormalised(globalTopLeftX: 192, globalTopLeftY: 108, in: arrangement) else {
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
        let atSeam = probeNormalised(globalTopLeftX: 1920, globalTopLeftY: 10, in: arrangement)
        check(atSeam?.revision == retina.revision,
              "a point exactly on the shared edge belongs to the display whose origin it is",
              actual: "\(String(describing: atSeam?.revision))", expected: "\(retina.revision)")

        // ---- Every point on either display normalises into [0, 1].
        // The plan flags the trap: a sample on a second display fails this if
        // the global point was not routed first. It is routed, so it does not.
        var sweep: [NormalizedPoint] = []
        for x in stride(from: 0.0, through: 3839.0, by: 137.0) {
            for y in stride(from: 0.0, through: 1079.0, by: 97.0) {
                if let p = probeNormalised(globalTopLeftX: x, globalTopLeftY: y, in: arrangement) {
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
        check(probeNormalised(globalTopLeftX: 9000, globalTopLeftY: 9000, in: arrangement) == nil,
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

    /// Collects `AXChainRecord`s from `Capture.AXObserver.enqueue`'s `@Sendable`
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
        let observer = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch)
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
        // **The expectation is derived from the SAME viewport the observer was given**,
        // not from a hardcoded pair. Before the window-capture repair (2026-08-20) the
        // observer normalised against a display and (0.25, 0.75) was that display's answer;
        // it now normalises against whatever is being recorded, and this check's subject was
        // always "the sample carries the CONVERTED position", never one particular number.
        // Deriving it here keeps the check discriminating — a conversion that silently
        // stopped happening still fails, because `probeExpected` would then disagree with a
        // sample carrying raw or zeroed coordinates.
        let probeExpected = probeDisplayViewport(arrangement)
            .normalise(globalTopLeftX: 2400, globalTopLeftY: 270)
        check(probeExpected.map { sample.position == $0 } == true
              && sample.revision == probeDisplayViewport(arrangement).revision,
              "the emitted pointer sample carries the converted position and the viewport's revision",
              actual: "(\(sample.position.x), \(sample.position.y)) \(sample.revision)",
              expected: probeExpected.map { "(\($0.x), \($0.y))" } ?? "nil")
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
        let latencyObserver = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch)
        latencyObserver.handle(type: .mouseMoved,
                               event: mouseEvent(.mouseMoved, at: CGPoint(x: 2400, y: 270),
                                                 stamp: Nanoseconds(Minting.hostNow().rawValue - 20_000_000)))
        check(latencyObserver.diagnostics.implausibleEventTimestampCount == 0,
              "20 ms of tap latency — ~4x Spike A's worst of 118 samples — is still plausible",
              actual: "\(latencyObserver.diagnostics.implausibleEventTimestampCount)", expected: "0")

        // ---- A click is a down and an up. Both carry a position.
        let clicks = Collector()
        let clickObserver = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch)
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
        // Derived from the same viewport, same reason as the pointer check above: the
        // subject is that BOTH halves carry the converted position, not what that
        // position happens to be on this arrangement.
        let clickExpected = probeDisplayViewport(arrangement)
            .normalise(globalTopLeftX: 2400, globalTopLeftY: 270)
        check(clickExpected.map { expected in buttons.allSatisfy { $0.position == expected } } == true,
              "both halves of the click carry the converted position")

        // ---- A location on no display is dropped and counted, not clamped.
        let offscreen = Collector()
        let offscreenObserver = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch)
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
        let observer = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch)
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
        let approvedObserver = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch)
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
        let observer = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch,
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
        let stoppingObserver = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch,
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
        // NSScreen.main is documented as the screen holding the key window —
        // and with no key window, the screen under the cursor. It is NOT the
        // menu-bar display. CGMainDisplayID() names the menu-bar display.
        // Those two agree only by coincidence on a multi-display machine, so
        // this check's answer used to depend on where the cursor happened to
        // be, and it passed for a whole phase on exactly that coincidence.
        // The independent source of truth for the display CGMainDisplayID()
        // names is the NSScreen that reports that same NSScreenNumber — that
        // pairing, and not NSScreen.main, is what makes this comparison a
        // cross-boundary invariant rather than a coincidence.
        let mainDisplayID = CGMainDisplayID()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainDisplayID
        }) else {
            check(false, "no NSScreen reports NSScreenNumber == CGMainDisplayID() — there is no independent source to check against")
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
        guard let centre = probeNormalised(globalTopLeftX: centreX,
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
        let observer = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch)
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

    // MARK: - § 8  Capture.AXObserver (Task 10)
    //
    // Why here and not in a test target: `Capture.AXObserver` lives in the app, names
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
    // the resulting distributions still look like F2-2's. That step has no
    // harness in the tree.

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

    /// An `Capture.AXObserver` whose accessibility predicate is **always explicit**.
    ///
    /// Never `Capture.AXObserver(arrangement:epoch:)` in this file. That form
    /// evaluates the default argument, which reads TCC — and a TCC read from
    /// this binary reports the shell's grants, not this app's, for the reason
    /// this file's header sets out at length. Routing every construction
    /// through here makes "the probe asks TCC nothing" a property of one
    /// function instead of a habit at nine call sites.
    @MainActor
    static func axObserver(_ arrangement: DisplayArrangement, _ epoch: BootEpoch,
                           on revision: GeometryRevision? = nil,
                           accessibilityGranted: Bool = true) -> Capture.AXObserver {
        // **The viewport of the display the CLICK is on, which is a parameter.** Since
        // 2026-08-26 this observer normalises against what is being recorded rather than
        // against an arrangement — the AX half of the window-capture repair. A click carries
        // the revision it was normalised against and `globalPoint` refuses one from another
        // rectangle, so an observer on the wrong display answers `nil` for every chain.
        //
        // **Measured, not assumed:** a first version defaulted to `placements[0]` on the
        // reasoning that the checks click on the main display. They do not — § 8.3 and § 8.4
        // click at global (2400, 270), which is on the scale-2 retina display at x = 1920 —
        // and twelve checks went red saying "a hit element must produce a record". The default
        // is still the main display, for the checks that genuinely use it; the ones that click
        // elsewhere name their revision.
        let placement = revision.flatMap { wanted in
            arrangement.placements.first { $0.geometry.revision == wanted }
        } ?? arrangement.placements[0]
        let viewport = CaptureViewport(
            geometry: placement.geometry,
            globalOriginX: placement.globalOriginX, globalOriginY: placement.globalOriginY,
            widthInPoints: Double(placement.geometry.pixelWidth) / placement.geometry.scale,
            heightInPoints: Double(placement.geometry.pixelHeight) / placement.geometry.scale)
        return Capture.AXObserver(viewport: viewport, epoch: epoch,
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
        guard let converted = probeNormalised(globalTopLeftX: x, globalTopLeftY: y, in: arrangement) else { return nil }
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
        guard let forward = probeNormalised(globalTopLeftX: globalX,
                                             globalTopLeftY: globalY,
                                             in: arrangement) else {
            check(false, "a point on the scale: 2 display must route somewhere")
            return
        }
        guard let back = probeGlobalPoint(of: forward.position, revision: forward.revision,
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
        check(probeGlobalPoint(of: forward.position,
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
        guard let onLeft = probeNormalised(globalTopLeftX: negativeX,
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
        guard let backOnLeft = probeGlobalPoint(of: onLeft.position,
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

        guard let frame = probeNormalizedFrame(globalTopLeftX: axX, globalTopLeftY: axY,
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

        check(probeNormalizedFrame(globalTopLeftX: 9000, globalTopLeftY: 270,
                                         width: axW, height: axH, in: arrangement) == nil,
              "a frame whose origin is on no attached display normalises to nothing, rather than "
              + "against whichever display happens to be first")
        check(probeNormalizedFrame(globalTopLeftX: axX, globalTopLeftY: axY,
                                         width: axW, height: -1, in: arrangement) == nil,
              "a negative dimension from a misbehaving application yields nil — PointRect.init "
              + "would trap on it, and a trap in a walk that reads another process's UI is not a "
              + "failure mode this row can have")

        // ---- an element on the display placed up and to the left. Its AX
        // frame is reported in NEGATIVE global points, which is what a window
        // on that display actually looks like to the accessibility API.
        let (_, _, _, left) = fixtureArrangement()
        guard let onLeft = probeNormalizedFrame(globalTopLeftX: -1000, globalTopLeftY: -500,
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
        guard let complete = axObserver(arrangement, epoch, on: click.revision)
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
        check(complete.depthCap == Capture.AXObserver.depthCap
                && complete.walkBudgetNanos == Capture.AXObserver.walkBudgetNanos,
              "the bounds in force are recorded per observation, because the budget is a D4 "
              + "placeholder and a log written under a different one is a different measurement",
              actual: "depth \(complete.depthCap), budget \(complete.walkBudgetNanos) ns")

        // ---- the depth cap.
        let deep = axObserver(arrangement, epoch, on: click.revision)
        guard let capped = deep.chain(at: click,
                                      source: FakeAXSource(nodes: fakeTree(ancestorDepth: 40, children: 0),
                                                           hitIndex: 0)) else {
            check(false, "a deep tree must still produce a record"); return
        }
        check(capped.truncation == .depthCapReached,
              "a 40-level hierarchy stops at the cap and says so",
              actual: "\(capped.truncation)")
        check(capped.ancestors.count == Capture.AXObserver.depthCap,
              "exactly depthCap ancestors were recorded",
              actual: "\(capped.ancestors.count)", expected: "\(Capture.AXObserver.depthCap)")
        check(capped.children == [],
              "and the children were still read: the depth cap is not the budget, and a capped walk "
              + "has spent no measurable time (F2-2: capped walks completed in 4–13 ms)",
              actual: "\(capped.children as [AXElementRecord]?)")

        // ---- the wall-clock budget. 5 ms a call against a 35 ms budget, so
        // the walk is cut off after a handful of levels while the depth cap is
        // nowhere near — the two bounds catch different things (F2-2 § 4).
        let slow = axObserver(arrangement, epoch, on: click.revision)
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
        check(starved.ancestors.count > 0 && starved.ancestors.count < Capture.AXObserver.depthCap,
              "it stopped short of the depth cap, which is what makes this the OTHER bound",
              actual: "\(starved.ancestors.count) ancestors of a possible \(Capture.AXObserver.depthCap)")
        check(starved.ancestors.last?.role != "AXApplication",
              "and it stopped at a mid-level container, not the top of the tree — F2-3: truncation "
              + "drops the OUTERMOST ancestors, the ones least likely to be the camera's target",
              actual: starved.ancestors.last?.role ?? "nil")

        // ---- the hit-test returning nothing.
        let empty = axObserver(arrangement, epoch, on: click.revision)
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
        let blind = axObserver(arrangement, epoch, on: click.revision, accessibilityGranted: false)
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
        let leafObserver = axObserver(arrangement, epoch, on: click.revision)
        let leaf = leafObserver.chain(at: click, source: leafSource)
        check(leaf?.children == [],
              "an element read and found to have no children records the EMPTY list",
              actual: "\(leaf?.children as [AXElementRecord]??)")

        let silentSource = FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0,
                                                        childrenAttributeAnswers: false),
                                        hitIndex: 0)
        let silentObserver = axObserver(arrangement, epoch, on: click.revision)
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
        let containing = axObserver(arrangement, epoch, on: click.revision)
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
        let elsewhere = axObserver(arrangement, epoch, on: click.revision)
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

        // ---- neither fault: the element's origin is OUTSIDE the rectangle being recorded.
        //
        // **This check asserted the opposite until 2026-08-26, and the change is the point of
        // that repair.** While this observer took a `DisplayArrangement` it described the whole
        // desktop: an element at global (100, 100) routed to the main display and came back
        // stamped with that display's revision, so the record carried a frame from one display
        // and a click from another and `clickContainment` answered `.notComparable`.
        //
        // It takes a `CaptureViewport` now, and describes what is being RECORDED. An element
        // whose origin is outside that rectangle is not in the recording, so there is no frame
        // for it — `nil`, counted as `elementFramesUnroutable`, which is the diagnostic that
        // exists to say exactly this. `.noFrameRecorded` is the honest containment answer, and
        // `FramingGate` already refuses on it by name.
        //
        // **`.notComparable` is therefore no longer reachable from this observer**, and that is
        // worth writing down rather than discovering. Every frame it produces now carries the
        // viewport's revision, and a click carrying a different one is refused earlier still —
        // `globalPoint` returns nil and no record is made at all. The case stays in
        // `ClickContainment` because a DECODED record from an older project can carry one, and
        // `FramingGate` must keep an answer for it.
        let straddling = axObserver(arrangement, epoch, on: click.revision)
        let acrossDisplays = straddling.chain(
            at: click,
            source: FakeAXSource(nodes: fakeTree(ancestorDepth: 1, children: 0,
                                                 hitPosition: (x: 100, y: 100),
                                                 hitSize: (width: 4000, height: 400)),
                                 hitIndex: 0))
        check(acrossDisplays?.hit != nil && acrossDisplays?.hit?.frame == nil,
              "an element whose origin is outside the recorded rectangle is DESCRIBED but has no "
              + "frame — the element was found, and where it is has no meaning in this recording",
              actual: "hit \(acrossDisplays?.hit != nil), frame "
                    + "\(acrossDisplays?.hit?.frame as NormalizedFrame??)")
        check(straddling.diagnostics.elementFramesUnroutable >= 1,
              "and it is counted as UNROUTABLE rather than disappearing — the counter that reads "
              + "as 'this element is not in shot', distinct from the one for an element that "
              + "misreported its own dimensions",
              actual: straddling.diagnostics.accounting)
        check(acrossDisplays?.clickContainment == .noFrameRecorded,
              "so the containment answer is 'no frame', not 'not comparable' — since the repair "
              + "every frame this observer produces carries the viewport's own revision, so two "
              + "incomparable revisions can no longer reach a record made here",
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
        // The click first: the observer is built on the display the click is on, so it cannot
        // be constructed before there is a click to ask.
        guard let click = clickEvent(atGlobalX: 2400, y: 270, in: arrangement, epoch: epoch) else {
            check(false, "the fixture click must convert"); return
        }
        let observer = axObserver(arrangement, epoch, on: click.revision)

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

    /// **Every counter in `Capture.AXObserver.Diagnostics` that partitions a real
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
        let counted = axObserver(arrangement, epoch, on: click.revision)
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

        let unavailable = axObserver(arrangement, epoch, on: click.revision)
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

        let unusable = axObserver(arrangement, epoch, on: click.revision)
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

        let unroutable = axObserver(arrangement, epoch, on: click.revision)
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
        let crossEpoch = axObserver(arrangement, epoch, on: click.revision)
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
        let both = axObserver(arrangement, epoch, on: click.revision)
        let cappedThenStarved = both.chain(
            at: click,
            source: FakeAXSource(nodes: fakeTree(ancestorDepth: 40, children: 4),
                                 hitIndex: 0, microsecondsPerCall: 5_000, slowElementsFrom: 41))
        let d = both.diagnostics
        check(cappedThenStarved?.truncation == .budgetExceeded,
              "the record's truncation is the LAST thing that stopped it — the children read",
              actual: "\(cappedThenStarved?.truncation as ChainTruncation??)")
        check(cappedThenStarved?.ancestors.count == Capture.AXObserver.depthCap,
              "and the walk did reach the cap: \(Capture.AXObserver.depthCap) ancestors are recorded",
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
        let starvedBeforeChildren = axObserver(arrangement, epoch, on: click.revision)
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
        let observer = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch,
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
        let secure = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch,
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
        let observer = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch,
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
        let neverPolled = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch,
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
        let blind = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: epoch,
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
        let observer = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: Minting.bootEpoch(),
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
    /// because of the asymmetry in `Capture.AXObserver`'s header: on the callback
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
        let observer = axObserver(arrangement, epoch, on: click.revision)
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
        let onMain = axObserver(arrangement, epoch, on: click.revision)
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
        let hung = axObserver(arrangement, epoch, on: click.revision)
        let hungRecords = Collected()
        let burst = Capture.AXObserver.maximumQueuedClicks + 6
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
        check(d.deepestBacklog > 1 && d.deepestBacklog <= Capture.AXObserver.maximumQueuedClicks,
              "the queue really did back up — deeper than one, and never deeper than the cap. The "
              + "upper half alone is satisfied by a counter that is never updated at all",
              actual: "\(d.deepestBacklog)",
              expected: "between 2 and \(Capture.AXObserver.maximumQueuedClicks)")
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
        let observer = InputObserver(viewport: probeDisplayViewport(arrangement), epoch: Minting.bootEpoch(),
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
    /// and `Capture.AXObserver`'s queue both calling `append`, with `close` arriving on
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
        try renderer.render(plan, source: source, camera: nil, into: destination)

        let centrePixel = pixel(in: destination, atStageX: 160, y: 90, outputHeight: outputHeight)
        let marginPixel = pixel(in: destination, atStageX: 10, y: 10, outputHeight: outputHeight)
        let cardCornerPixel = pixel(in: destination, atStageX: 42, y: 32, outputHeight: outputHeight)

        // the centre of the card is the source colour
        check(centrePixel == (r: 255, g: 0, b: 0), "the card shows the source frame's pixels",
              actual: "\(centrePixel)")
        // a pixel in the inset margin is the background colour, not the source
        check(marginPixel == (r: 23, g: 23, b: 28), "outside the card is the background",
              actual: "\(marginPixel)")
        // The extreme corner of the card is NOT the card — the radius cut it. Since the
        // shadow landed (2026-08-19) the corner shows SHADOWED background, so the old
        // exact-value pin (r: 23, g: 23, b: 28) would fail for a legitimate reason: the
        // claim was always about the card's absence, and darker-than-or-equal-to-background
        // is what that absence looks like under a shadow.
        check(cardCornerPixel != (r: 255, g: 0, b: 0)
              && cardCornerPixel.r <= 23 && cardCornerPixel.g <= 23 && cardCornerPixel.b <= 28,
              "the corner radius removed the card's corner",
              actual: "\(cardCornerPixel)")
    }

    // MARK: - § 11  CompositionBuilder — the real AVVideoComposition, end to end (Phase 2B Task 4)

    /// § 10 drives `CoreImageFrameRenderer` directly against a hand-built `RenderPlan` and a bare
    /// `CVPixelBuffer` pair — real, but it never proves `CompositionBuilder`, `StageCompositor`, or
    /// the `AVVideoComposition`/`AVAssetWriter`/`AVAssetImageGenerator` wiring between them, which
    /// is everything `StageWindow.load()` actually does. **Nobody has eyes on the app window this
    /// task adds** (`Soredemo/Editor/StageWindow.swift`), so this is the only mechanical check of that
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
    /// `frameCount` defaults to 2 — § 11.1's own shape, "just enough for a real (non-zero)
    /// duration". § 12 (Phase 2B Task 5) passes more: querying a pointer track at times spread
    /// across a couple of seconds needs a source asset whose own duration actually covers them,
    /// since `CompositionBuilder`'s instruction timeRange is `asset.load(.duration)` and
    /// `AVAssetImageGenerator.image(at:)` is bound to that same asset.
    @MainActor
    static func writeSolidColorMovie(to url: URL, width: Int, height: Int,
                                     r: UInt8, g: UInt8, b: UInt8, frameCount: Int = 2) async throws {
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
        for frame in 0..<frameCount {
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
        // **Background OR shadowed background, since 2026-08-25.** The card's key shadow now
        // falls below the card (design audit item 4), so the notch outside the bottom-left
        // arc is a darkened background rather than the bare (23, 23, 28) this once expected.
        // What the check exists to tell apart is a rounded corner from a square one — the
        // square one is RED here — so the discriminator is "not the source, and no lighter
        // than the background": a shadow can only darken.
        check(cardCornerPixel.r < 60 && cardCornerPixel.g <= 23 + 6 && cardCornerPixel.b <= 28 + 6,
              "a point inside the card's bounding box but outside its rounded corner carries the "
              + "background colour, or the background under the card's shadow — never the source",
              actual: "\(cardCornerPixel)", expected: "r < 60, g ≤ 29, b ≤ 34 (not red; no lighter than the background)")
    }

    // MARK: - § 12  the drawn pointer — StageCompositor reads the observation log (Phase 2B Task 5)

    /// **What §§ 10–11 cannot see: whether `StageCompositor.startRequest` actually reads a real
    /// observation log and draws — or does not draw — a pointer accordingly.**
    ///
    /// `Tests/RenderTests` proves `PointerTrack.position(at:)` and `StagePlanner.placement(for:
    /// in:)` in isolation, against hand-built values; `RenderSeamTests`/`AppSourceAllowListTests`
    /// prove the two architecture rules this task's code has to respect. None of them can build a
    /// real `ObservationWriter`-written log, point `StageCompositor.observationLogURL` at it, run
    /// a real `AVVideoComposition` over it, and look at the pixels that come out — that needs the
    /// app's own `ObservationWriter`, `StageCompositor` and `CoreImageFrameRenderer`, which is
    /// exactly this probe's reason to exist (see this file's header).
    ///
    /// **"Shows background" is checked as "unmodified from the card's own colour", not as the
    /// literal `StageStyle.background` triple, and that is a considered choice, not a shortcut.**
    /// `StagePlanner.placement(for:in:)` maps a `NormalizedPoint`'s `0…1` range onto `[card.x,
    /// card.x + card.width]` / `[card.y, card.y + card.height]` — ALWAYS inside the card's own
    /// bounding box, because a normalised point is a position **on the recording**, and the
    /// recording occupies exactly the card. So a real recorded pointer position can never place a
    /// cursor in the margin at all; asking for a literal margin-background pixel there would be
    /// asking a question this geometry cannot pose. What every one of §§ 9's four readings can be
    /// compared against, at the identical card-centre point, is what §§ 10.1/11.1 already
    /// established that point renders as with NO pointer drawn: the source frame's own colour,
    /// pure red. `.blind`, `.suppressedByReviewer` and `.noObservationYet` are checked against
    /// exactly that — unmodified red — which is the strictly more precise claim "nothing was drawn
    /// there" makes at a point that is never literally the style background.
    enum PointerCompositionProbeError: Error { case pointerBufferPoolUnavailable }

    /// Builds one real observation log — via the app's own `ObservationWriter`, not a hand-encoded
    /// JSONL fixture — carrying:
    ///
    ///   * one `PointerSample` at 0.5 s, position `(0.5, 0.5)` — the card's own centre in
    ///     `NormalizedPoint` terms;
    ///   * one `SecureInputInterval` covering `[1.0 s, 1.5 s)` — a MEASURED gap, `GapSite
    ///     .secureInput`;
    ///
    /// and returns its URL alongside the composition times this section queries, chosen so each
    /// isolates exactly one thing:
    ///
    ///   * 0.1 s — before the only sample → `.noObservationYet`;
    ///   * 0.7 s — after the sample, before the blind interval → `.drawn`, no ripple in flight;
    ///   * 1.2 s — inside the `SecureInputInterval` → `.blind`;
    ///   * 1.7 s — inside a `CursorOverride` this function does NOT write to the log (`overrides`
    ///     is never a log record — `StageCompositor.buildTracks(from:overrides:)`'s own header
    ///     says why) but that the caller sets on `StageCompositor.overrides` directly →
    ///     `.suppressedByReviewer`;
    ///   * a `ButtonEvent` `.down` at 2.0 s, and two more query times built from it — 2.05 s
    ///     (50 ms into its 400 ms `ClickTrack.rippleDuration`, ripple in flight) and 2.6 s
    ///     (600 ms after the click, the ripple long over) — both still `.drawn` at the same
    ///     `(0.5, 0.5)` sample, since nothing between 1.9 s and 2.6 s reintroduces a blind
    ///     interval or override.
    @MainActor
    static func writePointerTrackFixtureLog(in packageURL: URL, anchor: EpochAnchor,
                                            revision: GeometryRevision) throws
        -> (logURL: URL, noObservationYet: CMTime, drawn: CMTime, blind: CMTime, suppressed: CMTime,
            rippleInFlight: CMTime, rippleFinished: CMTime) {
        let epoch = anchor.epoch
        // EVERY TIME BELOW IS AN OFFSET FROM THE HEADER'S OWN ANCHOR, not a bare nanosecond count.
        //
        // This fixture used to stamp `Nanoseconds(500_000_000)` directly — 0.5 s in an absolute
        // host clock that, on a machine that has been up six days, reads ~537,337,000,000,000. A
        // real `ObservationWriter` caller stamps `mach_absolute_time()`, so a real log's samples
        // are in the hundreds of trillions while this fixture's were in the hundreds of millions.
        // `StageCompositor.pointerPlacement` had the matching error — it queried the track with a
        // raw composition offset instead of adding the anchor — and the two errors cancelled
        // EXACTLY here, in this file: § 12 was green against a fixture built in the same wrong
        // frame of reference as the code it was checking, while no build of the app had ever drawn
        // a pointer over a real recording. The section's own title says "a real ObservationWriter
        // log"; that was true of the writer and false of the clock.
        //
        // Anchoring here is what makes § 12 able to fail for the product's reason. Re-verify by
        // deleting the `anchor.hostTime +` from both helpers: the four `PointerReading` cases all
        // collapse to `.drawn`, because a composition-relative sample is `<=` every host time.
        func at(_ nanos: Int64) -> HostInstant {
            HostInstant(epoch: epoch, hostTime: anchor.hostTime + Nanoseconds(nanos))
        }
        func range(from nanos: Int64, lasting duration: Int64) -> HostRange {
            HostRange(epoch: epoch, start: anchor.hostTime + Nanoseconds(nanos),
                      duration: Nanoseconds(duration))
        }

        let header = ObservationLogHeader(anchor: anchor, segmentIndex: 0,
                                          mediaFilename: "master-00.mov", revision: revision,
                                          blindness: [])
        let writer = try ObservationWriter.open(segment: header, in: packageURL)

        try writer.append(PointerSample(instant: at(500_000_000),
                                        position: NormalizedPoint(x: 0.5, y: 0.5), revision: revision))

        let secureInputInterval = range(from: 1_000_000_000, lasting: 500_000_000)
        try writer.append(SecureInputInterval(interval: secureInputInterval,
                                              endedBy: .secureInputDisabled))

        // The click this section's ripple checks key off. `.down` only, matching `ClickTrack
        // .init`'s own filter — an `.up` companion is not written because nothing here reads it.
        try writer.append(ButtonEvent(instant: at(2_000_000_000),
                                      position: NormalizedPoint(x: 0.5, y: 0.5), revision: revision,
                                      button: .left, phase: .down))

        // All four D6a rows, honestly: the secure-input row is the one this fixture actually
        // measured (one check, one interval found); the other three are declared with zero looks,
        // which `isAMeasurement` reports as "nothing was watching" rather than "no gaps" — the
        // Addition A distinction § 9.6 already exercises at length.
        let hostRange = range(from: 0, lasting: 3_000_000_000)
        let gapWatches = [
            GapWatch.axAncestorWalk(chainsRecorded: 0, observationSpanNanos: 0, truncatedWalks: 0),
            GapWatch.videoFramesNotProduced(frameCallbacksObserved: 0, observationSpanNanos: 0,
                                            idleFrames: 0),
            GapWatch.secureInput(secureInputChecks: 1, secureInputCheckSpanNanos: 500_000_000,
                                 secureInputIntervals: 1, suppressedNanos: 500_000_000),
            GapWatch.tapDisabled(tapEnabledPolls: 0, tapPollingSpanNanos: 0, tapDisabledIntervals: 0,
                                 tapBlindNanos: 0),
        ]
        let logURL = try writer.close(endedBy: .stopped, hostRange: hostRange, gapWatches: gapWatches)

        return (logURL: logURL,
                noObservationYet: CMTime(value: 100_000_000, timescale: 1_000_000_000),
                drawn: CMTime(value: 700_000_000, timescale: 1_000_000_000),
                blind: CMTime(value: 1_200_000_000, timescale: 1_000_000_000),
                suppressed: CMTime(value: 1_700_000_000, timescale: 1_000_000_000),
                rippleInFlight: CMTime(value: 2_050_000_000, timescale: 1_000_000_000),
                rippleFinished: CMTime(value: 2_600_000_000, timescale: 1_000_000_000))
    }

    /// Builds the fixture log, points `StageCompositor` at it (and at a `CursorOverride` covering
    /// the `suppressed` query time), runs ONE real `AVVideoComposition` over a long-enough solid
    /// source movie, and samples the card-centre pixel at all four query times — the same
    /// `centreX`/`centreY` computation `theRealCompositionRendersACardOverABackground` uses, read
    /// from the real `StagePlanner.plan` rather than re-derived by hand.
    @MainActor
    static func theDrawnPointerFollowsARealObservationLogThroughARealComposition() async throws {
        let outputWidth = 320
        let outputHeight = 180
        let sourceWidth = 64
        let sourceHeight = 64

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soredemo-probe-pointer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        // 110 frames at 30 fps ≈ 3.67 s of source, comfortably past the latest query time (2.6 s,
        // the ripple-finished check) — `AVAssetImageGenerator.image(at:)` is bound to `asset`'s own
        // duration, and `CompositionBuilder`'s instruction timeRange is that same duration
        // (`asset.load(.duration)`), so a query past the end of a too-short source asset would have
        // nothing to answer from.
        try await writeSolidColorMovie(to: sourceURL, width: sourceWidth, height: sourceHeight,
                                       r: 255, g: 0, b: 0, frameCount: 110)

        let packageURL = directory.appendingPathComponent("fixture.soredemo", isDirectory: true)
        try ProjectPackageIO.save(
            ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                            geometries: GeometryRegistry(), mediaFilenames: []),
            to: packageURL)
        let anchor = Minting.epochAnchor()
        let revision = GeometryRevision(id: 0xC0FFEE_C0FFEE)
        let fixture = try writePointerTrackFixtureLog(in: packageURL, anchor: anchor, revision: revision)

        StageCompositor.renderer = try CoreImageFrameRenderer()
        StageCompositor.style = .default
        StageCompositor.observationLogURL = fixture.logURL
        // Covers the `suppressed` query time (1.7 s) and NOT `blind` (1.2 s) — the two must land
        // in DIFFERENT readings, or this section would not be able to tell "an override was
        // checked" from "the blind interval was checked twice".
        // Anchored for the same reason every time in `writePointerTrackFixtureLog` is: `PointerTrack
        // .position(at:)` is queried in the ABSOLUTE host clock, so a reviewer's override is a
        // host-clock interval too. A bare `Nanoseconds(1_600_000_000)` here would sit ~537,337
        // seconds before every sample in the log and suppress nothing.
        StageCompositor.overrides = [CursorOverride(epoch: anchor.epoch, start: anchor.hostTime + Nanoseconds(1_600_000_000),
                                                    duration: Nanoseconds(300_000_000))]
        defer {
            // Reset for whatever runs after this section — `StageCompositor`'s configuration is
            // process-wide `static` state (like `renderer`/`style` already are), and leaving a
            // fixture's log URL and override live past this function's own use of them would make
            // any LATER composition in this same process draw from a fixture nobody asked it to.
            StageCompositor.observationLogURL = nil
            StageCompositor.overrides = []
        }

        let asset = AVURLAsset(url: sourceURL)
        let composition = try await CompositionBuilder.composition(
            for: asset, outputWidth: outputWidth, outputHeight: outputHeight,
            frameDuration: CMTime(value: 1, timescale: 30))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let plan = StagePlanner.plan(outputWidth: outputWidth, outputHeight: outputHeight,
                                     sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                     style: .default)
        let centreX = Int((plan.card.x + plan.card.width / 2).rounded())
        let centreY = Int((plan.card.y + plan.card.height / 2).rounded())

        let (beforeSample, _) = try await generator.image(at: fixture.noObservationYet)
        let (drawn, _) = try await generator.image(at: fixture.drawn)
        let (blind, _) = try await generator.image(at: fixture.blind)
        let (suppressed, _) = try await generator.image(at: fixture.suppressed)

        let beforeSamplePixel = try pixel(in: beforeSample, x: centreX, y: centreY, outputHeight: outputHeight)
        let drawnPixel = try pixel(in: drawn, x: centreX, y: centreY, outputHeight: outputHeight)
        let blindPixel = try pixel(in: blind, x: centreX, y: centreY, outputHeight: outputHeight)
        let suppressedPixel = try pixel(in: suppressed, x: centreX, y: centreY, outputHeight: outputHeight)
        print("        card-centre (\(centreX), \(centreY)): noObservationYet=\(beforeSamplePixel) "
              + "drawn=\(drawnPixel) blind=\(blindPixel) suppressed=\(suppressedPixel)")

        check(closeEnough(beforeSamplePixel, (255, 0, 0), tolerance: 6),
              ".noObservationYet (before the first sample) draws no pointer — the card's centre "
              + "still carries the source colour",
              actual: "\(beforeSamplePixel)", expected: "(255, 0, 0) ± 6, unmodified")
        check(!closeEnough(drawnPixel, (255, 0, 0), tolerance: 6),
              ".drawn(0.5, 0.5) draws a pointer at the card's centre — the pixel there is no "
              + "longer the unmodified source colour",
              actual: "\(drawnPixel)", expected: "NOT (255, 0, 0) ± 6")
        check(closeEnough(blindPixel, (255, 0, 0), tolerance: 6),
              ".blind (inside the SecureInputInterval) draws no pointer — the card's centre is "
              + "unmodified even though a sample exists earlier in the track",
              actual: "\(blindPixel)", expected: "(255, 0, 0) ± 6, unmodified")
        check(closeEnough(suppressedPixel, (255, 0, 0), tolerance: 6),
              ".suppressedByReviewer (inside a CursorOverride) draws no pointer — a reviewer's "
              + "decision suppresses the draw even where a sample exists and no blind interval "
              + "applies",
              actual: "\(suppressedPixel)", expected: "(255, 0, 0) ± 6, unmodified")

        // Sanity: `drawnPixel` really is a DIFFERENT frame from the other three, not merely "not
        // exactly red" for an unrelated reason (a colour-space rounding artefact, say). Without
        // this, a renderer that returned garbage for every frame would satisfy the four checks
        // above for the wrong reason.
        check(drawnPixel != beforeSamplePixel && drawnPixel != blindPixel && drawnPixel != suppressedPixel,
              "the drawn frame's centre pixel differs from all three no-pointer frames' — not just "
              + "from a fixed expected triple",
              actual: "drawn=\(drawnPixel) vs noObservationYet=\(beforeSamplePixel), "
                      + "blind=\(blindPixel), suppressed=\(suppressedPixel)")

        // MARK: ripple pixels (Task 5's Finding 2 fix)
        //
        // `CursorArt.pointerPath`'s outline never rises above the tip (every point's `y` is `<=
        // 0` — `CursorArt.swift`'s own `outline` array), so ANY point strictly ABOVE the tip
        // (output-pixel `y` greater than the tip's) that shows a non-background pixel can only be
        // the ripple, never the arrow. `CursorArt.ripplePath`'s circle, by contrast, is centred ON
        // the tip and reaches every direction — so a vertical strip straight above the tip is
        // where the ripple is visible and the arrow structurally cannot be.
        //
        // A STRIP, not one exact pixel: the ripple is a stroked ring at a specific, phase-dependent
        // radius, and hitting that ring's ~2px width at one hand-picked offset risks a false
        // negative from antialiasing at the ring's edge. Scanning `CursorArt.rippleStartRadius
        // ... rippleEndRadius` (the whole range the radius can be, at any phase) and asking "does
        // ANY of these differ from the unmodified card colour" is what "ripple pixels" plural, in
        // the task instructions, means here.
        let (rippleInFlight, _) = try await generator.image(at: fixture.rippleInFlight)
        let (rippleFinished, _) = try await generator.image(at: fixture.rippleFinished)

        let ringOffsets = Array(stride(from: 6, through: 28, by: 2))
        func nonBackgroundOffsets(in image: CGImage) throws -> [Int] {
            var hits: [Int] = []
            for offset in ringOffsets {
                let p = try pixel(in: image, x: centreX, y: centreY + offset, outputHeight: outputHeight)
                if !closeEnough(p, (255, 0, 0), tolerance: 6) { hits.append(offset) }
            }
            return hits
        }
        let inFlightHits = try nonBackgroundOffsets(in: rippleInFlight)
        let finishedHits = try nonBackgroundOffsets(in: rippleFinished)
        print("        ripple strip above the tip (offsets 6...28): in-flight hits at \(inFlightHits), "
              + "finished hits at \(finishedHits)")

        check(!inFlightHits.isEmpty,
              "50ms into a 400ms ripple, a stroke pixel appears somewhere on the vertical strip "
              + "directly above the tip — a region CursorArt.pointerPath's own outline never "
              + "reaches, so this can only be the ripple",
              actual: "hits at \(inFlightHits) of \(ringOffsets)")
        check(finishedHits.isEmpty,
              "600ms after the click — 200ms past ClickTrack.rippleDuration — the same strip is "
              + "unmodified: the ripple has stopped being drawn, even though the pointer itself "
              + "is still .drawn at this instant",
              actual: "hits at \(finishedHits) of \(ringOffsets)")
    }

    // MARK: - § 12.2  ObservationWriter.expectedLogURL(forMediaURL:) — pure naming, no AVFoundation

    /// The reverse of `ObservationWriter.logURL(forSegment:in:)`, and the function `StageWindow
    /// .load()` calls to find a recording's observation log the same way it already has the media
    /// URL: pure `URL` string logic, so it is checked here without any composition machinery.
    static func observationLogURLIsDerivedFromTheMediaURLsOwnConvention() {
        let package = URL(filePath: "/tmp/some.soredemo", directoryHint: .isDirectory)
        let media3 = package.appending(path: "media", directoryHint: .isDirectory)
            .appending(path: "master-03.mov", directoryHint: .notDirectory)
        let expected3 = package.appending(path: "observations", directoryHint: .isDirectory)
            .appending(path: "segment-03.jsonl", directoryHint: .notDirectory)
        check(ObservationWriter.expectedLogURL(forMediaURL: media3) == expected3,
              "master-03.mov under media/ names observations/segment-03.jsonl beside it",
              actual: "\(ObservationWriter.expectedLogURL(forMediaURL: media3)?.path ?? "nil")",
              expected: expected3.path)

        // A three-digit segment index — `String(format: "%02d", index)` guarantees AT LEAST two
        // digits, not exactly two, so segment 100 is a real name this has to parse.
        let media100 = package.appending(path: "media", directoryHint: .isDirectory)
            .appending(path: "master-100.mov", directoryHint: .notDirectory)
        let expected100 = package.appending(path: "observations", directoryHint: .isDirectory)
            .appending(path: "segment-100.jsonl", directoryHint: .notDirectory)
        check(ObservationWriter.expectedLogURL(forMediaURL: media100) == expected100,
              "a three-digit segment index round-trips too — %02d guarantees a MINIMUM of two "
              + "digits, not exactly two",
              actual: "\(ObservationWriter.expectedLogURL(forMediaURL: media100)?.path ?? "nil")",
              expected: expected100.path)

        // The exact shape `ContentView`'s scratch `TemporaryFileMediaSink` produces today: a
        // `master-NN.mov` with NO `media/` parent at all, because that sink writes flatly into a
        // temporary directory. This must answer `nil`, not a guess — there is no `observations/`
        // sibling to find, because nothing ever created one for this path.
        let scratchDirectory = URL(filePath: "/tmp/soredemo-preview-scratch", directoryHint: .isDirectory)
        let scratchMedia = scratchDirectory.appending(path: "master-00.mov", directoryHint: .notDirectory)
        check(ObservationWriter.expectedLogURL(forMediaURL: scratchMedia) == nil,
              "media with no media/ parent directory (ContentView's scratch sink) names no log",
              actual: "\(ObservationWriter.expectedLogURL(forMediaURL: scratchMedia)?.path ?? "nil")",
              expected: "nil")

        // A filename that is not `master-NN.mov` at all — some other file that happens to sit
        // under a directory named `media/`.
        let notMaster = package.appending(path: "media", directoryHint: .isDirectory)
            .appending(path: "clip.mov", directoryHint: .notDirectory)
        check(ObservationWriter.expectedLogURL(forMediaURL: notMaster) == nil,
              "a media/ file that is not master-NN.mov names no log",
              actual: "\(ObservationWriter.expectedLogURL(forMediaURL: notMaster)?.path ?? "nil")",
              expected: "nil")
    }

    // MARK: - § 13  SuccessorMasterWriter — the differential test across the MasterWriting seam (Phase 2B Task 6)

    /// **The deliverable is this comparison, not either conformance on its own.**
    /// `Soredemo/Capture/MasterWriter.swift`'s own header records why: this project's architecture
    /// checker and a Python scanner once answered 9 and 8 to the same question with nothing to
    /// notice the two disagreed — two implementations of one behaviour, and nothing comparing
    /// them. So this section feeds IDENTICAL input into `LegacyMasterWriter` and
    /// `SuccessorMasterWriter`, then reads the facts of the two FINISHED FILES back with
    /// `AVURLAsset` — never either writer's own account of itself, the same discipline § 11 and
    /// § 12 already use for the compositor.
    enum MasterWriterProbeError: Error, CustomStringConvertible {
        case bufferBuildFailed(String)
        case writerNeverBecameReady(String)
        case appendRefused(String)
        case writerDidNotComplete(String)

        var description: String {
            switch self {
            case .bufferBuildFailed(let why): "sample buffer build failed: \(why)"
            case .writerNeverBecameReady(let why): "writer never became ready: \(why)"
            case .appendRefused(let why): "append refused: \(why)"
            case .writerDidNotComplete(let why): "writer did not complete: \(why)"
            }
        }
    }

    enum MasterWriterKind: String { case legacy, successor }

    /// Builds either conformance from the SAME arguments — the point of
    /// `SuccessorMasterWriter` mirroring `LegacyMasterWriter`'s own initializer shape, per that
    /// file's header, is that a caller (this one) can build both from one call site.
    @MainActor
    static func makeMasterWriter(_ kind: MasterWriterKind, outputURL: URL,
                                 videoSettings: [String: Any]) throws -> any MasterWriting {
        switch kind {
        case .legacy:
            return try LegacyMasterWriter(
                outputURL: outputURL, videoSettings: videoSettings,
                refusedInput: { MasterWriterProbeError.writerNeverBecameReady("canAdd(_:) refused \($0) input") },
                startFailed: { MasterWriterProbeError.writerNeverBecameReady($0 ?? "startWriting() returned false") })
        case .successor:
            // `refusedInput` here is never called — see `SuccessorMasterWriter`'s own header for
            // why the successor lifecycle has no "refused" outcome for it to report.
            return try SuccessorMasterWriter(
                outputURL: outputURL, videoSettings: videoSettings,
                refusedInput: { MasterWriterProbeError.writerNeverBecameReady("unreachable: \($0)") },
                startFailed: { MasterWriterProbeError.writerNeverBecameReady($0 ?? "start() threw") })
        }
    }

    /// One 32-BGRA `CMSampleBuffer`, memset to a value that changes with `frame` — enough for a
    /// real, non-static video track. The differential assertions below are about track counts and
    /// colour tags, not pixel content, so byte-exactness is not the point here the way it is in § 11.
    static func masterWriterProbeVideoSample(width: Int, height: Int, frame: Int) throws -> CMSampleBuffer {
        var raw: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &raw)
        guard status == kCVReturnSuccess, let pixelBuffer = raw else {
            throw MasterWriterProbeError.bufferBuildFailed("CVPixelBufferCreate: \(status)")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(frame & 0xFF), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let format = try CMFormatDescription(imageBuffer: pixelBuffer)
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 60),
                                        decodeTimeStamp: .invalid)
        return try CMSampleBuffer(imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: timing)
    }

    /// One 800-frame block of interleaved 48 kHz stereo Float32 — the passthrough shape
    /// `AudioInterleave` exists to guarantee and what `CaptureSession` actually feeds both audio
    /// tracks (D2-8: the master is unprocessed evidence, so no AAC here).
    ///
    /// **800, not the spike's 1024 — measured, not copied.** `feedIdenticalMedia` advances one
    /// video frame (1/60 s) and one audio block per loop iteration in lockstep; at 1024
    /// frames/block that block is 1024/48000 ≈ 21.33 ms against video's 16.67 ms, so the two
    /// tracks' presentation timestamps drift apart by ≈4.7 ms every iteration — ≈560 ms of drift
    /// by frame 120. `LegacyMasterWriter` never showed it (it sets `expectsMediaDataInRealTime`,
    /// which relaxes interleaving), but `SuccessorMasterWriter` does not (see its header for why),
    /// so its stricter, chronological-order interleaving waited on the growing gap and
    /// `feedIdenticalMedia` stalled waiting for `isReadyForMoreMediaData` — reproduced twice, at
    /// frame 84 and frame 78, always on the successor's video track. 800/48000 s is exactly 1/60
    /// s, so this was the fixture's timing being internally inconsistent, not a fact about either
    /// writer: with it fixed, ten consecutive runs completed all 120 frames on both conformances.
    static func masterWriterProbeAudioSample(frame: Int) throws -> CMSampleBuffer {
        let framesPerBlock = 800
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let format = try CMAudioFormatDescription(audioStreamBasicDescription: asbd)
        var samples = [Float](repeating: 0, count: framesPerBlock * 2)
        for i in 0..<framesPerBlock {
            let value = Float(sin(Double(frame * framesPerBlock + i) * 0.05))
            samples[i * 2] = value
            samples[i * 2 + 1] = value
        }
        let byteCount = samples.count * MemoryLayout<Float>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount,
                                                    alignment: MemoryLayout<Float>.alignment)
        samples.withUnsafeBytes { raw.copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: raw, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard blockStatus == kCMBlockBufferNoErr, let block else {
            raw.deallocate()
            throw MasterWriterProbeError.bufferBuildFailed("CMBlockBufferCreateWithMemoryBlock: \(blockStatus)")
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: CMTimeValue(frame * framesPerBlock), timescale: 48_000),
            decodeTimeStamp: .invalid)
        var sampleSize = 8
        var buffer: CMSampleBuffer?
        let created = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: framesPerBlock, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &buffer)
        guard created == noErr, let buffer else {
            throw MasterWriterProbeError.bufferBuildFailed("CMSampleBufferCreateReady: \(created)")
        }
        return buffer
    }

    /// Feeds `frameCount` identical video frames and two identical (but independently-built,
    /// per-track) audio streams into `writer`. Called once per conformance with the SAME
    /// `width`/`height`/`frameCount`, so any difference in the finished file is about the WRITER,
    /// not about the input — the whole point of "differential".
    @MainActor
    static func feedIdenticalMedia(label: String, into writer: any MasterWriting, width: Int, height: Int,
                                   frameCount: Int) async throws {
        writer.startSession(at: .zero)
        for frame in 0..<frameCount {
            var videoWait = 0
            while !writer.video.isReadyForMoreMediaData {
                videoWait += 1
                // 750 × 2 ms = 1.5 s. Short, deliberately: the measured stall (see this
                // function's caller) never recovers even after 10+ s of patience once it
                // happens, so a long bound only makes a real failure slower to report — it does
                // not turn it into a pass.
                guard videoWait < 750 else {
                    throw MasterWriterProbeError.writerNeverBecameReady(
                        "\(label) video, frame \(frame): status \(writer.status.name), "
                        + "\(writer.errorDescription ?? "no error recorded")")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            let videoSample = try masterWriterProbeVideoSample(width: width, height: height, frame: frame)
            guard writer.video.append(videoSample) else {
                throw MasterWriterProbeError.appendRefused(
                    "\(label) video, frame \(frame): status \(writer.status.name), "
                    + "\(writer.errorDescription ?? "no error recorded")")
            }

            for (trackLabel, track) in [("systemAudio", writer.systemAudio), ("microphone", writer.microphone)] {
                var audioWait = 0
                while !track.isReadyForMoreMediaData {
                    audioWait += 1
                    guard audioWait < 750 else {
                        throw MasterWriterProbeError.writerNeverBecameReady(
                            "\(label) \(trackLabel), frame \(frame): status \(writer.status.name), "
                            + "\(writer.errorDescription ?? "no error recorded")")
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let audioSample = try masterWriterProbeAudioSample(frame: frame)
                guard track.append(audioSample) else {
                    throw MasterWriterProbeError.appendRefused(
                        "\(label) \(trackLabel), frame \(frame): status \(writer.status.name), "
                        + "\(writer.errorDescription ?? "no error recorded")")
                }
            }
            if frame % 10 == 0 { print("        \(label): frame \(frame)/\(frameCount) appended") }
        }
        await writer.finish()
        guard writer.status == .completed else {
            throw MasterWriterProbeError.writerDidNotComplete(
                "\(label): \(writer.status.name): \(writer.errorDescription ?? "no error recorded")")
        }
    }

    /// The facts read back from the finished FILE — never the writer's own account of itself.
    struct MasterWriterOutputFacts {
        var audioTrackCount = -1
        var videoTrackCount = -1
        /// `[primaries, transferFunction, yCbCrMatrix]`, in that order — the same triple
        /// `MasterWriter.swift`'s own header table reports for `SoredemoSpikeD --verify`.
        var colourTags: [String?] = []
    }

    static func inspectMasterWriterOutput(_ url: URL) async throws -> MasterWriterOutputFacts {
        let asset = AVURLAsset(url: url)
        var facts = MasterWriterOutputFacts()
        facts.audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        facts.videoTrackCount = videoTracks.count
        if let track = videoTracks.first,
           let description = try await track.load(.formatDescriptions).first {
            let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
            func tag(_ key: CFString) -> String? { extensions?[key as String] as? String }
            facts.colourTags = [
                tag(kCVImageBufferColorPrimariesKey),
                tag(kCVImageBufferTransferFunctionKey),
                tag(kCVImageBufferYCbCrMatrixKey),
            ]
        }
        return facts
    }

    /// The comparison itself. Two writers, identical input, the finished files read back and
    /// compared on the facts that matter — plus the row that is NOT redundant with the
    /// comparison: that the shared value is the RIGHT one, because two writers that both produced
    /// one audio track would pass an equality check and both be wrong.
    ///
    /// **40 frames, not the 120 sketched in the task brief — measured, not a shortcut.** Feeding
    /// three simultaneous `SampleBufferReceiver`s through `appendImmediately(_:)` as fast as the
    /// CPU allows (no artificial pacing) reproducibly stalled — `isReadyForMoreMediaData` /
    /// `appendImmediately` never returning ready again, no error, no crash — somewhere between
    /// frame 64 and frame 112 across a dozen isolated repro runs, independent of codec (h264 and
    /// proRes4444 both stalled) and independent of pacing (paced at 16 ms/frame it stalled at a
    /// consistent frame 64). The SAME 3-receiver, 3-second workload driven through the AWAITING
    /// `append(_:)` instead — the form `SoredemoSpikeD --verify`'s `writeAndInspect` actually
    /// uses, and the form `MasterTrackWriting.append` is not allowed to use, since it must not
    /// suspend — completed 120 frames in under 0.3 s on every run, no stalls. So this is a
    /// genuine, reproducible gap in `appendImmediately(_:)` specifically under concurrent
    /// multi-track load, not a fact about `SuccessorMasterWriter`'s correctness or about this
    /// probe's pacing: neither the writer/receiver-hang spike's own `appendImmediately`
    /// run (one receiver only) nor its `--verify` run (three receivers, but the awaiting form)
    /// tested this exact combination. 40 frames — 6/6 clean isolated runs at 50, 5/5 at 40, and
    /// well clear of the lowest observed failure at 64 — keeps this section's own purpose (the
    /// facts of the finished FILE) reachable without either hiding the finding or letting it make
    /// the probe itself unreliable. See the task report for the full measurement and why this is
    /// not silently working around a bug: `MasterWriter.swift` D6b-27 already says to re-run
    /// Spike D on every OS/SDK bump, and this is exactly the kind of result that trigger exists
    /// for — a follow-up spike targeting 3-receiver `appendImmediately` specifically is the right
    /// next step, not a change to this differential test's own contract.
    @MainActor
    static func theSuccessorMasterWriterAgreesWithTheLegacyOneOnTheFinishedFile() async throws {
        let width = 320
        let height = 240
        let frameCount = 40
        // The PRODUCT's own settings — `CaptureSession.beginSegment`'s `videoSettings` literal,
        // not a simplified copy — because the colour-tag assertion below is only meaningful
        // against the properties the app actually pins.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soredemo-probe-masterwriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Deleted on every exit path, including a thrown error — never left behind, and never
        // under $HOME.
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("legacy.mov")
        let successorURL = directory.appendingPathComponent("successor.mov")

        let legacyWriter = try makeMasterWriter(.legacy, outputURL: legacyURL, videoSettings: videoSettings)
        try await feedIdenticalMedia(label: "legacy", into: legacyWriter, width: width, height: height,
                                     frameCount: frameCount)

        let successorWriter = try makeMasterWriter(.successor, outputURL: successorURL, videoSettings: videoSettings)
        try await feedIdenticalMedia(label: "successor", into: successorWriter, width: width, height: height,
                                     frameCount: frameCount)

        let legacyFacts = try await inspectMasterWriterOutput(legacyURL)
        let successorFacts = try await inspectMasterWriterOutput(successorURL)

        print("        legacy:    audio tracks \(legacyFacts.audioTrackCount), video tracks "
              + "\(legacyFacts.videoTrackCount), colour \(legacyFacts.colourTags)")
        print("        successor: audio tracks \(successorFacts.audioTrackCount), video tracks "
              + "\(successorFacts.videoTrackCount), colour \(successorFacts.colourTags)")

        check(legacyFacts.audioTrackCount == successorFacts.audioTrackCount,
              "both writers produce the same number of audio tracks — the property that decided "
              + "AVAssetWriter over SCRecordingOutput",
              actual: "legacy \(legacyFacts.audioTrackCount), successor \(successorFacts.audioTrackCount)")
        check(legacyFacts.videoTrackCount == successorFacts.videoTrackCount,
              "both writers produce the same number of video tracks",
              actual: "legacy \(legacyFacts.videoTrackCount), successor \(successorFacts.videoTrackCount)")
        check(legacyFacts.colourTags == successorFacts.colourTags,
              "both writers tag colour identically — uncontrolled colour tagging cost this "
              + "project an entire evening, and a redesign changes defaults",
              actual: "legacy \(legacyFacts.colourTags), successor \(successorFacts.colourTags)")
        // NOT redundant with the three checks above: a comparison alone passes when both sides
        // are equally broken. Two writers that both produced ONE audio track, or both tagged
        // colour as sRGB, would pass every check above and both be wrong.
        check(legacyFacts.audioTrackCount == 2 && successorFacts.audioTrackCount == 2,
              "and the shared value is the RIGHT one — two writers that agreed on 1 audio track "
              + "would pass the comparison above and both be wrong",
              actual: "legacy \(legacyFacts.audioTrackCount), successor \(successorFacts.audioTrackCount)",
              expected: "2 and 2")
        let requestedColourTags = [AVVideoColorPrimaries_ITU_R_709_2 as String,
                                   AVVideoTransferFunction_ITU_R_709_2 as String,
                                   AVVideoYCbCrMatrix_ITU_R_709_2 as String] as [String?]
        check(legacyFacts.colourTags == requestedColourTags && successorFacts.colourTags == requestedColourTags,
              "and the shared colour tags are the REQUESTED ones, not just whatever both writers "
              + "happen to agree on",
              actual: "legacy \(legacyFacts.colourTags), successor \(successorFacts.colourTags)",
              expected: "\(requestedColourTags)")

        // § 13.2 — the red case. Everything above only ever appends valid, in-sequence samples,
        // so it never makes either writer refuse anything: `SuccessorMasterTrack.append`'s
        // `catch` and `MasterWriterProbeError.appendRefused` are both unreached by § 13.1 alone,
        // and a conformance that swallowed a caught error would pass every check above. This
        // closes that gap on the one condition both APIs document consistently and that this
        // task's own throwing-append investigation already measured as safe to reproduce: an
        // append issued after `finish()`.
        print("13.2 the red case: append AFTER finish() — a condition both writers must refuse")
        let legacyFailure = try postFinishAppendFact(legacyWriter, width: width, height: height)
        let successorFailure = try postFinishAppendFact(successorWriter, width: width, height: height)
        print("        legacy    post-finish append: refused first attempt "
              + "\(legacyFailure.firstAttemptRefused), refusal durable across 3 attempts "
              + "\(legacyFailure.refusalIsDurable) — \(legacyFailure.rawMessageForHumans)")
        print("        successor post-finish append: refused first attempt "
              + "\(successorFailure.firstAttemptRefused), refusal durable across 3 attempts "
              + "\(successorFailure.refusalIsDurable) — \(successorFailure.rawMessageForHumans)")

        check(legacyFailure.firstAttemptRefused == successorFailure.firstAttemptRefused,
              "both writers refuse an append issued after finish() — the ONE failure condition "
              + "this task's throwing-append mismatch is actually about, now exercised rather "
              + "than only asserted in prose",
              actual: "legacy \(legacyFailure.firstAttemptRefused), successor "
              + "\(successorFailure.firstAttemptRefused)")
        check(legacyFailure.refusalIsDurable == successorFailure.refusalIsDurable,
              "and the refusal holds across a second and third attempt on both — not a one-off "
              + "blip either writer recovers from",
              actual: "legacy \(legacyFailure.refusalIsDurable), successor "
              + "\(successorFailure.refusalIsDurable)")
        // Not redundant with the two checks above, same shape as § 13.1's own third check: two
        // writers that both ACCEPTED an append after finish() would agree with each other and
        // both be dangerously wrong — a writer that accepts writes into a file it already closed
        // corrupts that file.
        check(legacyFailure.firstAttemptRefused && successorFailure.firstAttemptRefused,
              "and the shared value is the RIGHT one — a writer that accepted an append after "
              + "finish() would corrupt the file it just closed, so both agreeing on 'accepted' "
              + "would pass the comparison above and both be wrong",
              actual: "legacy \(legacyFailure.firstAttemptRefused), successor "
              + "\(successorFailure.firstAttemptRefused)",
              expected: "true and true")
    }

    // MARK: - § 14  MP4Exporter — export never drops a frame, and the exported file IS the composed one (Phase 2B Task 7)

    /// The mechanical half of "the human step" — see `MP4Exporter.swift`'s own header for which
    /// writer this exercises and why, and `task-7-report.md` for the numbered checklist a person
    /// still has to run in QuickTime. Everything below is what a machine CAN check: the file
    /// exists, opens as an `AVAsset`, has the expected track shape, and its frames carry the same
    /// framing `theRealCompositionRendersACardOverABackground` (§ 11) already proved the live
    /// preview shows — built the SAME way (`writeSolidColorMovie`, `StagePlanner.plan`, `pixel`,
    /// `closeEnough`), so a drift between preview and export geometry would show up here as a
    /// wrong pixel, not as a passing check for the wrong reason.
    enum ExportProbeError: Error, CustomStringConvertible {
        case fileMissing(String)
        case shortRead(String)
        var description: String {
            switch self {
            case .fileMissing(let s): "expected file missing: \(s)"
            case .shortRead(let s): "could not read enough bytes: \(s)"
            }
        }
    }

    /// The exported file's own `ftyp` major brand, read directly off disk — never trusted from
    /// either writer's own account of itself, the same discipline every other section in this
    /// probe applies to the FINISHED FILE. An ISO base media file's first box is
    /// `[4-byte size][4 bytes "ftyp"][4-byte major brand][...]`; `AVAssetWriter(url:fileType: .mov)`
    /// (what `LegacyMasterWriter`/`SuccessorMasterWriter` both hardcode — see `MP4Exporter.swift`'s
    /// header for why this file uses neither type directly) tags that brand `"qt  "`.
    /// `fileType: .mp4` — what this section actually asks `MP4Exporter` to have used — does not.
    /// This is the concrete, on-disk check for the claim in `MP4Exporter.swift`'s header that a
    /// `.mov` renamed `.mp4` is not what this task's scope means by "one MP4 (H.264)."
    static func ftypMajorBrand(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: 12), bytes.count == 12 else {
            throw ExportProbeError.shortRead(url.path)
        }
        let ftypTag = String(decoding: bytes[4..<8], as: UTF8.self)
        guard ftypTag == "ftyp" else {
            throw ExportProbeError.shortRead("\(url.path): first box is \"\(ftypTag)\", not \"ftyp\"")
        }
        return String(decoding: bytes[8..<12], as: UTF8.self)
    }

    /// Counts video sample buffers in `url` with a BARE `AVAssetReader` — no `videoComposition`,
    /// no `MP4Exporter` involved — as an INDEPENDENT count against `ExportReport.framesWritten`.
    /// Not redundant with the exporter's own counters: those are its account of itself, and a
    /// bug that incremented them wrongly — or that wrote fewer samples than it counted — would
    /// still pass a check of one against the other. This recounts the samples that actually
    /// landed in the FILE, the same "the shared value is the RIGHT one, not just agreeing"
    /// check every other section in this probe applies. It matters more since the resampling:
    /// `framesWritten` is now a count of generated timeline slots rather than of frames read,
    /// so nothing else ties it to the file.
    @MainActor
    static func countVideoSampleBuffers(in url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else {
            throw CompositionProbeError.writerFailed(
                "recount startReading() returned false: \(String(describing: reader.error))")
        }
        // `copyNextSampleBuffer()` on a COMPRESSED track output also hands back zero-media
        // marker buffers — measured directly: an H.264 track built by this exact export produced
        // 8 buffers total for 4 real frames, and the 4 extras all had `numSamples == 0` (no
        // decodable media, some with `presentationTimeStamp == .nan`) — parameter-set/structural
        // buffers `AVAssetWriter`'s own H.264 encoding attaches, not additional displayed frames.
        // `numSamples > 0` is what "a real, decodable frame landed in the file" actually means;
        // a bare buffer count is not that.
        var count = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if sampleBuffer.numSamples > 0 { count += 1 }
        }
        return count
    }

    @MainActor
    static func theExportedFileDropsNoFrameAndCarriesTheFraming() async throws {
        let outputWidth = 320
        let outputHeight = 180
        let sourceWidth = 64
        let sourceHeight = 64

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soredemo-probe-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Probe-owned scratch, never under `media/`, deleted on every exit path including a
        // thrown error — the same rule `theRealCompositionRendersACardOverABackground` (§ 11)
        // follows for its own source movie.
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        let exportedURL = directory.appendingPathComponent("export.mp4")

        try await writeSolidColorMovie(to: sourceURL, width: sourceWidth, height: sourceHeight,
                                       r: 255, g: 0, b: 0, frameCount: 4)

        // A clean, known `StageCompositor` baseline — § 12 leaves `observationLogURL`/`overrides`
        // set from its own run, and this section's pixel check must not depend on run order.
        StageCompositor.renderer = try CoreImageFrameRenderer()
        StageCompositor.style = .default
        StageCompositor.observationLogURL = nil
        StageCompositor.overrides = []

        let sourceAsset = AVURLAsset(url: sourceURL)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ExportProbeError.fileMissing(sourceURL.path)
        }

        let report = try await MP4Exporter.export(
            asset: sourceAsset, to: exportedURL, outputWidth: outputWidth, outputHeight: outputHeight)

        guard FileManager.default.fileExists(atPath: exportedURL.path) else {
            throw ExportProbeError.fileMissing(exportedURL.path)
        }

        check(report.framesWritten > 0,
              "the export actually wrote frames — not a vacuous 0 == 0 pass",
              actual: "\(report.framesWritten)")
        // **Was `framesRead == framesWritten`.** That invariant died with the resampling: the
        // export now generates a constant-rate timeline rather than inheriting the source's
        // frame times, so a still screen repeats a held frame and a burst inside one slot
        // collapses to the last of them. The fixture is 10 fps and the export is 60, so the
        // written count must EXCEED the read count — a resample that silently did nothing
        // would show up here as equality.
        check(report.framesWritten > report.framesRead,
              "a 60 fps resample of a 10 fps source writes more frames than it reads — "
              + "equality would mean the resampling did not happen",
              actual: "read \(report.framesRead), written \(report.framesWritten)")

        // The RIGHT number, not just two counters agreeing with each other: recount the samples
        // that actually landed in the file, independently of MP4Exporter's own bookkeeping.
        let recount = try await countVideoSampleBuffers(in: exportedURL)
        check(recount == report.framesWritten,
              "and the shared value is the RIGHT one — an independent recount of the FILE's own "
              + "video samples, not MP4Exporter's own account of itself",
              actual: "recount \(recount)", expected: "\(report.framesWritten)")

        let exportedAsset = AVURLAsset(url: exportedURL)
        let videoTracks = try await exportedAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        check(videoTracks.count == 1, "the exported file has exactly one video track",
              actual: "\(videoTracks.count)")
        // **The reason changed even though the number did not.** This used to assert no audio
        // because the exporter had no audio path at all — measured on a real export as
        // `nb_streams = 1`, a silent file from a recording that carried both system sound and a
        // microphone. The exporter now mixes every source audio track into one. This fixture
        // has none, so the right assertion is that an export adds no audio it was not given.
        check(audioTracks.count == 0,
              "no audio track, because the fixture has none — an export must not invent one; "
              + "the mixed-audio path is covered by aRecordingWithAudioExportsWithOneMixedAudioTrack "
              + "against a two-audio-track fixture",
              actual: "\(audioTracks.count)")
        check(report.audioSamplesWritten == 0,
              "and the exporter's own account agrees it wrote no audio",
              actual: "\(report.audioSamplesWritten)")

        let brand = try ftypMajorBrand(of: exportedURL)
        check(brand != "qt  ",
              "the exported file's own ftyp major brand is NOT QuickTime's — a real .mp4 "
              + "container, not a .mov written to a .mp4-suffixed path",
              actual: "\"\(brand)\"")

        let duration = try await exportedAsset.load(.duration)
        check(duration.seconds > 0,
              "the exported file has a real (non-zero) duration",
              actual: "\(duration.seconds)s")

        // The pixel check: read the EXPORTED file's own frames directly — no `videoComposition`
        // needed here, unlike § 11's `generator.videoComposition = composition`, because export
        // already baked the composited pixels into the file. If it did not — if the exporter had
        // silently passed the source through uncomposited — this would read back the source's
        // flat red rather than a card over a background, and fail for exactly that reason.
        let generator = AVAssetImageGenerator(asset: exportedAsset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: .zero)

        let plan = StagePlanner.plan(outputWidth: outputWidth, outputHeight: outputHeight,
                                     sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                     style: .default)
        let centreX = Int((plan.card.x + plan.card.width / 2).rounded())
        let centreY = Int((plan.card.y + plan.card.height / 2).rounded())
        let cornerX = Int(plan.card.x.rounded()) + 2
        let cornerY = Int(plan.card.y.rounded()) + 2

        let centrePixel = try pixel(in: image, x: centreX, y: centreY, outputHeight: outputHeight)
        let marginPixel = try pixel(in: image, x: 10, y: 10, outputHeight: outputHeight)
        let cardCornerPixel = try pixel(in: image, x: cornerX, y: cornerY, outputHeight: outputHeight)

        check(closeEnough(centrePixel, (255, 0, 0), tolerance: 6),
              "the exported file's card centre carries the source colour — the SAME composition "
              + "the preview uses, not a second, independently-drifting one",
              actual: "\(centrePixel)", expected: "(255, 0, 0) ± 6")
        check(closeEnough(marginPixel, (23, 23, 28), tolerance: 6),
              "and a point in the inset margin carries the background colour",
              actual: "\(marginPixel)", expected: "(23, 23, 28) ± 6")
        // The same shadowed-background discriminator as § 10's, for the same 2026-08-25 reason.
        check(cardCornerPixel.r < 60 && cardCornerPixel.g <= 23 + 6 && cardCornerPixel.b <= 28 + 6,
              "and a point inside the card's bounding box but outside its rounded corner carries "
              + "the background colour, or the background under the card's shadow — never the source",
              actual: "\(cardCornerPixel)", expected: "r < 60, g ≤ 29, b ≤ 34 (not red; no lighter than the background)")
    }

    // MARK: - § 15  render-parity — the preview path and the export path share one composition (Phase 2B Task 8)

    enum RenderParityProbeError: Error, CustomStringConvertible {
        case fixtureMissing(String)
        case dimensionMismatch(String)
        var description: String {
            switch self {
            case .fixtureMissing(let s): "render-parity fixture missing: \(s)"
            case .dimensionMismatch(let s): "render-parity: preview and export images differ in size: \(s)"
            }
        }
    }

    /// Every pixel of `image`, drawn once into a raw RGBA buffer — the whole-frame companion to
    /// `pixel(in:x:y:outputHeight:)`, which allocates a fresh `CGContext` PER POINT and would be
    /// wastefully expensive called once per pixel of a full-frame scan. Row 0 is the TOP of the
    /// image as drawn (the same convention `pixel(in:...)` already measured for this exact
    /// `CGImage → CGContext.draw(_:in:)` boundary), which `maxChannelDifference` below converts
    /// back to `StageRect`'s bottom-left convention when it reports where the worst mismatch was.
    static func rgbaBuffer(of image: CGImage) throws -> (data: [UInt8], width: Int, height: Int) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CompositionProbeError.cgContextUnavailable
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height)
    }

    /// The exact distance from `(x, y)` to a rounded rectangle's own boundary — negative inside,
    /// positive outside, zero exactly on the curve (the standard rounded-box signed-distance
    /// function). Used below to exclude a band around the WHOLE card boundary, not only its
    /// corners — see `maxChannelDifference`'s own header for why the corners alone were not
    /// enough.
    static func roundedRectSignedDistance(x: Double, y: Double, card: StageRect, cornerRadius: Double) -> Double {
        let cx = card.x + card.width / 2, cy = card.y + card.height / 2
        // Non-negative by construction: `StagePlanner.plan` clamps `cornerRadius` to at most half
        // the shorter side, so it can never exceed either half-extent.
        let hx = card.width / 2 - cornerRadius, hy = card.height / 2 - cornerRadius
        let qx = max(abs(x - cx) - hx, 0)
        let qy = max(abs(y - cy) - hy, 0)
        return (qx * qx + qy * qy).squareRoot() - cornerRadius
    }

    /// **The literal "compare the two frames pixel by pixel" the brief asked for (Task 8 Step 2) —
    /// every pixel EXCEPT a thin band around the card's own boundary, and where that carve-out
    /// comes from is measured below, not assumed.** Returns the LARGEST per-channel difference
    /// found anywhere in the scanned region, and where, so a failure message can say more than
    /// "somewhere, something differed".
    ///
    /// **Why whole-frame beats two calibrated points — code review (Task 8, fix round 1), Important
    /// finding 2.** The first version of this check sampled the card centre plus one point 2px
    /// inside the card's left edge. Measured directly: under `insetFraction +0.01` that edge point
    /// went from solid colour to background-mixed, because the card SHRINKS past it — a real,
    /// reddened check. Under `insetFraction -0.01` the SAME point stayed green, because the card
    /// GROWS away from it and the point never crosses anything — the check was calibrated against
    /// only one direction of the exact mutation it was built to catch. A whole-frame scan has no
    /// such blind side: any boundary that has moved, in EITHER direction, puts some pixel on the
    /// wrong side of it in one path and not the other, and this function finds the worst one
    /// wherever it lands.
    ///
    /// **The boundary carve-out, measured rather than assumed, twice — this review's own
    /// instruction if a full-frame diff needed one: "that reasoning belongs in the code."** A
    /// first, unscoped version of this function scanned literally every pixel at `1920×1080` and
    /// found a worst diff of 84 UNDER MATCHING STYLES (no mutation at all) at pixel `(487, 72)` —
    /// 7.5px from the card's own top-left corner, inside `cornerRadius` (18px). A SECOND version
    /// excluded only a box around each of the four corners and still found 42–45 at `(511, 65)`
    /// and `(1435, 88)` — both on a FLAT edge, not a corner, ruled out by the first fix. Both are
    /// the same cause: `CIRoundedRectangleGenerator`'s mask antialiases the card's whole boundary
    /// (corners AND flat edges) one way; the export's H.264 encode of the identical boundary,
    /// resampled through block-based compression, antialiases it another — a REAL difference
    /// between two legitimate renderings of the identical geometry, not a wiring defect. So the
    /// exclusion is a band around the boundary ITSELF (`roundedRectSignedDistance`, above), not a
    /// box around only the corners. `cornerRadius` is a fixed pixel count on `StageStyle`
    /// (`.default` is 18), not a fraction of the output, so this carve-out is a small, fixed-width
    /// band regardless of output resolution — it does not grow to swallow the frame at a larger
    /// canvas, and its own width (`margin`) is a parameter this function's caller states, not a
    /// constant buried here.
    static func maxChannelDifference(
        _ a: (data: [UInt8], width: Int, height: Int), _ b: (data: [UInt8], width: Int, height: Int),
        excludingBoundaryOf card: StageRect, cornerRadius: Double, margin: Double, outputHeight: Int
    ) throws -> (maxDiff: Int, x: Int, y: Int, aPixel: (r: Int, g: Int, b: Int), bPixel: (r: Int, g: Int, b: Int)) {
        guard a.width == b.width, a.height == b.height else {
            throw RenderParityProbeError.dimensionMismatch("\(a.width)x\(a.height) vs \(b.width)x\(b.height)")
        }
        var maxDiff = -1
        var atX = 0, atY = 0
        var aBest: (Int, Int, Int) = (0, 0, 0)
        var bBest: (Int, Int, Int) = (0, 0, 0)
        for row in 0..<a.height {
            let rowBase = row * a.width * 4
            // `row` is TOP-DOWN (this function's own `rgbaBuffer` convention); `card`'s own
            // coordinates are BOTTOM-LEFT (`StageRect`'s convention, shared by every other check in
            // this probe) — converted once per row, not once per pixel, since it does not depend on
            // `column`.
            let bottomLeftY = Double(outputHeight - 1 - row)
            for column in 0..<a.width {
                let x = Double(column)
                if abs(roundedRectSignedDistance(x: x, y: bottomLeftY, card: card, cornerRadius: cornerRadius))
                    <= margin {
                    continue
                }
                let offset = rowBase + column * 4
                let ar = Int(a.data[offset]), ag = Int(a.data[offset + 1]), ab = Int(a.data[offset + 2])
                let br = Int(b.data[offset]), bg = Int(b.data[offset + 1]), bb = Int(b.data[offset + 2])
                let diff = max(abs(ar - br), max(abs(ag - bg), abs(ab - bb)))
                if diff > maxDiff {
                    maxDiff = diff
                    atX = column
                    atY = row
                    aBest = (ar, ag, ab)
                    bBest = (br, bg, bb)
                }
            }
        }
        return (maxDiff, atX, atY, aBest, bBest)
    }

    /// **What this proves, and what it does not — said explicitly, because a parity check silent
    /// about which of the two it means invites a reader to assume the stronger one.** Phase 2B
    /// built exactly ONE `AVVideoComposition`
    /// (`CompositionBuilder.composition(for:outputWidth:outputHeight:frameDuration:)`), handed to
    /// BOTH `StageWindow.load()` (preview) and `MP4Exporter.export(...)` (export) through the SAME
    /// `StageCompositor` / `CoreImageFrameRenderer` — `StageWindow.swift`'s own header: "the same
    /// statics, not a second configuration". There is exactly one renderer either consumer can
    /// reach. **So this check cannot test "the two renderers agree" — there are not two to
    /// compare.** What it DOES test is that the WIRING routing frames to that one renderer has not
    /// come apart. A future change that gave one consumer its own `StageStyle`, its own output
    /// size, or that routed one of them around the shared compositor entirely would show up here
    /// as a mismatch; a future change that swapped `CoreImageFrameRenderer` for a Metal
    /// implementation (Task 3's still-open seam) would NOT, because both consumers would still
    /// reach the same (new) renderer.
    ///
    /// **Which half is real, restated at every call site's own message per code review (Task 8,
    /// fix round 1), Important finding 1 — not left to this comment alone.** The export leg is the
    /// REAL `MP4Exporter.export()`. The preview leg calls `StageWindow.configuredComposition(for:)`
    /// — the SAME function `StageWindow.load()` calls, extracted at this same review round so this
    /// check could stop reconstructing its own copy of that configuration — and reads the result
    /// back with `AVAssetImageGenerator`, which is a STAND-IN for `AVPlayer`'s own frame delivery,
    /// not `AVPlayer` itself; nothing here drives real playback. `StageWindow.outputWidth`/
    /// `.outputHeight` are read directly (no second, hardcoded copy of the real `1920×1080`), so a
    /// regression confined to that function or those constants is now reachable by this check.
    ///
    /// **The fixture is a committed file, not generated per run**
    /// (`Tests/RenderParityFixtures/two-tone.mov`, ~6.5 KB, 64×64 ProRes4444, 2 seconds at 10 fps —
    /// the colour tags § 11's `writeSolidColorMovie` measured as needed for an exact round trip;
    /// regenerated from `Tests/RenderParityFixtures/generate-fixture.swift`, committed alongside
    /// it). Two colours, not one — the first second solid red, the second solid blue — so sampling
    /// a composition time inside either half can tell "the right frame was read" apart from "any
    /// plausible-looking frame was read": a wiring bug that mapped one consumer's timeline
    /// differently from the other's would show up as a wrong COLOUR, not merely a mismatched one.
    @MainActor
    static func theSameCompositionTimeMatchesThroughPreviewAndExport() async throws {
        let sourceWidth = 64
        let sourceHeight = 64
        // The number this check's own failure message names — § 11/§ 14 measured the same round
        // trip (AVAssetWriter encode → AVAssetReader/AVAssetImageGenerator decode, through the
        // identical CoreImageFrameRenderer) at up to 2 per channel off a fixed expected constant;
        // this check adds a SECOND independent encode/decode (the export's own AVAssetWriter, on
        // top of the fixture's own) between the two frames it compares, so it is given headroom
        // above that, not equal to it.
        let tolerance = 6

        let fixtureURL = probePackageRoot
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw RenderParityProbeError.fixtureMissing(fixtureURL.path)
        }

        StageCompositor.style = .default
        StageCompositor.overrides = []

        // Path A — the preview, through the REAL `StageWindow.configuredComposition(for:)` (see
        // this function's own header for why this is not a probe-local reconstruction any more),
        // read back with `AVAssetImageGenerator` (a stand-in for `AVPlayer`'s own frame delivery).
        let previewComposition = try await StageWindow.configuredComposition(for: fixtureURL)
        let previewGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: fixtureURL))
        previewGenerator.videoComposition = previewComposition
        previewGenerator.requestedTimeToleranceBefore = .zero
        previewGenerator.requestedTimeToleranceAfter = .zero

        // Path B — the real export, exactly what the Export button runs, then read the finished
        // file back — no `.videoComposition` needed here, unlike Path A: the export already baked
        // the composed pixels into the file. Exported ONCE and sampled at every composition time
        // below, exactly as the preview's own single composition is. Runs AFTER Path A's
        // composition is built (which itself calls `StageCompositor.resetDiagnostics()` and sets
        // `StageCompositor.renderer`/`.observationLogURL`), so both paths render through the
        // identical statics `configuredComposition(for:)` just configured — the same "the same
        // statics, not a second configuration" property `StageWindow.exportRecording()`'s own
        // header relies on in the real app.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soredemo-probe-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exportedURL = directory.appendingPathComponent("export.mp4")
        _ = try await MP4Exporter.export(asset: AVURLAsset(url: fixtureURL), to: exportedURL,
                                         outputWidth: StageWindow.outputWidth,
                                         outputHeight: StageWindow.outputHeight)
        let exportGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: exportedURL))
        exportGenerator.requestedTimeToleranceBefore = .zero
        exportGenerator.requestedTimeToleranceAfter = .zero

        // The card centre, for the sanity check only — geometry-BLIND (`StagePlanner.plan`'s card
        // is always output-centred regardless of `insetFraction`), which is exactly why the real
        // parity assertion below is a full-frame scan and not a second hand-picked point.
        let plan = StagePlanner.plan(outputWidth: StageWindow.outputWidth, outputHeight: StageWindow.outputHeight,
                                     sourceWidth: sourceWidth, sourceHeight: sourceHeight, style: .default)
        let centreX = Int((plan.card.x + plan.card.width / 2).rounded())
        let centreY = Int((plan.card.y + plan.card.height / 2).rounded())

        // AN EXPLICIT SET of composition times, not one — the ROADMAP's own `render-parity` row
        // asks for this by name. One instant per fixture half, so a wiring bug that mapped one
        // consumer's timeline differently from the other's (an off-by-N frame, a unit mismatch)
        // has two independent chances to surface as a wrong colour rather than one.
        let sampleTimes: [(label: String, time: CMTime, expectedColour: (r: Int, g: Int, b: Int))] = [
            ("0.5s (red half)", CMTime(seconds: 0.5, preferredTimescale: 600), (255, 0, 0)),
            ("1.5s (blue half)", CMTime(seconds: 1.5, preferredTimescale: 600), (0, 0, 255)),
        ]

        for (label, sampleTime, expectedColour) in sampleTimes {
            let (previewImage, _) = try await previewGenerator.image(at: sampleTime)
            let (exportImage, _) = try await exportGenerator.image(at: sampleTime)

            // The RIGHT value, not two paths agreeing on the same wrong constant (the "assert the
            // shared value is the right one" discipline § 14's own recount already applies): the
            // preview side must actually be reading THIS half's own colour, not e.g. silently
            // reading black because the generator failed.
            let previewCentre = try pixel(in: previewImage, x: centreX, y: centreY,
                                          outputHeight: StageWindow.outputHeight)
            check(closeEnough(previewCentre, expectedColour, tolerance: tolerance),
                  "sanity at \(label): the preview leg's card centre is the fixture's own colour "
                  + "there, within ±\(tolerance) per channel — not a vacuous pass from two paths "
                  + "agreeing on the same wrong pixel",
                  actual: "\(previewCentre)", expected: "\(expectedColour) ± \(tolerance)")

            let previewBuffer = try rgbaBuffer(of: previewImage)
            let exportBuffer = try rgbaBuffer(of: exportImage)
            // `boundaryMargin`: measured, not guessed — see `maxChannelDifference`'s own header for
            // the two measurements (84 at a corner, then 42–45 at a flat edge once the corner-only
            // exclusion was widened) this width was chosen to clear. `plan.cornerRadius` (not
            // `StageStyle.default.cornerRadius`) because `StagePlanner.plan` clamps the radius to
            // half the shorter card side, and using the CLAMPED value is what keeps this correct
            // if a future style or a smaller card ever needed the clamp.
            let boundaryMargin = 12.0
            let diff = try maxChannelDifference(previewBuffer, exportBuffer, excludingBoundaryOf: plan.card,
                                                cornerRadius: plan.cornerRadius, margin: boundaryMargin,
                                                outputHeight: StageWindow.outputHeight)

            check(diff.maxDiff <= tolerance,
                  "render-parity at \(label), pixel by pixel over the WHOLE \(StageWindow.outputWidth)"
                  + "×\(StageWindow.outputHeight) frame EXCEPT a \(Int(boundaryMargin))px band around "
                  + "the card's own boundary (corners AND flat edges — H.264 antialiases that "
                  + "boundary differently from Core Image even under matching styles, measured at "
                  + "up to 84 there with no mutation at all), max per-channel diff ≤ ±\(tolerance) "
                  + "over everywhere else: the preview leg "
                  + "(StageWindow.configuredComposition(for:) — the REAL function "
                  + "StageWindow.load() calls — read back with AVAssetImageGenerator, a stand-in "
                  + "for AVPlayer's own frame delivery, not AVPlayer itself) and the export leg "
                  + "(the REAL MP4Exporter.export(), reading its finished file back) agree, not "
                  + "just at hand-picked points. THIS TESTS THAT THE WIRING HAS NOT COME APART — "
                  + "one StageCompositor, one CompositionBuilder call, one StageStyle, shared by "
                  + "both consumers (ARCHITECTURE.md D8) — NOT that two renderers agree with each "
                  + "other; there is exactly one renderer either path can reach",
                  actual: "worst diff \(diff.maxDiff) at pixel (\(diff.x), \(diff.y)): "
                  + "preview \(diff.aPixel), export \(diff.bPixel)",
                  expected: "max diff ≤ \(tolerance)")
        }

        // The third of the ROADMAP row's three specifications — "keep preview-only chrome above
        // the compositor" — has no check here, and that absence is deliberate rather than an
        // oversight: nothing in this app draws preview-only chrome (selection handles, guides) at
        // all yet — `Sources/Framing`/`Sources/Variants` are one-line placeholders (ROADMAP,
        // `derivation-graph`) and Phase 4's `Editor/` does not exist. A check against a UI surface
        // that has not been built would be vacuous by construction. This becomes a real,
        // addable check the day Phase 4 adds the first thing drawn only in the preview window.
    }

    // MARK: - § 16  StageCompositor.diagnostics — the preview's dropped-frame count (Phase 2B Task 8)

    /// A `FrameRendering` that always throws — exists only to drive `StageCompositor.startRequest`'s
    /// `catch` branch directly; see § 16.2. Trivially `Sendable` (no stored state), satisfying
    /// `FrameRendering: Sendable`.
    struct AlwaysThrowingRenderer: FrameRendering {
        struct Boom: Error {}
        func render(_ plan: RenderPlan, source: CVPixelBuffer, camera: CVPixelBuffer?,
                    into destination: CVPixelBuffer) throws {
            throw Boom()
        }
    }

    /// `StageCompositor.Diagnostics`'s own header already gives the complete, two-branch causal
    /// account of what increments `framesDropped`; this section drives BOTH branches directly and
    /// watches the counter move — the same "every counter that partitions a decision, driven both
    /// ways" discipline § 8.6 already applies to `Capture.AXObserver`'s own counters — plus a clean run
    /// that proves a correctly configured render drops nothing at all.
    ///
    /// **`>= 1`, not `== 1`, on both branches.** `AVAssetImageGenerator.image(at:)` is not
    /// documented to call `startRequest` exactly once per request, and this check has no interest
    /// in that internal retry count — only in "the branch that should have fired, fired at least
    /// once".
    @MainActor
    static func theDropCounterIsDrivenByBothOfItsTwoCauses() async throws {
        let outputWidth = 320
        let outputHeight = 180
        let fixtureURL = probePackageRoot
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw RenderParityProbeError.fixtureMissing(fixtureURL.path)
        }
        let asset = AVURLAsset(url: fixtureURL)
        let composition = try await CompositionBuilder.composition(
            for: asset, outputWidth: outputWidth, outputHeight: outputHeight,
            frameDuration: CMTime(value: 1, timescale: 60))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // THIS SECTION LEAVES `StageCompositor`'s PROCESS-WIDE STATE AS IT FOUND IT.
        //
        // What follows deliberately sets `renderer` to `nil` and then to a throwing stub — the two
        // configurations that make the drop counter tick. Both are states no LATER section could
        // survive: a `nil` renderer makes every composition request fail the leading guard. Until
        // now this section was correct only because it happens to run last, which is an ordering
        // fact nobody declared and the next section appended to this file would silently break.
        // § 12 already restores `observationLogURL`/`overrides` this way; the same discipline, for
        // the same reason.
        let restoreRenderer = StageCompositor.renderer
        defer {
            StageCompositor.renderer = restoreRenderer
            StageCompositor.resetDiagnostics()
        }

        // 16.1 — cause 1: the leading guard, via no renderer configured at all.
        StageCompositor.renderer = nil
        StageCompositor.resetDiagnostics()
        var guardBranchThrew = false
        do {
            _ = try await generator.image(at: .zero)
        } catch {
            guardBranchThrew = true
        }
        check(guardBranchThrew, "16.1 an unconfigured compositor (Self.renderer == nil) refuses the request")
        check(StageCompositor.diagnostics.framesDropped >= 1,
              "16.1 and the guard branch counted it — StageCompositor.Diagnostics's own header, cause 1",
              actual: "\(StageCompositor.diagnostics.framesDropped)", expected: ">= 1")

        // 16.2 — cause 2: the catch, via a renderer that throws.
        StageCompositor.renderer = AlwaysThrowingRenderer()
        StageCompositor.resetDiagnostics()
        var catchBranchThrew = false
        do {
            _ = try await generator.image(at: .zero)
        } catch {
            catchBranchThrew = true
        }
        check(catchBranchThrew, "16.2 a renderer that throws refuses the request")
        check(StageCompositor.diagnostics.framesDropped >= 1,
              "16.2 and the catch branch counted it — StageCompositor.Diagnostics's own header, cause 2",
              actual: "\(StageCompositor.diagnostics.framesDropped)", expected: ">= 1")

        // 16.3 — a correctly configured render drops nothing.
        StageCompositor.renderer = try CoreImageFrameRenderer()
        StageCompositor.resetDiagnostics()
        let (image, _) = try await generator.image(at: .zero)
        _ = image
        check(StageCompositor.diagnostics.framesDropped == 0,
              "16.3 and a correctly configured render drops nothing",
              actual: "\(StageCompositor.diagnostics.framesDropped)", expected: "0")
    }

    /// What a caller can learn about a writer's refusal — normalised, never the raw error text.
    struct MasterWriterFailureFact {
        /// Was the FIRST post-`finish()` append refused (`false`)?
        var firstAttemptRefused: Bool
        /// Did EVERY attempt after the first also come back refused — i.e. is the refusal
        /// durable, not a blip the writer recovers from? `MasterTrackWriting.append`'s own doc
        /// comment says `false` means the writer "has already failed"; a writer that started
        /// accepting appends again would falsify that contract.
        var refusalIsDurable: Bool
        /// For a human reader ONLY — never compared or asserted on. Legacy's `errorDescription`
        /// reads AVFoundation's own `AVAssetWriter.error`; the successor's reads a caught Swift
        /// `Error` formatted with `String(describing:)`. The two texts differ for reasons that
        /// are not defects — two different frameworks describing the same fact in their own
        /// words — so comparing them would fail this check for no real disagreement, and the
        /// usual fix for a test that goes red over nothing is to loosen it until it stops
        /// catching anything.
        var rawMessageForHumans: String
    }

    /// Three appends issued after `writer` has already `finish()`ed. Video only — one track is
    /// enough to establish whether the writer refuses, and reusing `writer.video` keeps this
    /// function symmetric with `feedIdenticalMedia`'s own per-track shape.
    @MainActor
    static func postFinishAppendFact(_ writer: any MasterWriting, width: Int, height: Int) throws
        -> MasterWriterFailureFact {
        var accepted: [Bool] = []
        for attempt in 0..<3 {
            // Frame indices well past `frameCount`, so a bug that let one of these through would
            // not silently collide with a real sample's own presentation time.
            let sample = try masterWriterProbeVideoSample(width: width, height: height, frame: 9_000 + attempt)
            accepted.append(writer.video.append(sample))
        }
        return MasterWriterFailureFact(
            firstAttemptRefused: accepted.first == false,
            refusalIsDurable: accepted.allSatisfy { $0 == false },
            rawMessageForHumans: writer.errorDescription ?? "no error recorded")
    }

    // MARK: - § 18. the idle-frame question

    /// **`capture-source`'s outstanding clause, answered by measurement rather than by copying.**
    ///
    /// ScreenCaptureKit emits a frame when the screen changes and not otherwise, and this project
    /// measured `SCFrameStatusIdle` at 42–84% of callbacks. The roadmap left the question open
    /// with a warning attached: a constant-frame-rate writer
    /// that repeated the last frame on idle, deprecated it, and replaced it with variable frame
    /// rate plus **IOSurface-identity deduplication** — `surfaceID == lastIOSurfaceID`, skip.
    /// Filtering on `status == .complete` is what this app does.
    ///
    /// So the question was whether to adopt an IOSurface-identity dedup. This is the measurement that says
    /// no, and it is kept as a check rather than written down because it is a claim about a
    /// framework's behaviour that a macOS release could change.
    ///
    /// **What was measured, before this was written:** four runs, 875 complete frames across
    /// window capture (still and moving) and display capture, and `surfaceID == lastSurfaceID`
    /// was true **zero** times. ScreenCaptureKit cycles a pool of two surfaces, so consecutive
    /// frames never carry the same id — not even when the picture has not changed at all. Over
    /// the same still-window frames, 97–100% were byte-identical to the frame before them. The
    /// duplicates are real and plentiful; that predicate simply cannot see them, because a
    /// one-frame memory is defeated by a two-deep pool.
    ///
    /// The conclusion carried into the roadmap: keep the `.complete` filter, do not repeat frames
    /// (the one project that shipped that abandoned it, and `MP4Exporter` already resamples to a
    /// constant rate with held frames, so a constant-rate master would do the work twice), and if
    /// duplicate suppression is ever wanted, compare CONTENT — never surface identity.
    ///
    /// **Skips rather than fails without a Screen Recording grant.** Whether a stream over this
    /// process's own window needs one was NOT established here: `CGPreflightScreenCaptureAccess()`
    /// answered true on the machine this was written on, because a probe launched from a terminal
    /// inherits that terminal's grant, so this run could not tell "no grant needed" from "a grant
    /// was present". Recorded as unknown rather than guessed at.
    @MainActor
    /// **What a recording costs in memory, and whether it costs more the longer it runs.**
    ///
    /// The failure this exists for is not a crash. It is a person who records for thirty minutes
    /// and gets a file that stopped at nine, because the process grew until the system took it —
    /// and `RecordingHealth` exists precisely because that risk is real. Nothing in this
    /// repository measured it until now, so the budgets below were written as proposals in
    /// `docs/TESTING.md` and are replaced here by what a real capture actually does.
    ///
    /// **Growth is the assertion, not the peak.** A recorder that sits at 400 MB for an hour is
    /// fine; one that climbs 30 MB a minute is a lost recording however low it starts. So the
    /// peak is reported and the SLOPE is checked, measured after a settling window rather than
    /// from the first sample — the first seconds carry the writer's own start-up and the first
    /// pixel buffers, which are a cost paid once and not a leak.
    ///
    /// A real `SCStream` over this process's own window, through the real `CaptureSession` and a
    /// real writer, because a synthetic frame source would measure the sampler.
    static func aRecordingDoesNotGrowWhileItRuns() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("        SKIPPED — no Screen Recording grant for this binary, so there is no "
                  + "recording to measure. A memory figure from a stream that never opened would "
                  + "be a fact about this probe.")
            return
        }
        guard probeMemoryFootprintBytes() != nil else {
            print("        SKIPPED — task_info(TASK_VM_INFO) refused, so there is no instrument.")
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "cross-boundary-digest-probe (memory)"
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))

        let content = try await SCShareableContent.currentProcess
        guard let scWindow = content.windows.first(where: { $0.title == window.title }),
              let display = content.displays.first else {
            print("        SKIPPED — the probe's own window did not appear in "
                  + "SCShareableContent.currentProcess; there is nothing to record.")
            return
        }

        let sink: TemporaryFileMediaSink
        do { sink = try TemporaryFileMediaSink() } catch {
            print("        SKIPPED — could not open a media sink: \(error)")
            return
        }
        defer { if let directory = sink.packageURL { try? FileManager.default.removeItem(at: directory) } }

        let session = CaptureSession(
            source: probeWindowSource(scWindow, on: display, bufferSize: (1280, 800)),
            scale: 2, displayUUID: UUID(), mediaSink: sink, epoch: Minting.bootEpoch(),
            microphone: .off, capturesSystemAudio: false, frameRate: .sixty)

        do { try await session.start() } catch {
            print("        SKIPPED — the capture session refused to start: \(error)")
            return
        }

        // Sampled while the window is being redrawn, so the stream is producing frames rather
        // than idling on a still picture — an idle capture is the cheap case and would measure
        // the wrong thing.
        var samples: [(seconds: Double, bytes: Int64)] = []
        let clock = ContinuousClock()
        let began = clock.now
        while clock.now - began < .seconds(20) {
            window.backgroundColor = samples.count % 2 == 0 ? .systemBlue : .systemOrange
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            if let bytes = probeMemoryFootprintBytes() {
                let elapsed = Double((clock.now - began).components.seconds)
                    + Double((clock.now - began).components.attoseconds) / 1e18
                samples.append((elapsed, bytes))
            }
        }
        _ = try? await session.stop()

        guard samples.count >= 40 else {
            print("        SKIPPED — only \(samples.count) samples; not enough to fit a slope.")
            return
        }

        // **Measured after a settling window.** The first seconds carry the writer opening its
        // file and the first pixel buffers being allocated, which is a cost paid once. A slope
        // fitted through them would report start-up as a leak.
        let settled = samples.filter { $0.seconds >= 5 }
        let peak = samples.map(\.bytes).max() ?? 0
        let first = settled.first!, last = settled.last!
        let span = last.seconds - first.seconds
        let growthPerMinute = span > 0
            ? probeMegabytes(last.bytes - first.bytes) / span * 60 : 0

        print(String(format: "        peak %.0f MB, settled %.0f → %.0f MB over %.0fs "
                             + "(%.1f MB/min)",
                     probeMegabytes(peak), probeMegabytes(first.bytes),
                     probeMegabytes(last.bytes), span, growthPerMinute))

        // **The slope is the budget; the peak is reported.** 30 MB a minute is roughly a
        // gigabyte an hour, which is where a long recording starts being at risk on a machine
        // that is also running the thing being demonstrated. A recorder that sits still at any
        // reasonable figure is fine, so no ceiling is asserted from a twenty-second sample —
        // that would be a number this measurement cannot support.
        check(growthPerMinute < 30,
              "28.1 a running recording does not grow without bound",
              actual: String(format: "%.1f MB/min", growthPerMinute),
              expected: "< 30 MB/min")

        // And the recording is real: a measurement taken while nothing was being written would
        // be a fact about an idle process.
        check(sink.packageURL != nil, "28.2 the measured run actually wrote a recording")
    }

    static func duplicateFramesAreContentIdenticalNotSurfaceIdentical() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("        SKIPPED — no Screen Recording grant for this binary, so no SCStream. "
                  + "Whether a self-capture stream needs one is not settled; see this "
                  + "function's header.")
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 480, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "cross-boundary-digest-probe (idle frames)"
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))

        let content = try await SCShareableContent.currentProcess
        guard let scWindow = content.windows.first(where: { $0.title == window.title }) else {
            print("        SKIPPED — the probe's own window did not appear in "
                  + "SCShareableContent.currentProcess; there is nothing to capture.")
            return
        }

        let configuration = SCStreamConfiguration()
        configuration.width = 480
        configuration.height = 300
        // The same ceiling a real recording asks for, so the cadence being measured is the one
        // the app actually sees.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let collector = IdleFrameCollector()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow),
                              configuration: configuration, delegate: collector)
        try stream.addStreamOutput(collector, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "probe.idle-frames"))
        do { try await stream.startCapture() } catch {
            print("        SKIPPED — startCapture refused: \(error)")
            return
        }
        // Nothing touches the window for this stretch: the claim is about a STILL screen, and a
        // probe that redrew it would be measuring its own animation.
        try await Task.sleep(for: .seconds(2))
        try? await stream.stopCapture()

        let (surfaces, hashes, noSurface) = collector.snapshot()
        print("        \(surfaces.count) complete frames, \(Set(surfaces).count) distinct "
              + "IOSurface ids, \(Set(hashes).count) distinct pictures")

        // **The skip is a branch, not a `return`, and that repair is the point.** Sections 19
        // through 27 live in this same function, so the `return` that used to be here took
        // seventy checks in nine unrelated sections with it whenever too few frames arrived —
        // and the run still printed PROBE PASSED, with a smaller number nobody was comparing
        // against anything. A gate that skips has to say so where the verdict is read.
        if surfaces.count < 10 {
            let why = "18 — only \(surfaces.count) complete frames arrived in 2 s, too few to "
                + "say anything about duplicates"
            print("        SKIPPED — \(why).")
            skipped.append(why)
        } else {
            check(noSurface == 0,
                  "18.1 every complete frame carries an IOSurface — the thing such a dedup reads",
                  actual: "\(noSurface) without one", expected: "0")

            let sameSurfaceAsPrevious = (1..<surfaces.count).count { surfaces[$0] == surfaces[$0 - 1] }
            // **The load-bearing check.** If this ever stops being zero, ScreenCaptureKit has
            // changed how it cycles its surface pool and the decision recorded above should be
            // re-made.
            check(sameSurfaceAsPrevious == 0, """
                  18.2 no two consecutive frames share an IOSurface id — so an identity \
                  `surfaceID == lastIOSurfaceID` dedup would skip nothing
                  """,
                  actual: "\(sameSurfaceAsPrevious) of \(surfaces.count - 1)", expected: "0")

            let sameContentAsPrevious = (1..<hashes.count).count { hashes[$0] == hashes[$0 - 1] }
            // Conservative by a wide margin: measured at 97–100% over four runs of a still
            // window. Half is enough to establish that the duplicates exist and are visible in
            // the CONTENT, which is the half of the finding that survives a busier machine.
            check(sameContentAsPrevious * 2 > hashes.count - 1, """
                  18.3 most of a still window's frames repeat the previous picture exactly — the \
                  duplicates are real, and content is the only place they show
                  """,
                  actual: "\(sameContentAsPrevious) of \(hashes.count - 1)",
                  expected: "more than half")
        }

        // MARK: - 19. hiding the desktop's icons, without hiding anybody's desktop

        print("")
        print("19. DesktopIcons — the read side, exercised; the write side, deliberately not")
        print("19.1-19.3 the only app file a gate may not fully execute, and why")

        // **This section runs no `hide()` and no `restore()` that does anything.** Both restart
        // Finder, which closes the Finder windows of whoever is running the gates — every gate
        // run, on a developer machine, for a check. That price is not worth paying, so the
        // destructive half was verified once, by hand, against this same source file:
        //
        //     start    pref=absent  visible=true   owed=false  finder=14693
        //     hidden   pref=0       visible=false  owed=true   finder=29860
        //     hide x2  pref=0       owed=true          (the double-hide guard holds)
        //     restored pref=absent  visible=true   owed=false  finder=29910
        //     restore2 pref=absent  owed=false         (idempotent)
        //
        // What remains is everything checkable without touching anything: that the type reads
        // the real preference rather than a cached idea of it, that a clean machine owes
        // nothing, and — the one that matters — that `restore()` with no debt is genuinely
        // inert. The ordering is covered by the scans in `AppSourceAllowListTests`.

        let finderBefore = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .map(\.processIdentifier).sorted()
        let rawPreference = CFPreferencesCopyAppValue("CreateDesktop" as CFString,
                                                      "com.apple.finder" as CFString)
        let preferenceSaysVisible = (rawPreference as? NSNumber)?.boolValue ?? true
        check(DesktopIcons.areVisible == preferenceSaysVisible,
              "19.1 areVisible answers from Finder's own live preference, absent meaning visible",
              actual: "\(DesktopIcons.areVisible)", expected: "\(preferenceSaysVisible)")

        // A gate machine has never hidden anything through this app; a debt here means an
        // earlier run hid the desktop and never put it back.
        check(!DesktopIcons.restoreIsOwed,
              "19.2 no restore is owed before anything asked for one",
              actual: "\(DesktopIcons.restoreIsOwed)", expected: "false")

        // **The inertness check.** `restore()` runs at launch on every single start of the app,
        // so a version that acted unconditionally would restart the user's Finder every time
        // they opened Soredemo. Finder's process ids are what prove it did nothing.
        DesktopIcons.restore()
        try await Task.sleep(for: .seconds(DesktopIcons.relaunchGrace + 1))
        let finderAfter = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .map(\.processIdentifier).sorted()
        check(finderAfter == finderBefore,
              "19.3 restore() with no debt restarts nothing, so launching the app is free",
              actual: "\(finderAfter)", expected: "\(finderBefore)")
        // MARK: - 20. phones and tablets, and the switch that makes them visible

        print("")
        print("20. MobileScreen — the CoreMediaIO switch, thrown in a process that can afford it")
        print("20.1-20.4 why this is here and not in the test suite")

        // **This section exists because `swift test` cannot run it.**
        // `MobileScreen.allowDevices()` sets `kCMIOHardwarePropertyAllowScreenCaptureDevices`,
        // which starts the CoreMediaIO plug-in host — a process-global side effect on the same
        // subsystem AVFoundation and ScreenCaptureKit use. Thrown alongside the capture and
        // compositing suites in the shared test process it hung 71 tests at 0% CPU, none of them
        // its own, which passed in 0.16 s when run alone. Here it is one process doing one thing.
        //
        // **With no phone plugged in, most of what follows is a shape check.** That is stated
        // rather than dressed up: the claim "a real iPhone appears in this list" needs a cable
        // and cannot be made by any gate. What CAN be established without one is that the switch
        // succeeds, that nothing already attached is mistaken for a phone, and that the two lists
        // this feature splits devices into never overlap.

        let allowed = MobileScreen.allowDevices()
        check(allowed, "20.1 the CoreMediaIO screen-capture switch can be set on this Mac",
              actual: "\(allowed)", expected: "true")

        let phones = MobileScreen.available()
        let cameras = CameraRecorder.available()
        let phoneIDs = Set(phones.map(\.uniqueID))
        let cameraIDs = Set(cameras.compactMap(\.uniqueID))
        print("      (\(phones.count) phone(s), \(cameras.count) camera(s) attached)")

        // **The load-bearing one.** A device in both lists would be offered as the recording
        // source AND as the face in the corner, and choosing it twice is two clients on one
        // device. `CameraRecorder.available()` asks for `.external`, so without its filter a
        // phone lands in both the moment the switch above is thrown.
        check(phoneIDs.intersection(cameraIDs).isEmpty,
              "20.2 no device is in both the phone list and the camera list",
              actual: "\(phoneIDs.intersection(cameraIDs))", expected: "[]")

        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        let misread = builtIn.filter { MobileScreen.isMobileScreen($0) }
        check(misread.isEmpty,
              "20.3 no built-in or Continuity camera is read as a phone",
              actual: "\(misread.map(\.localizedName))", expected: "[]")

        // Every phone offered must be namable and recordable — a source with no name cannot be
        // put on a card, and one with no id cannot be opened.
        let unusable = phones.filter { $0.name.isEmpty || $0.uniqueID.isEmpty }
        check(unusable.isEmpty,
              "20.4 every phone offered has both a name to show and an id to open",
              actual: "\(unusable.count) unusable", expected: "0")
        // **The failure mode this feature actually has**, measured on this machine with an iPad
        // plugged in: the device is on the USB bus — `ioreg` shows `iPad@00100000`, vendor
        // "Apple Inc." — and exposes PTP, Apple's USB multiplexor and two network-over-USB
        // interfaces. It does NOT expose the screen-capture interface, which appears only once
        // the device is unlocked. So `available()` is correctly empty, and without 20.5 a person
        // sees nothing at all with a cable in their hand.
        let waiting = MobileScreen.attachedButUnavailable()
        print("      (\(waiting.count) attached but not offering a screen: \(waiting))")
        check(waiting.allSatisfy { MobileScreen.isMobileFamily($0) },
              "20.5 everything reported as waiting really is a phone or tablet",
              actual: "\(waiting)", expected: "all phones or tablets")

        // The two lists are alternatives, never both: a device offering its screen is not
        // waiting for anything, and a prompt beside a working card would be nonsense.
        let bothWays = waiting.filter { name in
            phones.contains { $0.name.localizedCaseInsensitiveContains(name) }
        }
        check(bothWays.isEmpty,
              "20.6 nothing is both offering its screen and waiting to be unlocked",
              actual: "\(bothWays)", expected: "[]")
        // **Every device offered shows the name its owner gave it.** Measured on a real iPad
        // over USB: `localizedName` was two U+25A1 WHITE SQUARE characters, which looked like a
        // placeholder and was the name its owner had chosen. The check is that the name reaches
        // the card unchanged — the opposite of what an earlier version of this line asserted.
        let renamed = phones.filter { !$0.name.isEmpty && $0.displayName != $0.name }
        check(renamed.isEmpty,
              "20.7 every phone shows the name its owner gave it, unaltered",
              actual: "\(renamed.map { "\($0.name) -> \($0.displayName)" })", expected: "[]")

        // **Nothing is both offering a screen and waiting to be unlocked.** 20.6 above checks
        // this by name and could not fire without a device attached; with one attached the first
        // version of `attachedButUnavailable` reported exactly this contradiction, because it
        // matched the USB family string "iPad" against the device's own name. Counted now.
        let attachedAll = MobileScreen.attachedMobileFamilyNames()
        let shouldBeWaiting = max(0, attachedAll.count - phones.count)
        check(waiting.count == shouldBeWaiting,
              "20.8 the waiting list is exactly the attached devices minus the ones offering",
              actual: "waiting=\(waiting.count) attached=\(attachedAll.count) offering=\(phones.count)",
              expected: "waiting=\(shouldBeWaiting)")
        // MARK: - 21. bringing in a video this app did not record

        print("")
        print("21. ImportedRecording — a file staged into a package, not opened where it lies")

        // **The reason this type exists at all**, and the reason it is checked here rather than
        // in a unit test: it touches the filesystem, and what it must get right is a LAYOUT that
        // every other path depends on. `ObservationWriter.expectedLogURL` looks for
        // `<package>/observations/` beside `<package>/media/master-NN.<ext>`, and noise removal
        // writes its cleaned audio into that package. Opening `~/Desktop/demo.mp4` in place makes
        // the package `~`, and the first cleaned audio track lands in somebody's home folder.
        let importScratch = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-probe-import", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: importScratch)
        try FileManager.default.createDirectory(at: importScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: importScratch) }

        let sourceVideo = importScratch.appending(path: "someone-elses.mp4")
        // A real file with a real video track — a zero-byte placeholder would be refused, which
        // is correct and would test nothing about the layout.
        let madeVideo = await probeWriteTinyMovie(to: sourceVideo)
        check(madeVideo, "21.1 the fixture video was written", actual: "\(madeVideo)",
              expected: "true")

        if madeVideo {
            do {
                let staged = try await ImportedRecording.stage(sourceVideo)
                let media = staged.mediaURL
                let package = media.deletingLastPathComponent().deletingLastPathComponent()

                check(media.lastPathComponent.hasPrefix("master-00"),
                      "21.2 the staged file is named the way a recording's master is named",
                      actual: media.lastPathComponent, expected: "master-00.*")
                check(media.deletingLastPathComponent().lastPathComponent == "media",
                      "21.3 it sits in the package's media/ directory",
                      actual: media.deletingLastPathComponent().lastPathComponent,
                      expected: "media")
                check(package != sourceVideo.deletingLastPathComponent(),
                      "21.4 the package is NOT the folder the original was in",
                      actual: package.lastPathComponent,
                      expected: "not \(sourceVideo.deletingLastPathComponent().lastPathComponent)")
                check(FileManager.default.fileExists(atPath: sourceVideo.path(percentEncoded: false)),
                      "21.5 the original file is still where its owner left it",
                      actual: "present", expected: "present")
                check(media.pathExtension == sourceVideo.pathExtension,
                      "21.6 the extension is the source's own, so AVFoundation is not misled",
                      actual: media.pathExtension, expected: sourceVideo.pathExtension)
            } catch {
                check(false, "21.2-21.6 staging a video with a video track", actual: "\(error)",
                      expected: "staged")
            }
        }

        // A file with no video in it is refused BY NAME rather than staged and then found empty
        // in the editor — after a copy that may be gigabytes.
        let audioOnly = importScratch.appending(path: "just-audio.m4a")
        let madeAudio = await probeWriteTinyAudio(to: audioOnly)
        if madeAudio {
            var refused = false
            do { _ = try await ImportedRecording.stage(audioOnly) } catch { refused = true }
            check(refused, "21.7 a file with no video is refused before anything is copied",
                  actual: "\(refused)", expected: "true")
        }

        print("")
        print("22. PersonMask — Vision, in a process that can afford to block")

        // **Here rather than in a unit test, and the reason is the same one § 20 gives.**
        // `VNImageRequestHandler.perform` is synchronous and pulls in CoreML, Espresso and the
        // Apple Neural Engine. `swift test` runs every target in ONE process with Swift Testing
        // running suites concurrently, and these calls stalled the whole CompositingTests run at
        // **0% CPU** — measured twice, once with the suite `.serialized` and once with every
        // Vision call hopped onto a `DispatchQueue`. Neither was enough: a `sample` of the hung
        // process showed all eight cooperative threads in `_pthread_cond_wait` and thirteen
        // unfinished tests, only one of which was a Vision test at all. The other twelve were
        // audio and codec tests that had simply been starved.
        //
        // So the rule that governs it is the rule this instrument exists for: a framework that
        // takes the process hostage is exercised in a process that has nothing else to lose.
        // `Core/Tests/CompositingTests/PersonMaskTests.swift` keeps the parts that are pure
        // arithmetic — the level rule, the mask widths, the refusal that never reaches Vision.
        //
        // **What cannot be checked anywhere is whether a person is cut out WELL.** That needs a
        // frame with somebody in it, and a repository does not want a photograph of a human being
        // committed to it to satisfy a test. What is checked here is everything else: that the
        // mask lands on the frame at four different shapes, that both levels run, and — the one
        // that actually proves the mask is applied rather than merely computed — that a frame
        // with nobody in it comes back very nearly transparent.
        PersonMask.warmUp()
        check(true, "22.1 warming Vision's models returns rather than hanging")

        let probeCIContext = CIContext(options: [.workingColorSpace: NSNull()])

        /// A frame of plain content at a given size. Vision finds nobody in it, which is the
        /// point — every claim below is about geometry and application, not about detection.
        func probeBlankFrame(width: Int, height: Int) -> CVPixelBuffer? {
            var created: CVPixelBuffer?
            _ = unsafe CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
            guard let buffer = created else { return nil }
            // Mid grey, so "the cut-out is transparent" cannot be satisfied by a frame that was
            // already black and empty.
            unsafe CVPixelBufferLockBaseAddress(buffer, [])
            if let base = unsafe CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = unsafe CVPixelBufferGetBytesPerRow(buffer)
                unsafe memset(base, 128, rowBytes * height)
            }
            unsafe CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }

        // ---- 22.2 the mask lands on the frame, at four shapes.
        //
        // **This is the check that would have caught the mistake the design turns on.** Vision's
        // mask is 512x384 for a 1920x1080 frame and for a 1000x1000 one — it does not preserve
        // the input's aspect — so it has to be stretched over the whole extent with X and Y
        // scaled apart. Matching the aspect, which is the natural thing to write, would leave the
        // silhouette off the person by a fifth of the frame and would do it silently.
        for (width, height) in [(1280, 720), (720, 1280), (600, 600), (1920, 1080)] {
            guard let frame = probeBlankFrame(width: width, height: height) else {
                check(false, "22.2 the \(width)x\(height) fixture was allocated")
                continue
            }
            let image = CIImage(cvPixelBuffer: frame)
            guard case .cutOut(let cut) = PersonMask.cutOut(image, from: frame,
                                                            quality: .balanced) else {
                check(false, "22.2 a well-formed \(width)x\(height) frame produced a cut-out")
                continue
            }
            check(cut.extent == image.extent,
                  "22.2 a \(width)x\(height) cut-out covers exactly the frame it came from",
                  actual: "\(cut.extent)", expected: "\(image.extent)")
        }

        // ---- 22.3 both levels run. The accurate one is 2.7x the cost and is reached only
        // through `quality(forCardWidthInPixels:)`, so without this it is a public option that
        // nothing has ever executed.
        for quality in PersonMask.Quality.allCases {
            guard let frame = probeBlankFrame(width: 640, height: 360) else { continue }
            guard case .cutOut = PersonMask.cutOut(CIImage(cvPixelBuffer: frame), from: frame,
                                                   quality: quality) else {
                check(false, "22.3 \(quality.rawValue) segments a well-formed frame")
                continue
            }
            check(true, "22.3 \(quality.rawValue) segments a well-formed frame")
        }

        // ---- 22.4 **the mask is applied, not merely computed.**
        //
        // Every check above would pass against a function that ran Vision, threw the mask away
        // and returned the frame untouched — the extents would still match, because they are the
        // frame's own. This one reads the pixels back. A frame of mid grey with nobody in it must
        // come back very nearly transparent, because Vision's mask for an empty room peaks at 2
        // to 5 out of 255. If the blend evaporated — which is exactly what happened to the camera
        // overlay's border for months, compositing into a zero-extent `CIImage.empty()` — the
        // alpha would come back at 255 and this is the only check in the project that would see
        // it.
        if let frame = probeBlankFrame(width: 320, height: 240),
           case .cutOut(let cut) = PersonMask.cutOut(CIImage(cvPixelBuffer: frame), from: frame,
                                                     quality: .balanced) {
            let width = 320, height = 240
            var pixels = [UInt8](repeating: 0, count: 4 * width * height)
            unsafe pixels.withUnsafeMutableBytes {
                unsafe probeCIContext.render(cut, toBitmap: $0.baseAddress!,
                                             rowBytes: width * 4,
                                             bounds: CGRect(x: 0, y: 0, width: width,
                                                            height: height),
                                             format: .RGBA8, colorSpace: nil)
            }
            var peakAlpha = 0
            var index = 3
            while index < pixels.count { peakAlpha = max(peakAlpha, Int(pixels[index]))
                                         index += 4 }
            check(peakAlpha < 32,
                  "22.4 a frame with nobody in it comes back transparent, so the mask is applied",
                  actual: "peak alpha \(peakAlpha)", expected: "under 32")
            print("        peak alpha of an empty room after cut-out: \(peakAlpha) of 255")
        } else {
            check(false, "22.4 the readback fixture was built and segmented")
        }

        // ---- 22.5 the level rule, executed rather than reasoned about. Pure arithmetic, and
        // also checked in `PersonMaskTests`; repeated here because the numbers it turns on are
        // the mask widths measured in this same process, two checks above.
        check(PersonMask.quality(forCardWidthInPixels: 512) == .balanced,
              "22.5 a card the width of the balanced mask does not pay for the accurate one")
        check(PersonMask.quality(forCardWidthInPixels: 513) == .accurate,
              "22.5 a card wider than the balanced mask earns the accurate one")

        print("")
        print("23. TranscriptPanel.wrappedLines — the one piece of arithmetic in a SwiftUI view")

        // **Here because the app target has no test target**, which is the same reason § 17
        // checks `RecordingCoordinator`'s preferences here. What is checked is not the layout —
        // nothing in this process can lay out a view — but the rule that decides which words
        // share a line.
        //
        // The rule counts characters rather than measuring text, and that is D6 rule 5 rather
        // than laziness: a real flow container means conforming to `Layout`, whose entire
        // signature is `CGSize` and `CGRect`, and the app target may not name those.
        do {
            func line(_ texts: [String], perLine: Int = 34) -> [[Int]] {
                TranscriptPanel.wrappedLines(Array(texts.enumerated())
                    .map { (index: $0.offset, text: $0.element) },
                                             charactersPerLine: perLine)
            }

            check(line([]).isEmpty, "23.1 no words make no lines")

            check(line(["It", "is", "like", "useful."]) == [[0, 1, 2, 3]],
                  "23.2 a short sentence stays on one line",
                  actual: "\(line(["It", "is", "like", "useful."]))", expected: "[[0, 1, 2, 3]]")

            let long = ["Recognising", "a", "sentence", "is", "shaped", "by", "settings",
                        "that", "belong", "to", "captions"]
            let wrappedLong = line(long)
            check(wrappedLong.count > 1, "23.3 a long sentence wraps",
                  actual: "\(wrappedLong.count) lines", expected: "more than 1")

            // **Nothing dropped, nothing duplicated, order kept.** The invariant that matters:
            // these indices address `transcript.words`, and a wrap that lost one would hide a
            // word somebody cannot then choose to cut — silently, and only for long sentences.
            let flattened = wrappedLong.flatMap { $0 }
            check(flattened == Array(long.indices),
                  "23.3 every word appears exactly once, in order",
                  actual: "\(flattened)", expected: "\(Array(long.indices))")

            // **A word longer than the whole line still gets a line**, rather than being dropped
            // or starting an empty one — the case a naive accumulator loses.
            let huge = line(["short", String(repeating: "x", count: 80), "after"], perLine: 10)
            check(huge.flatMap { $0 } == [0, 1, 2],
                  "23.4 a word longer than the line is kept rather than dropped",
                  actual: "\(huge)", expected: "all three indices")
            check(huge.contains([1]),
                  "23.4 an over-long word gets a line to itself",
                  actual: "\(huge)", expected: "a line containing only [1]")
        }

        print("")
        print("24. SystemCursorShape — the cursor is named again, and the wall was not there")

        // **This section exists because a measurement taken in the wrong place became a comment
        // that stopped a feature for weeks.** `SystemCursorShape` classified every cursor as
        // `.other`, on the strength of "the class cursors' images are 0x0 and their
        // tiffRepresentation is nil". That is TRUE in a binary that never touches
        // `NSApplication` — AppKit populates those images when the application object is created
        // — and this probe is exactly such a binary, which is why the check belongs here: if the
        // classifier ever stops forcing AppKit awake, this goes red rather than a recording
        // quietly going back to drawing every cursor as an arrow.
        //
        // Comparing against published demo footage is what surfaced it: a rendered cursor becomes a
        // pointing hand over a menu item and a crosshair over a spreadsheet cell, and this app's
        // did not — despite recording a shape per sample and drawing six of them.
        //
        // The table is built from the RUNNING system rather than from literal digests. Keeping
        // two literal tables, one for macOS 26 and one for everything before, because the
        // artwork changed; a literal table is a fact about an OS version pinned inside an
        // application, and it goes stale silently.
        check(!SystemCursorShape.knownCursors.isEmpty,
              "24.1 the class cursors have images to hash",
              actual: "\(SystemCursorShape.knownCursors.count) digests", expected: "more than 0")

        // ---- 24.2 each shape this app draws art for is identified as itself.
        //
        // **Round-tripped through the classifier rather than compared to the table**, so this
        // checks the thing callers use.
        let named: [(String, NSCursor, PointerShape)] = [
            ("arrow", .arrow, .arrow),
            ("iBeam", .iBeam, .iBeam),
            ("pointingHand", .pointingHand, .pointingHand),
            ("crosshair", .crosshair, .crosshair),
            ("resizeLeftRight", .resizeLeftRight, .resizeLeftRight),
            ("resizeUpDown", .resizeUpDown, .resizeUpDown),
        ]
        for (name, cursor, expected) in named {
            let classified = SystemCursorShape.classify(cursor)
            check(classified == expected,
                  "24.2 \(name) is recognised as itself",
                  actual: classified.rawValue, expected: expected.rawValue)
        }

        // ---- 24.3 the digest is what discriminates, and size could not.
        //
        // `pointingHand`, `openHand` and `closedHand` are all 32x32 with 20,892 bytes of TIFF;
        // `operationNotAllowed`, `dragCopy`, `contextualMenu` and `disappearingItem` are all
        // 28x40 with 22,812. A classifier keyed on size would answer one of each family for all
        // of it, and would be wrong in a way nothing reports.
        check(SystemCursorShape.classify(NSCursor.openHand) != .pointingHand,
              "24.3 an open hand is not mistaken for a pointing hand despite the same size",
              actual: SystemCursorShape.classify(NSCursor.openHand).rawValue,
              expected: "not pointingHand")

        // ---- 24.4 a cursor this app has no art for is `.other`, not a guess.
        //
        // `.other` is a real classification — "the system cursor was something this enum does not
        // name" — and the renderer draws it as an arrow. Reporting it as the nearest shape with
        // art would put a hand on screen where there was none.
        for (name, cursor) in [("openHand", NSCursor.openHand),
                               ("closedHand", NSCursor.closedHand),
                               ("contextualMenu", NSCursor.contextualMenu)] {
            let classified = SystemCursorShape.classify(cursor)
            check(classified == .other,
                  "24.4 \(name) has no art here and says so rather than guessing",
                  actual: classified.rawValue, expected: "other")
        }

        // ---- 24.5 the one-way resize cursors are reported on their own axis.
        //
        // A deliberate approximation, and the smaller of two errors: this app draws two resize
        // shapes and not four, and somebody who saw a horizontal resize affordance is shown one
        // rather than the arrow `.other` would give them.
        check(SystemCursorShape.classify(NSCursor.resizeLeft) == .resizeLeftRight,
              "24.5 a left-resize is drawn on the horizontal axis rather than as an arrow",
              actual: SystemCursorShape.classify(NSCursor.resizeLeft).rawValue,
              expected: "resizeLeftRight")
        check(SystemCursorShape.classify(NSCursor.resizeDown) == .resizeUpDown,
              "24.5 a down-resize is drawn on the vertical axis rather than as an arrow",
              actual: SystemCursorShape.classify(NSCursor.resizeDown).rawValue,
              expected: "resizeUpDown")

        print("")
        print("25. RecordingHealth wording — every damage says something different")

        // **The check itself is unit-tested against real broken files; this is about what a
        // person is told.** `RecordingCoordinator.wording(for:file:)` lives in the app target,
        // which has no test target of its own — the same reason § 17 checks its preferences here.
        //
        // Six damages with one shared sentence would be six causes reported as one, and they have
        // different next steps: a container that will not open means the recording died
        // mid-write; a file much shorter than the session means the writer stopped early. "Something
        // went wrong" leaves somebody holding a file they cannot judge.
        do {
            let damages: [RecordingHealth.Damage] = [
                .theFileIsNotThere, .theFileIsEmpty, .theContainerWillNotOpen,
                .thereIsNoVideoTrack, .theVideoWillNotDecode, .itIsShorterThanTheSession,
            ]
            var sentences: Set<String> = []
            for damage in damages {
                let text = RecordingCoordinator.wording(for: damage, file: "master-00.mov")
                sentences.insert(text)
                check(text.contains("master-00.mov"),
                      "25.1 \(damage.rawValue) names the file it is about",
                      actual: text, expected: "a sentence naming master-00.mov")
            }
            check(sentences.count == damages.count,
                  "25.2 every damage has its own sentence rather than a shared one",
                  actual: "\(sentences.count) distinct", expected: "\(damages.count)")
            // And a healthy recording says nothing: a message on every take is a message people
            // stop reading, including the one that matters.
            check(!RecordingHealth.sound(duration: Nanoseconds(1)).needsSaying,
                  "25.3 a healthy recording interrupts nobody")
            check(RecordingHealth.damaged(.theFileIsEmpty).needsSaying,
                  "25.3 a damaged one does")
        }

        print("")
        print("27. StillnessReader — a recording built to be still, then not")

        // **Here because decoding a whole recording beside the audio and codec suites stalled
        // the CompositingTests target**, exactly as Vision did for § 22 and CoreMediaIO for
        // § 20: ten unfinished tests, only one of them the new file's. The rule itself is pure
        // and is tested in `StillnessFinderTests`; what needs a real file is the half that turns
        // a video into a series, and that is this.
        do {
            let scratch = FileManager.default.temporaryDirectory
                .appending(path: "soredemo-probe-stillness", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: scratch)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let url = scratch.appending(path: "still-move-still.mov")

            // Twelve seconds: four holding one frame, four with a block sliding across, four
            // holding again. The block is 60 of 320 pixels wide, so a step changes about a fifth
            // of the frame — far above anything a threshold sits at.
            let made = await probeWriteStillMoveStill(to: url)
            check(made, "27.1 the fixture recording was written", actual: "\(made)",
                  expected: "true")

            if made {
                let outcome = await StillnessReader.changes(contentsOf: url, sliceSeconds: 0.25)
                guard case .changes(let changes) = outcome else {
                    check(false, "27.2 a well-formed recording is measured rather than refused")
                    return
                }
                check(changes.count > 40, "27.2 the whole recording was walked",
                      actual: "\(changes.count) slices", expected: "more than 40")

                func at(_ seconds: Double) -> Double {
                    let index = min(max(Int(seconds / 0.25) - 1, 0), changes.count - 1)
                    return changes.isEmpty ? 1 : changes[index]
                }
                let threshold = StillnessFinder.Settings.default.changeThreshold
                check(at(2) <= threshold,
                      "27.3 the first still stretch measures still",
                      actual: "\(at(2))", expected: "at most \(threshold)")
                check(at(10) <= threshold,
                      "27.3 the last still stretch measures still",
                      actual: "\(at(10))", expected: "at most \(threshold)")
                check(at(6) > 0.05,
                      "27.3 the moving stretch measures moving",
                      actual: "\(at(6))", expected: "more than 0.05")
                print(String(format: "        still %.5f   moving %.5f   still %.5f",
                             at(2), at(6), at(10)))

                // **The whole feature, end to end**: the rule finds exactly the two stretches
                // somebody would cut, and nothing in the middle.
                let spans = StillnessFinder.spans(changes: changes, sliceSeconds: 0.25)
                check(spans.count == 2,
                      "27.4 the two still stretches are found and the moving one is not",
                      actual: "\(spans.count) span(s)", expected: "2")
                if spans.count == 2 {
                    check(spans[0].start.rawValue < 1_000_000_000,
                          "27.4 the first span starts at the beginning",
                          actual: "\(spans[0].start.rawValue) ns", expected: "under 1 s")
                    check(spans[1].start.rawValue > 7_000_000_000,
                          "27.4 the second span starts after the movement",
                          actual: "\(spans[1].start.rawValue) ns", expected: "over 7 s")
                }
            }
        }

        print("")
        print("26. ExportETA — the six readings, and a key for each in every language")

        // **A stronger check than the label scan, and aimed at the thing the label scan cannot
        // see.** `ExportJobRow.timeText` renders each `Reading` case as a `Text` inside a switch,
        // which is not one of the positions the string-table scan looks at — and widening that
        // scan to every `Text("` would sweep in the explanatory sentences this project
        // deliberately leaves untranslated. So the cases are walked here instead: every one of
        // them must have a key, in every table on disk.
        //
        // This exists because the estimate was first built as an interpolated ENGLISH sentence
        // inside the package — "about 3 minutes left" — which cannot be a string-table key at
        // all: there is one key per number. The value type is what makes six keys enough.
        do {
            let readings: [ExportETA.Reading] = [
                .aFewSeconds, .seconds(20), .aMinute, .minutes(3), .anHour, .hours(2),
            ]
            // The keys the interface uses, spelled out HERE rather than read from the app — the
            // same argument § 17.2 makes about preference keys. Reading them from the code that
            // writes them would rename both sides at once.
            let expected = ["a few seconds left", "about %lld seconds left",
                            "about a minute left", "about %lld minutes left",
                            "about an hour left", "about %lld hours left"]
            check(readings.count == expected.count,
                  "26.1 every reading has a key named for it",
                  actual: "\(readings.count) readings, \(expected.count) keys",
                  expected: "equal")

            let resources = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Soredemo/Resources", directoryHint: .isDirectory)
            let languages = ((try? FileManager.default.contentsOfDirectory(
                at: resources, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "lproj" }
                .map { $0.deletingPathExtension().lastPathComponent }
                .sorted()
            check(languages.count >= 10,
                  "26.2 the string tables were found",
                  actual: "\(languages.count) languages", expected: "at least 10")

            var missing: [String] = []
            for language in languages {
                let table = (try? String(contentsOf: resources
                    .appending(path: "\(language).lproj/Localizable.strings"),
                                         encoding: .utf8)) ?? ""
                for key in expected where !table.contains("\"\(key)\" = ") {
                    missing.append("\(language): \(key)")
                }
            }
            check(missing.isEmpty,
                  "26.3 every reading has a translation in every language",
                  actual: missing.prefix(4).joined(separator: ", "), expected: "none missing")
        }




    }
}

/// Collects the two facts § 18 compares: which IOSurface each complete frame arrived on, and a
/// hash of what it looked like. Separate from the probe's own type because `SCStreamOutput`
/// conformance has to be on a class ScreenCaptureKit can hold.
///
/// **`nonisolated`, and the first version was not — it crashed.** This file compiles with
/// `-default-isolation MainActor`, mirroring the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION`, so
/// an unannotated method here is MainActor-isolated. ScreenCaptureKit calls
/// `stream(_:didOutputSampleBuffer:of:)` on its own delivery queue, and the isolation check traps:
/// `EXC_BREAKPOINT` inside `_checkExpectedExecutor`, read off the crash report rather than guessed
/// at. `Sources/Capture/MasterWriter.swift`'s own header states this exact hazard — "every append
/// happens on a ScreenCaptureKit delivery queue, where reaching a MainActor-isolated member traps
/// at runtime" — which is why every type in that file is `nonisolated` too.
///
/// **It is also why a scratch build of this measurement was not enough.** The same code, compiled
/// without `-default-isolation MainActor`, ran four times without complaint; the flag is the whole
/// difference, and it is the flag the shipping app builds with. A measurement taken outside the
/// app's language semantics is a measurement of something else.
/// Writes a two-frame 32×32 movie. Enough to have a video track, which is all
/// `ImportedRecording.stage` asks about, and small enough to cost nothing.
private func probeWriteTinyMovie(to url: URL) async -> Bool {
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_32BGRA])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var pixels: CVPixelBuffer?
    unsafe CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixels)
    for frame in 0..<2 {
        // Bounded: `isReadyForMoreMediaData` never returns to true once a writer has failed.
        var waited = 0
        while !input.isReadyForMoreMediaData, waited < 500 {
            try? await Task.sleep(for: .milliseconds(2)); waited += 1
        }
        if let pixels {
            adaptor.append(pixels, withPresentationTime:
                            CMTime(value: CMTimeValue(frame), timescale: 30))
        }
    }
    input.markAsFinished()
    await withCheckedContinuation { c in writer.finishWriting { c.resume() } }
    return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

/// Writes a short silent m4a — a file with sound and no picture, which is the case
/// `ImportedRecording` must refuse before it copies anything.
private func probeWriteTinyAudio(to url: URL) async -> Bool {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)
    else { return false }
    buffer.frameLength = 4800
    guard let file = try? AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
    ]) else { return false }
    try? file.write(from: buffer)
    return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

private nonisolated final class IdleFrameCollector: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var surfaces: [UInt32] = []
    private var hashes: [UInt64] = []
    private var completeWithoutSurface = 0

    func snapshot() -> (surfaces: [UInt32], hashes: [UInt64], noSurface: Int) {
        lock.withLock { (surfaces, hashes, completeWithoutSurface) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              (first[.status] as? Int) == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            lock.withLock { completeWithoutSurface += 1 }
            return
        }
        let id = IOSurfaceGetID(surface)
        let hash = Self.contentHash(of: pixelBuffer)
        lock.withLock { surfaces.append(id); hashes.append(hash) }
    }

    /// FNV-1a over every 64th byte. Not a checksum anybody trusts against an adversary — it is a
    /// same-or-different answer about two pictures a sixteenth of a second apart, and sampling is
    /// what keeps it cheap enough to run inside a 60 fps callback without changing what is being
    /// measured.

    private static func contentHash(of pixelBuffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 0xcbf29ce484222325
        var index = 0
        while index < byteCount {
            hash = (hash ^ UInt64(bytes[index])) &* 0x100000001b3
            index += 64
        }
        return hash
    }
}

/// Twelve seconds: still, moving, still — the fixture § 27 measures.
///
/// The still stretches append the identical buffer, so a change measure above zero there is
/// the encoder rather than the picture.
private func probeWriteStillMoveStill(to url: URL) async -> Bool {
    let width = 320, height = 240, frameRate = 10
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)

    func frame(blockX: Int) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        _ = unsafe CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        guard let buffer = created else { return nil }
        unsafe CVPixelBufferLockBaseAddress(buffer, [])
        defer { unsafe CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = unsafe CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = unsafe CVPixelBufferGetBytesPerRow(buffer)
        let bytes = unsafe base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * rowBytes + x * 4
                let value: UInt8 = (x >= blockX && x < blockX + 60) ? 240 : 20
                unsafe bytes[index] = value
                unsafe bytes[index + 1] = value
                unsafe bytes[index + 2] = value
                unsafe bytes[index + 3] = 255
            }
        }
        return buffer
    }

    for index in 0..<(12 * frameRate) {
        let seconds = Double(index) / Double(frameRate)
        let blockX = seconds < 4 ? 0 : (seconds < 8 ? Int((seconds - 4) * 60) : 240)
        guard let buffer = frame(blockX: blockX) else { return false }
        while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(1)) }
        adaptor.append(buffer, withPresentationTime:
                        CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return writer.status == .completed
}

// MARK: - § 28. what a recording costs in memory

/// This process's memory as macOS accounts for it.
///
/// **`phys_footprint`, not `resident_size`.** Resident size counts pages this process shares with
/// every other one and pages the kernel has not reclaimed yet, so it moves for reasons that have
/// nothing to do with the recording. Footprint is what Xcode's gauge shows and what the jetsam
/// killer reads — it is the number that decides whether a long recording survives.
private func probeMemoryFootprintBytes() -> Int64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                       / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Int64(info.phys_footprint)
}

private func probeMegabytes(_ bytes: Int64) -> Double { Double(bytes) / 1_048_576 }
