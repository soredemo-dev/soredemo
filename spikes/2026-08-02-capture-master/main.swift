// Spike B, extended for Task 8's human verification — three ORDERED, INDEPENDENT
// steps, not one combined run. Each is only meaningful once its predecessor is
// known good, and step 3 changes system state, so it must be last:
//
//   1. `video`    — the simplest thing that proves the AVAssetWriter path works
//                    at all: the file exists, plays, frame count is plausible,
//                    ContentScale == 1. No audio at all.
//   2. `audio`     — two audio sources, each carrying a distinguishable signal.
//                    Only meaningful once step 1 is known good.
//   3. `reconfig`  — display reconfiguration mid-recording. LAST: it changes the
//                    display's resolution, which would invalidate the
//                    conditions steps 1 and 2 ran under if it went first.
//
// This drives `CaptureSession` (Soredemo/Capture/CaptureSession.swift) — the
// real, unmodified type the product will use — instead of `SCRecordingOutput`,
// which the original Spike B (F2-4) measured as unusable at our floor: it
// mixes the microphone into the system-audio track.
//
// Needs Screen Recording (all three steps) and Microphone (step 2 only).
// Records to `~/Soredemo-Task8-Verification/` — see the task report for why
// that location, not `/tmp` or the bare home directory the original Spike B
// used. Delete that directory when done; nothing here cleans it up
// automatically, so the files are still there afterward to open and check by
// eye.

import AVFoundation
import AVFAudio
import AppKit
import ScreenCaptureKit
import CoreGraphics
import Darwin
import Foundation
import Timeline
import Project
import Geometry

// ------------------------------------------------------------- identity block
//
// AGENTS.md, added since the original Spike B: "Every output a human is asked
// to read starts with an identity block." Unlike the product
// (`Soredemo/App/BuildProvenance.swift`), this spike has no build-time commit
// injection — it is `swiftc`-compiled directly by `build.sh`, run once, and
// deleted. Reading `git rev-parse` at launch is therefore a reasonable
// simplification for a throwaway tool, not the product-grade answer
// `BuildProvenance`'s own doc comment insists on for `Soredemo.app` — labelled
// as such below so nobody mistakes one for the other.
func printIdentityBlock(step: String) {
    let bundle = Bundle.main
    let v = ProcessInfo.processInfo.operatingSystemVersion
    var commit = "unknown"
    let proc = Process()
    proc.executableURL = URL(filePath: "/usr/bin/git")
    proc.arguments = ["-C", URL(filePath: #filePath).deletingLastPathComponent().path(), "rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    if (try? proc.run()) != nil {
        proc.waitUntilExit()
        if let data = try? pipe.fileHandleForReading.readToEnd(), let s = String(data: data, encoding: .utf8) {
            commit = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    print("""
    ── Spike B / Task 8 verification — step: \(step) ──
    commit (read at launch, NOT baked — throwaway spike, not BuildProvenance): \(commit)
    macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)
    bundle identifier : \(bundle.bundleIdentifier ?? "nil")
    executable path   : \(bundle.executablePath ?? "nil")
    inside a .app     : \(bundle.bundlePath.hasSuffix(".app") ? "yes" : "no")
    pid               : \(ProcessInfo.processInfo.processIdentifier)
    ──
    """)
}

// A temporary directory, NOT the home directory. Standing constraint: a
// spike's capture output goes to temp only and is deleted afterwards —
// screen recordings and frame dumps never land somewhere a person keeps
// their own files, and never anywhere a `git add` could reach. Fixed after
// this file wrote ~/Soredemo-Task8-Verification for three runs.
//
// Not `NSTemporaryDirectory()` directly: `removeItem` on it at the start of
// each step would delete the whole per-user temp directory, including the
// scratch `.mov` files `CaptureSession` deliberately retains when a segment
// is discarded — the evidence this spike exists to collect.
let verificationDir = FileManager.default.temporaryDirectory
    .appending(path: "Soredemo-Task8-Verification", directoryHint: .isDirectory)
let packageDir = verificationDir.appending(path: "verify.soredemo", directoryHint: .isDirectory)

let tb: mach_timebase_info_data_t = {
    var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
}()
@inline(__always) func nowNs() -> UInt64 { mach_absolute_time() &* UInt64(tb.numer) / UInt64(tb.denom) }

func bootEpoch() -> BootEpoch {
    var size = 0
    sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
    precondition(size > 0, "kern.bootsessionuuid unavailable")
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0)
    let terminatorIndex = buf.firstIndex(of: 0) ?? buf.count
    let s = String(decoding: buf[..<terminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
    guard let id = UUID(uuidString: s) else { preconditionFailure("kern.bootsessionuuid not a UUID: \(s)") }
    return BootEpoch(id: id)
}

func displayUUID(for displayID: CGDirectDisplayID) -> UUID {
    guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
        preconditionFailure("CGDisplayCreateUUIDFromDisplayID returned nil for display \(displayID)")
    }
    let s = CFUUIDCreateString(nil, cfUUID) as String
    guard let uuid = UUID(uuidString: s) else { preconditionFailure("not a UUID: \(s)") }
    return uuid
}

// ---------------------------------------------------------------- analyse
//
// Kept from the original Spike B, unmodified in method — reused per the
// coordinator's instruction to read how it identified tones rather than
// inventing a second approach. What changed: tracks are identified by WHICH
// tone dominates, not by array index, because `AVAssetWriter.inputs` order
// is not a documented guarantee of file track order, and the coordinator's
// point stands regardless — "two tracks" is not "the right two tracks".
func goertzel(_ x: [Float], _ freq: Double, _ rate: Double) -> Double {
    guard x.count > 0 else { return 0 }
    let k = Int(0.5 + Double(x.count) * freq / rate)
    let w = 2.0 * Double.pi * Double(k) / Double(x.count)
    let c = 2.0 * cos(w)
    var s0 = 0.0, s1 = 0.0, s2 = 0.0
    for v in x { s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
    return sqrt(s1*s1 + s2*s2 - c*s1*s2) / Double(x.count)
}

struct TrackTones {
    let index: Int
    let rms: Double
    let a440: Double
    let a1k: Double
    let noise: Double
    var essentiallySilent: Bool { rms < 1e-3 }
    var has440: Bool { a440 > 1e-4 && a440 > noise * 4 }
    var has1k: Bool { a1k > 1e-4 && a1k > noise * 4 }
}

func readTones(track: AVAssetTrack, asset: AVAsset) throws -> TrackTones {
    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000.0,
    ]
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(o); reader.startReading()
    var samples: [Float] = []
    while let sb = o.copyNextSampleBuffer(), samples.count < 48000 * 6 {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &len, dataPointerOut: &ptr)
        if let p = ptr {
            p.withMemoryRebound(to: Float.self, capacity: len/4) { fp in
                samples.append(contentsOf: UnsafeBufferPointer(start: fp, count: len/4))
            }
        }
    }
    let rms = sqrt(samples.reduce(0) { $0 + Double($1*$1) } / Double(max(samples.count,1)))
    return TrackTones(index: 0, rms: rms,
                       a440: goertzel(samples, 440, 48000), a1k: goertzel(samples, 1000, 48000),
                       noise: goertzel(samples, 3000, 48000))
}

func analyse(_ url: URL) async throws {
    let asset = AVURLAsset(url: url)
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    print("file: \(url.path())")
    print("  duration \(try await CMTimeGetSeconds(asset.load(.duration))) s")
    print("  video tracks \(video.count), audio tracks \(audio.count)")
    for (i, t) in video.enumerated() {
        let sz = try await t.load(.naturalSize)
        print("    video[\(i)] \(Int(sz.width))x\(Int(sz.height))  nominalFrameRate \(try await t.load(.nominalFrameRate))")
        let desc = try await t.load(.formatDescriptions).first
        if let ext = desc.flatMap({ CMFormatDescriptionGetExtensions($0) as? [String: Any] }) {
            print("    video[\(i)] colour tag: primaries=\(ext[kCMFormatDescriptionExtension_ColorPrimaries as String] ?? "nil") " +
                  "transfer=\(ext[kCMFormatDescriptionExtension_TransferFunction as String] ?? "nil") " +
                  "matrix=\(ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] ?? "nil")")
        }
    }
    print()
    if audio.isEmpty { print("  NO AUDIO TRACK AT ALL."); return }
    for (i, t) in audio.enumerated() {
        let tones = try readTones(track: t, asset: asset)
        print("  audio[\(i)]  samples-limited-rms \(String(format:"%.5f", tones.rms))")
        print(String(format: "     440 Hz %.6f   1000 Hz %.6f   3000 Hz (ref) %.6f", tones.a440, tones.a1k, tones.noise))
        if tones.essentiallySilent {
            print("     ESSENTIALLY SILENT — no tone conclusion possible.")
        } else {
            print("     440 present: \(tones.has440)    1k present: \(tones.has1k)")
        }
    }
}

// ------------------------------------------------------------- shared setup

func requireScreenRecording() {
    guard CGPreflightScreenCaptureAccess() else {
        print("Screen Recording NOT granted.")
        _ = CGRequestScreenCaptureAccess()
        print("Grant it, then QUIT AND RELAUNCH — the grant does not apply to a running process.")
        exit(2)
    }
}

func firstDisplay() async throws -> SCDisplay {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else { print("no display"); exit(3) }
    return display
}

nonisolated(unsafe) var displayReconfigurations = 0
// `nonisolated` — same reason as `CaptureSession.reconfigurationCallback`
// (see that type's own doc comment): under this build's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an unannotated top-level
// function is implicitly `@MainActor`, and `CGDisplayRegisterReconfigurationCallback`
// needs a plain, context-free C function pointer — confirmed by compiling
// this file, "a C function pointer can only be formed from a reference to a
// 'func' or a literal closure" until this was added.
nonisolated func reconfigCallback(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                      _ userInfo: UnsafeMutableRawPointer?) {
    if !flags.contains(.beginConfigurationFlag) {
        displayReconfigurations += 1
        print("  *** display \(id) reconfigured, flags 0x\(String(flags.rawValue, radix: 16))")
    }
}

func printDiagnostics(_ d: CaptureSession.Diagnostics) {
    print("  frame status counts \(d.frameStatusCounts)  (0=complete,1=idle,2=blank,3=suspended,4=started,5=stopped)")
    print("  complete frames: \(d.completeFrameCount)   ContentScale checked: \(d.contentScaleCheckedCount)   " +
          "resampled (ContentScale != 1): \(d.resampledFrameCount)")
    if let lo = d.minContentScaleObserved, let hi = d.maxContentScaleObserved {
        print("  ContentScale observed range: \(lo) ... \(hi)")
    }
    if !d.ptsToCallbackLatencyNanos.isEmpty {
        let s = d.ptsToCallbackLatencyNanos.sorted()
        func p(_ q: Double) -> Double { Double(s[min(Int(Double(s.count)*q), s.count-1)]) / 1e6 }
        print(String(format: "  PTS->callback  p50 %.2f ms  p90 %.2f ms  max %.2f ms  (n=%d)",
                     p(0.5), p(0.9), Double(s.last!)/1e6, s.count))
    }
    // Printed UNCONDITIONALLY, including when it is zero. The other
    // conditional lines above are ranges and lists that read as noise when
    // empty; this one is a count of frames the OS delivered and the session
    // threw away. Printed only when non-zero, its absence would be
    // indistinguishable from "this build does not report it" — and a reader
    // six weeks from now cannot tell those apart.
    // "complete frames" is about the STREAM. These are about the FILE. They
    // were one number until a run reported 309 complete frames over a
    // zero-byte file.
    print("  video appends accepted: \(d.appendedVideoFrameCount)   refused: \(d.failedVideoAppendCount)")
    print("  audio appends accepted: \(d.appendedAudioSampleCount)   refused: \(d.failedAudioAppendCount)")
    if let first = d.firstAppendFailure { print("  FIRST append failure: \(first)") }
    print("  complete frames dropped, PTS not convertible: \(d.unconvertiblePresentationTimeCount)")
    // A conservation law, not a diagnostic. Two numbers in a report have to
    // be compared by a person; this one is compared by the machine, every run.
    print("  FRAME ACCOUNTING: \(d.frameAccounting)")
    if !d.everyCompleteFrameIsAccountedFor {
        print("  ^^ DOES NOT BALANCE — a frame left handleScreenSample by a path nothing counts. " +
              "That is the exact hiding place of the defect this check exists for.")
    }
    // Measured, not inferred. The claim "ScreenCaptureKit delivers planar
    // audio" was reached by matching an error code; this is the OS saying so.
    print("  system audio layout: \(d.systemAudioLayout ?? "(no system audio buffer arrived)")")
    print("  microphone layout:   \(d.microphoneLayout ?? "(no microphone buffer arrived)")")
    print("  system audio  \(d.systemAudioAccounting.accounting)")
    print("  microphone    \(d.microphoneAccounting.accounting)")
    for (name, a) in [("system audio", d.systemAudioAccounting), ("microphone", d.microphoneAccounting)] {
        if !a.balances {
            print("  ^^ \(name) DOES NOT BALANCE — a buffer left appendAudio by a path nothing counts.")
        }
        if a.deliveredButWroteNothing {
            print("  ^^ \(name): \(a.delivered) buffers delivered, NONE written. That track will be " +
                  "absent from the file, and this line is the only place it says so before you open it.")
        }
    }
    print("  frames whose ContentRect could not be decoded: \(d.unreadableContentRectCount)   " +
          "ScreenRect: \(d.unreadableScreenRectCount)")
    print("  segments discarded (media never reached the package): \(d.discardedSegments.count)")
    for s in d.discardedSegments {
        print("    - \(s.mediaFilename)  writer status: \(s.writerStatus)")
        print("      writer error: \(s.writerError)")
        print("      bytes retained at: \(s.retainedScratchPath)")
    }
    if !d.blackFrameDetections.isEmpty {
        print("  black-frame detections (LOGGED ONLY, uncalibrated threshold — see CaptureSession doc comment): \(d.blackFrameDetections)")
    }
}

// ------------------------------------------------------------- Step 1: video

func runVideoOnly(seconds: Int) async throws {
    printIdentityBlock(step: "1 — video only, no audio, WINDOW capture (D2-13a)")
    print("""
    Expect BEFORE running:
      - a real NSWindow this process creates, deliberately SMALLER than the
        display, is what gets captured — NOT the display itself. Capturing
        the whole display would make ContentScale == 1 NECESSARILY true (the
        buffer IS the display, nothing to scale) — the identity element of
        the exact transform this step checks, which would pass for the wrong
        reason. D2-13a only has content when the window is smaller than a
        display-sized buffer: padded, not resampled.
          source        .window
          bufferSize    the display's own native pixels (NOT the window's)
          contentRect   the window's own frame, SMALLER than bufferSize
      - a file named master-00.mov appears under \(packageDir.appending(path: "media").path())
      - it opens and plays in QuickTime Player: a solid blue rectangle (the
        window) surrounded by black padding (the display-sized buffer) — that
        padding IS D2-13a's decision, on screen, worth more than the number
      - frame count is roughly \(seconds) * (some rate <= 60fps — a floor, not a cadence, F2-4)
      - printed as ONE pass/fail statement, not a percentage: "checked N
        frames, N > 0, of which N had ContentScale == 1" — a checked count of
        ZERO must FAIL this check, not satisfy it (a vacuous pass over an
        empty set is exactly what Tests/DeterminismTests' own
        `#require(!objectFiles.isEmpty, …)` guards against for the symbol
        check, and what an assertion that only compared min/max against 1
        would silently be if no frame's ContentScale were ever readable)
      - the printed colour tag is 709/709/709 primaries (the D2-15 placeholder pin)
    """)
    requireScreenRecording()
    try? FileManager.default.removeItem(at: verificationDir)

    let display = try await firstDisplay()
    let scale = 2.0

    // A real, on-screen window, deliberately smaller than the display in
    // both dimensions, filled with a solid, distinctive colour so the
    // padding is obvious to the eye once the file is opened.
    let testWindow = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 800, height: 500),
                               styleMask: [.titled], backing: .buffered, defer: false)
    testWindow.title = "Soredemo Task 8 Step 1 — smaller than the display, on purpose"
    testWindow.backgroundColor = .systemBlue
    testWindow.isReleasedWhenClosed = false
    testWindow.makeKeyAndOrderFront(nil)
    // Same technique, and same reason, as
    // scripts/cross-boundary-digest-probe.swift's captureSourceGeometry():
    // a moment for the window to register with the window server before
    // SCShareableContent can see it — measured to work there, reused here.
    try await Task.sleep(for: .milliseconds(500))

    let content = try await SCShareableContent.currentProcess
    guard let scWindow = content.windows.first(where: { $0.title == testWindow.title }) else {
        print("FAIL — the test window did not appear in SCShareableContent.currentProcess; cannot proceed.")
        exit(6)
    }

    // D2-13a: the buffer is sized to the DISPLAY's own native pixels, not
    // the window's. `display.width`/`.height` are points
    // (`SCShareableContent.h`) — the same multiplication
    // `CaptureSource.geometry()` performs for the `.display` case, mirrored
    // here for the BUFFER, never for the digest (the window's own frame
    // stays extrinsic — see `CaptureSource.swift`'s own header).
    let bufferSize = (width: Int((Double(display.width) * scale).rounded()),
                       height: Int((Double(display.height) * scale).rounded()))
    print("display (points): \(display.width)x\(display.height)  scale: \(scale)  " +
          "buffer (pixels): \(bufferSize.width)x\(bufferSize.height)")
    print("window content rect (points): \(Int(testWindow.frame.width))x\(Int(testWindow.frame.height)) " +
          "— must be SMALLER than the buffer above (in the same units) for this check to mean anything")
    guard Double(testWindow.frame.width) * scale < Double(bufferSize.width),
          Double(testWindow.frame.height) * scale < Double(bufferSize.height) else {
        print("FAIL — the test window is not smaller than the display-sized buffer on this machine; " +
              "the ContentScale check below would be vacuous (the identity-transform case this step exists " +
              "to avoid). Shrink the window in this file and re-run.")
        exit(7)
    }

    let source = CaptureSource.window(scWindow, bufferSize: bufferSize)
    // A per-selection identity, not a real display UUID — the same reuse
    // `CaptureSource.geometry()`'s own doc comment documents for `.window`,
    // and the same pattern `scripts/cross-boundary-digest-probe.swift`'s
    // §5 uses for its own `.window` fixtures.
    let windowSourceIdentity = UUID()
    let session = CaptureSession(source: source, scale: scale, displayUUID: windowSourceIdentity,
                                  packageURL: packageDir, epoch: bootEpoch())
    // ---- EXPECTATION TABLE, computed and printed BEFORE the recording ----
    //
    // Every value below is derived from the configuration, not chosen by
    // hand. The three identity-element mistakes this project has made in
    // expectation tables (a scale of 1, a `tooNew` fixture at the wrong
    // identity, recording a display where ContentScale == 1 is necessarily
    // true) were all hand-written guesses in a table written by the person
    // who knew the implementation. A derived table cannot degrade into "a
    // black bar was visible, so it passed".
    let expected = source.destinationRect(scale: scale)
    print("""

    ---- EXPECTED, computed before recording ----
      buffer (pixels)            \(bufferSize.width) x \(bufferSize.height)
      destinationRect being set  x \(Int(expected.x)) y \(Int(expected.y)) \
    w \(Int(expected.width)) h \(Int(expected.height))
      content will span          x ∈ [\(Int(expected.x)), \(Int(expected.x + expected.width))], \
    y ∈ [\(Int(expected.y)), \(Int(expected.y + expected.height))]
      right-edge samples at      x = \(Int(expected.x + expected.width) - 4) (inside, NOT black) \
    and \(Int(expected.x + expected.width) + 4) (outside, black)
      per-frame contentRect      must come back as \(Int(expected.width / scale)) x \
    \(Int(expected.height / scale)) points at (\(Int(expected.x / scale)), \(Int(expected.y / scale)))
      ContentScale               1.0 on every frame — the destination matches the source size,
                                 so there is nothing to resample
      frame accounting           must balance, and every audio track's too
    ---------------------------------------------
    """)

    try await session.start()
    print("\nrecording \(seconds)s, video only, WINDOW capture, to \(packageDir.path()) ...")
    for s in stride(from: seconds, to: 0, by: -5) {
        try await Task.sleep(for: .seconds(min(5, s)))
        print("  t-\(max(0, s-5))s  \(session.diagnostics.completeFrameCount) complete frames so far")
    }
    // `stop()` returns `CaptureSession.Outcome`, not a bare `SegmentTable`,
    // so this switch is the type making the reader state which case they are
    // in. Reading `table` without it is no longer possible — which is the
    // whole point, because the run that produced this fix printed a perfectly
    // well-formed table for a segment whose file did not exist.
    let outcome = try await session.stop()
    testWindow.orderOut(nil)
    let table: SegmentTable
    switch outcome {
    case .complete(let t):
        table = t
    case .incomplete(let t, let discarded):
        table = t
        print("\nINCOMPLETE — \(discarded.count) segment(s) never reached the package. " +
              "The table below is what was recorded, not what was saved.")
    }

    print("\n--- step 1 result ---")
    print("segments: \(table.segments.count)  first mediaFilename: \(table.segments.first?.mediaFilename ?? "none")")
    printDiagnostics(session.diagnostics)

    // The non-vacuous assertion, as ONE statement covering the count and
    // the claim together — a checked count of zero FAILS, it does not
    // silently satisfy the "all frames had ContentScale == 1" claim.
    let checked = session.diagnostics.contentScaleCheckedCount
    let passing = checked - session.diagnostics.resampledFrameCount
    if checked == 0 {
        print("\nFAIL — checked 0 frames for ContentScale. Zero is not a pass; nothing was verified.")
    } else if passing == checked {
        // The subject is named in the sentence, deliberately. The previous
        // wording — "PASS — checked 112 frames, 112 > 0, of which 112 had
        // ContentScale == 1" — was true of a run whose output file was zero
        // bytes. Every frame the STREAM delivered was unresampled; not one
        // of them reached a FILE. Both halves have to appear or the pass
        // reads as something it never claimed.
        print("\nPASS (about the STREAM, not the file) — of the frames ScreenCaptureKit delivered, " +
              "checked \(checked), \(checked) > 0, of which \(passing) had ContentScale == 1.")
        print("Whether any of them were written is the `video appends accepted` line above, " +
              "and whether the file exists is the check below.")
    } else {
        print("\nFAIL — checked \(checked) frames, of which only \(passing) had ContentScale == 1 " +
              "(\(checked - passing) were resampled). The master was NOT unresampled here — see D2-8.")
    }

    let mediaURL = packageDir.appending(path: "media/master-00.mov")
    // Checked rather than left to `analyse` throwing out of `main`. When the
    // file was missing, the top-level error was an AVFoundation -11800 about
    // `assetProperty_Tracks` — which reads as "the movie is malformed" and
    // sent the first diagnosis at the writer. The file did not exist at all.
    guard FileManager.default.fileExists(atPath: mediaURL.path()) else {
        print("\nFAIL — no file at \(mediaURL.path()). The recording did not reach the package. " +
              "The `segments discarded` lines above say why; if that count is 0 too, then nothing " +
              "in this process knows, which is itself the finding.")
        exit(8)
    }
    try await analyse(mediaURL)
    try await checkPaddingGeometry(mediaURL, contentRect: session.diagnostics.lastContentRect,
                                   scale: scale, bufferSize: bufferSize,
                                   chosen: session.diagnostics.configuredDestinationRect)
    print("\nOptional, and NOT the check: open \"\(mediaURL.path())\" if you want to see it. " +
          "The eye is good at noticing things and bad at confirming them — the padding was verified " +
          "against computed coordinates above, not by looking.")
}


// ------------------------------------------------- padding, measured

/// Verifies that the black padding is where D2-13a's buffer layout says it
/// is — not merely that black padding exists.
///
/// **Why the eye is the wrong instrument here.** "I can see black bars" is
/// satisfied by a frame whose content starts 40 px from where `contentRect`
/// claims. The picture looks exactly as expected and the mapping is wrong,
/// which is the failure that matters: every later derivation reads
/// `contentRect` to locate the window inside the buffer. This project has
/// been caught three times by something that looked right — colour
/// saturation, a picker tab that was not there, a Settings pane showing a
/// grant that the API refused. Looking is for finding; measuring is for
/// confirming.
///
/// The check samples FOUR points, and the pairs are what make it fail when
/// the mapping is off:
///   * well inside the padding, and well inside the content — the weak
///     check, which "there are black bars" already satisfies;
///   * a few pixels either side of a content edge computed from
///     `contentRect × scale` — one must be black and the other must not. A
///     content rectangle displaced in either direction breaks exactly one of
///     those two, which is the whole point of straddling the edge.
///
/// **Which edge is not a free choice, and the first version got it wrong.**
/// It straddled the LEFT edge unconditionally. Measured, ScreenCaptureKit
/// anchors window content at the buffer's origin — `contentRect` came back
/// as `(0, 0) 800x532` in a 3024x1964 buffer — so there is no left padding
/// at all; all of it is to the right and below. The old guard then printed
/// "the content spans the full buffer width", which was simply false (1600
/// of 3024) and would have sent the next reader after the wrong thing. The
/// edge under test is now chosen from where the padding actually is, and the
/// refusal message says which edges were considered.
func checkPaddingGeometry(_ url: URL, contentRect: PointRect?, scale: Double,
                          bufferSize: (width: Int, height: Int),
                          chosen: PixelRect?) async throws {
    print("\n--- padding geometry, measured against contentRect ---")
    guard let contentRect else {
        print("FAIL — no ContentRect was ever read from a frame attachment, so there is nothing to " +
              "check the padding AGAINST. Black bars alone would not be a finding.")
        return
    }
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = false
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let (cgImage, _) = try await generator.image(at: CMTime(value: 1, timescale: 2))

    // `contentRect` is in points (D2-13a: it is the window's own frame, the
    // extrinsic mapping); the buffer is in pixels. One multiplication, the
    // same one `CaptureSource.geometry()` performs, stated here so the
    // number being checked has a derivation and not just a value.
    let left = Int((contentRect.x * scale).rounded())
    let right = Int(((contentRect.x + contentRect.width) * scale).rounded())
    let top = Int((contentRect.y * scale).rounded())
    let bottom = Int(((contentRect.y + contentRect.height) * scale).rounded())
    print("contentRect (points): origin (\(contentRect.x), \(contentRect.y)) " +
          "size \(contentRect.width)x\(contentRect.height)")
    print("buffer (pixels): \(bufferSize.width)x\(bufferSize.height)   " +
          "content spans x ∈ [\(left), \(right)], y ∈ [\(top), \(bottom)] after × \(scale)")
    guard cgImage.width == bufferSize.width, cgImage.height == bufferSize.height else {
        print("FAIL — decoded frame is \(cgImage.width)x\(cgImage.height), not the " +
              "\(bufferSize.width)x\(bufferSize.height) buffer the coordinates above are in. " +
              "Every sample below would be at the wrong place.")
        return
    }

    // **The contract check, and it is stronger than the pixel sampling
    // below.** `destinationRect` is no longer inherited from
    // ScreenCaptureKit's undocumented placement — `CaptureSource` chooses it.
    // So the window's reported `contentRect`, scaled to pixels, must equal
    // the rectangle we asked for. Sampling pixels can only show that SOME
    // edge is where SOME rectangle says; this shows it is where OURS says.
    // TWO INDEPENDENT SOURCES, and the check is worthless without that:
    //   `configuredDestinationRect` — recorded by CaptureSession at the moment
    //       it set the value. What was ASKED.
    //   `contentRect` — per-frame SCStreamFrameInfoContentRect. What SCK
    //       DELIVERED.
    // Recomputing the request here from `SCWindow.frame` would compare a
    // calculation against its own inputs: an assertion that cannot fail,
    // reported as the strongest check passing.
    guard let chosen else {
        print("FAIL — the session never recorded a configured destinationRect, so there is nothing " +
              "to compare the delivered contentRect against.")
        return
    }
    let matchesChosen = left == Int(chosen.x) && top == Int(chosen.y)
        && right == Int(chosen.x + chosen.width) && bottom == Int(chosen.y + chosen.height)
    print("destinationRect ASKED FOR (recorded at configure time): x \(Int(chosen.x)) y \(Int(chosen.y)) " +
          "w \(Int(chosen.width)) h \(Int(chosen.height))")
    print("  \(matchesChosen ? "ok  " : "FAIL") the per-frame contentRect × scale equals it — " +
          "ScreenCaptureKit honoured the anchor this process chose")

    // The margin each vertical edge has outside it. `nil` means that edge is
    // flush against the buffer and cannot be straddled.
    let margin = 8
    let leftPadding = left >= margin ? left : nil
    let rightPadding = right <= bufferSize.width - margin ? bufferSize.width - right : nil
    guard leftPadding != nil || rightPadding != nil else {
        print("FAIL — content is flush against BOTH vertical edges of the buffer " +
              "(left \(left), right \(right), buffer width \(bufferSize.width)), so there is no " +
              "vertical edge with padding beside it. This check would pass vacuously — which is " +
              "exactly the identity-transform case D2-13a's ContentScale check also has to avoid.")
        return
    }
    // Prefer the right edge when both have padding, because the measured
    // layout puts all of it there — but state which was used, so a future
    // run against a differently-anchored buffer is not silently checking
    // something else.
    let (edgeName, edgeX, outsideDirection) = rightPadding != nil
        ? ("RIGHT", right, 1)
        : ("LEFT", left, -1)
    print("padding is beside the \(edgeName) edge (left margin " +
          "\(leftPadding.map(String.init) ?? "none"), right margin " +
          "\(rightPadding.map(String.init) ?? "none")) — straddling x=\(edgeX)")

    // Sample row: the vertical middle of the content, so the horizontal
    // edges are the only thing under test.
    let y = (top + bottom) / 2
    guard let samples = sampleRow(cgImage, y: min(max(y, 0), cgImage.height - 1)) else {
        print("FAIL — could not read pixels from the decoded frame.")
        return
    }
    func isBlack(_ x: Int) -> Bool {
        let p = samples[min(max(x, 0), samples.count - 1)]
        return p.r < 12 && p.g < 12 && p.b < 12
    }
    let farPadding = outsideDirection > 0 ? (edgeX + bufferSize.width) / 2 : edgeX / 2
    let farContent = (left + right) / 2
    let justOutside = edgeX + 4 * outsideDirection
    let justInside = edgeX - 4 * outsideDirection

    let checks: [(String, Bool)] = [
        ("padding at x=\(farPadding) (well outside the window) is black", isBlack(farPadding)),
        ("content at x=\(farContent) (well inside the window) is NOT black", !isBlack(farContent)),
        ("x=\(justOutside), 4 px OUTSIDE the computed \(edgeName) edge, is black", isBlack(justOutside)),
        ("x=\(justInside), 4 px INSIDE the computed \(edgeName) edge, is NOT black", !isBlack(justInside)),
    ]
    for (what, ok) in checks { print("  \(ok ? "ok  " : "FAIL") \(what)") }
    print(checks.allSatisfy { $0.1 } && matchesChosen
          ? "PASS — the padding is where contentRect × scale says it is, not merely present. " +
            "Content is anchored at the buffer origin; the padding is to the \(edgeName.lowercased())."
          : "FAIL — padding exists but is not at the computed boundary. The buffer layout and " +
            "contentRect disagree; D2-13a's mapping is what is wrong, not the picture.")
}

func sampleRow(_ image: CGImage, y: Int) -> [(r: Int, g: Int, b: Int)]? {
    let width = image.width
    var bytes = [UInt8](repeating: 0, count: width * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let ok: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        // Draw the whole image translated so that row `y` lands on row 0 of
        // this 1-pixel-tall context. CoreGraphics' origin is bottom-left, so
        // the offset is measured from the bottom.
        ctx.draw(image, in: CGRect(x: 0, y: -(CGFloat(image.height - 1 - y)),
                                   width: CGFloat(width), height: CGFloat(image.height)))
        return true
    }
    guard ok else { return nil }
    return (0..<width).map { (Int(bytes[$0 * 4]), Int(bytes[$0 * 4 + 1]), Int(bytes[$0 * 4 + 2])) }
}

// ------------------------------------------------------------- Step 2: audio

func runAudioTones(seconds: Int) async throws {
    printIdentityBlock(step: "2 — two audio sources, distinguishable tones")
    print("""
    Expect BEFORE running:
      - track identified as "system" contains 440 Hz and NOT 1 kHz
      - track identified as "mic" contains 1 kHz and NOT 440 Hz
      - i.e. FOUR assertions, not a track count — see the coordinator's note in
        the task report for why a count alone cannot tell separation from
        duplication or from a dropped track
    You must, while this runs:
      - let it play 440 Hz itself (done automatically, from this process)
      - hold a phone playing a steady 1 kHz tone NEAR THE MICROPHONE
    """)
    requireScreenRecording()

    let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
    let micNames: [AVAuthorizationStatus: String] =
        [.notDetermined: "notDetermined", .restricted: "restricted", .denied: "denied", .authorized: "authorized"]
    print("microphone authorization: \(micNames[micAuth] ?? "?")")
    if micAuth == .notDetermined {
        print("  requesting…")
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        print("ABORTING — without microphone access this experiment cannot be read (one silent track " +
              "would be indistinguishable from a real 'mic dropped' result). Grant it and re-run.")
        exit(4)
    }

    print("\nChecking the microphone is actually receiving signal before spending \(seconds)s…")
    print("PLAY THE 1 kHz TONE NEAR THE MIC NOW.")
    let probeEngine = AVAudioEngine()
    var micRMS = 0.0
    probeEngine.inputNode.installTap(onBus: 0, bufferSize: 4096,
                                     format: probeEngine.inputNode.outputFormat(forBus: 0)) { buf, _ in
        guard let d = buf.floatChannelData?[0] else { return }
        var sum = 0.0
        for i in 0..<Int(buf.frameLength) { sum += Double(d[i] * d[i]) }
        micRMS = max(micRMS, sqrt(sum / Double(max(buf.frameLength, 1))))
    }
    try probeEngine.start()
    for i in (1...8).reversed() {
        try await Task.sleep(for: .seconds(1))
        print(String(format: "  %ds  mic peak rms %.5f", i, micRMS))
    }
    probeEngine.stop(); probeEngine.inputNode.removeTap(onBus: 0)
    guard micRMS > 0.01 else {
        print("ABORTING — the microphone is receiving essentially nothing (peak rms " +
              "\(String(format: "%.5f", micRMS))); a recording made now could not distinguish 'mixed/dropped' " +
              "from 'no tone was played'. Play the tone and re-run.")
        exit(5)
    }
    print("  mic is live (peak rms \(String(format: "%.4f", micRMS))) — proceeding\n")

    try? FileManager.default.removeItem(at: verificationDir)
    let display = try await firstDisplay()
    let source = CaptureSource.display(display)
    let session = CaptureSession(source: source, scale: 2.0, displayUUID: displayUUID(for: display.displayID),
                                  packageURL: packageDir, epoch: bootEpoch())

    // 440 Hz generated by this process itself — one fewer human step, and
    // removes the run-3-of-four failure mode the original Spike B hit
    // (nothing playing at all, "both tones" reported present in silence).
    let engine = AVAudioEngine()
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    var phase = 0.0
    let src = AVAudioSourceNode { _, _, frameCount, abl in
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        let inc = 2.0 * Double.pi * 440.0 / 48000.0
        for f in 0..<Int(frameCount) {
            let v = Float(sin(phase) * 0.25); phase += inc
            if phase > 2 * .pi { phase -= 2 * .pi }
            for b in bufs { b.mData!.assumingMemoryBound(to: Float.self)[f] = v }
        }
        return noErr
    }
    engine.attach(src)
    engine.connect(src, to: engine.mainMixerNode, format: fmt)
    try engine.start()
    print("playing 440 Hz from this process (captured as system audio)")

    try await session.start()
    print("recording \(seconds)s, video + system audio + microphone, to \(packageDir.path()) ...")
    for s in stride(from: seconds, to: 0, by: -5) {
        try await Task.sleep(for: .seconds(min(5, s)))
        print("  t-\(max(0, s-5))s  \(session.diagnostics.completeFrameCount) complete frames so far")
    }
    engine.stop()
    let table: SegmentTable
    switch try await session.stop() {
    case .complete(let t): table = t
    case .incomplete(let t, let discarded):
        table = t
        print("\nINCOMPLETE — \(discarded.count) segment(s) never reached the package.")
        for d in discarded { print("  \(d.mediaFilename): \(d.writerStatus) — \(d.writerError)") }
    }
    print("\n--- step 2 result ---")
    print("segments: \(table.segments.count)")
    printDiagnostics(session.diagnostics)

    let mediaURL = packageDir.appending(path: "media/master-00.mov")
    let asset = AVURLAsset(url: mediaURL)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    print("audio tracks: \(audioTracks.count)")
    guard audioTracks.count == 2 else {
        print("FAIL — expected 2 audio tracks, got \(audioTracks.count). Cannot run the four tone assertions.")
        try await analyse(mediaURL)
        return
    }
    let tones = try audioTracks.enumerated().map { i, t -> TrackTones in
        let raw = try readTones(track: t, asset: asset)
        return TrackTones(index: i, rms: raw.rms, a440: raw.a440, a1k: raw.a1k, noise: raw.noise)
    }
    for t in tones {
        print("  track[\(t.index)] rms \(String(format: "%.5f", t.rms))  " +
              "440=\(String(format: "%.6f", t.a440)) 1k=\(String(format: "%.6f", t.a1k)) ref=\(String(format: "%.6f", t.noise))  " +
              "silent=\(t.essentiallySilent)")
    }
    // Identify by WHICH tone dominates, not by array index (the coordinator's
    // point: `AVAssetWriter.inputs` order is not a documented guarantee of
    // file track order).
    guard let systemTrack = tones.first(where: { $0.has440 && !$0.has1k }),
          let micTrack = tones.first(where: { $0.has1k && !$0.has440 }),
          systemTrack.index != micTrack.index else {
        print("FAIL — could not identify one track as 440-only and a DIFFERENT track as 1k-only. " +
              "Read the per-track numbers above: this is either mixing, a dropped source, or a silent track.")
        return
    }
    print("\nFOUR ASSERTIONS:")
    print("  track \(systemTrack.index) (system) contains 440 Hz:       \(systemTrack.has440)")
    print("  track \(systemTrack.index) (system) does NOT contain 1kHz: \(!systemTrack.has1k)")
    print("  track \(micTrack.index) (mic) contains 1 kHz:              \(micTrack.has1k)")
    print("  track \(micTrack.index) (mic) does NOT contain 440 Hz:     \(!micTrack.has440)")
    let allPass = systemTrack.has440 && !systemTrack.has1k && micTrack.has1k && !micTrack.has440
    print(allPass ? "PASS — system audio and microphone are independent tracks." : "FAIL — see above.")
}

// --------------------------------------------------------- Step 3: reconfig

func runReconfig(seconds: Int) async throws {
    printIdentityBlock(step: "3 — display reconfiguration (LAST — changes system state)")
    print("""
    Expect BEFORE running:
      - at roughly the midpoint, you will change this display's resolution in
        System Settings -> Displays
      - the recording produces >= 2 segments in the returned SegmentTable
      - the segment before the change has endedBy == .displayReconfigured(...)
      - the two segments carry DIFFERENT GeometryRevision values
      - diagnostics.displayReconfigurationsHandled >= 1
    This step changes your display's resolution. Change it back afterward if
    it does not revert on its own.
    """)
    requireScreenRecording()
    try? FileManager.default.removeItem(at: verificationDir)
    let display = try await firstDisplay()
    let source = CaptureSource.display(display)
    let session = CaptureSession(source: source, scale: 2.0, displayUUID: displayUUID(for: display.displayID),
                                  packageURL: packageDir, epoch: bootEpoch())
    CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)
    try await session.start()
    print("recording \(seconds)s. CHANGE THIS DISPLAY'S RESOLUTION at roughly the midpoint.")
    for s in stride(from: seconds, to: 0, by: -5) {
        try await Task.sleep(for: .seconds(min(5, s)))
        print("  t-\(max(0, s-5))s  \(session.diagnostics.completeFrameCount) complete frames, " +
              "OS-level reconfigurations observed: \(displayReconfigurations)")
    }
    let table: SegmentTable
    switch try await session.stop() {
    case .complete(let t): table = t
    case .incomplete(let t, let discarded):
        table = t
        print("\nINCOMPLETE — \(discarded.count) segment(s) never reached the package.")
        for d in discarded { print("  \(d.mediaFilename): \(d.writerStatus) — \(d.writerError)") }
    }
    print("\n--- step 3 result ---")
    print("segments: \(table.segments.count)")
    for seg in table.segments {
        print("  [\(seg.index)] \(seg.mediaFilename)  revision=\(seg.revision)  endedBy=\(seg.endedBy)")
    }
    printDiagnostics(session.diagnostics)
    if displayReconfigurations == 0 {
        print("\n-> the display was NOT reconfigured during this run — the experiment did not happen, not a finding.")
    } else if table.segments.count < 2 {
        print("\nFAIL — the OS reported \(displayReconfigurations) reconfiguration(s) but the session produced " +
              "only \(table.segments.count) segment(s). Expected a split.")
    } else {
        let revisions = Set(table.segments.map(\.revision))
        print(revisions.count > 1
              ? "PASS — segments carry \(revisions.count) distinct GeometryRevisions."
              : "FAIL — segments split but all carry the SAME revision.")
    }
}

@main enum SpikeB {
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // a crash must not swallow the log
        let args = CommandLine.arguments
        switch args.count > 1 ? args[1] : "" {
        case "video":
            try await runVideoOnly(seconds: 20)
        case "audio":
            try await runAudioTones(seconds: 30)
        case "reconfig":
            try await runReconfig(seconds: 40)
        case "analyse":
            try await analyse(args.count > 2 ? URL(filePath: args[2])
                               : packageDir.appending(path: "media/master-00.mov"))
        default:
            print("usage: SoredemoSpikeB <video|audio|reconfig|analyse [path]>")
            print("Run in THIS order: video, then audio, then reconfig — see the file header.")
            exit(1)
        }
    }
}
