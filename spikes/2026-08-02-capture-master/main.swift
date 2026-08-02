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
/// The identity block, the expectation table and the positive control now
/// live in `spikes/shared/VerificationStep.swift`. Tasks 6, 7 and 8 each grew
/// their own copy; four more manual steps are coming, and the seventh
/// re-derivation is a worse time to notice than the fourth.
let repositoryPath = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path()

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

/// **Relative, not absolute.** The previous version was
/// `a440 > 1e-4 && a440 > noise * 4` — half absolute threshold, half ratio,
/// and the absolute half is unreadable: amplitude moves with the output
/// volume, the microphone's gain, and how far the phone is from the mic, and
/// this process controls none of the three. Only the ratio of the target
/// frequency to the surrounding noise floor is stable across those.
///
/// **The floor is a median of five bins, not one.** A single reference bin
/// can land near zero by chance, and dividing by it produces a huge ratio
/// from nothing — the last step-1 run had a 3 kHz reference of 0.000003,
/// which would make a silent 1 kHz bin read as "7× the floor" purely from
/// arithmetic noise. The five bins below are deliberately **not** harmonics
/// of either tone: 440's harmonics fall on 880/1320/1760/2200/2640/3080…,
/// 1000's on 2000/3000/4000/5000…, and a reference bin sitting on a harmonic
/// would measure the tone it is supposed to be a baseline for.
let referenceFrequencies: [Double] = [1523, 2717, 4231, 6133, 7549]

/// **The separation criterion, and its subject is a track — not a frequency
/// bin.**
///
/// The first version asked "is 440 Hz detectable in the microphone track,
/// relative to the noise floor?" and that question has the wrong subject.
/// 440 Hz IS detectable there: headphones leak, and leakage is physics. The
/// question the four assertions exist to answer is whether the two tracks
/// are *separate or mixed*, and that is a comparison **inside one track**,
/// between the tone that belongs to it and the tone that does not.
///
/// The two regimes are not adjacent, and neither number is chosen:
///   * acoustic leakage, measured across four runs on this setup — with
///     headphones the foreign tone lands between 1/1400 and 1/2138 of the
///     native one in the microphone track, and between 1/6570 and 1/16765 in
///     the system track. With the headphones off it was **1/1**, which is
///     why the acoustic condition is now a precondition rather than a
///     result;
///   * a range, not one figure, deliberately: a single number would read as
///     a property of the code, and this is a property of a room. The
///     pre-flight gate measured 1/174 in the same session whose recording
///     measured 1/1400 — the eight-second window falls while the tone source
///     is still being positioned, so the gate is pessimistic. That is the
///     safe direction, but it is observed, not designed: the gate's own
///     margin was 1.7x where the recording's was 14x;
///   * genuine mixing — both sources are summed into one track, so the two
///     tones sit within about 1/1 to 1/10 of each other.
/// Three orders of magnitude separate them, so `1/100` is a line drawn in
/// empty space rather than fitted to either side. The old `20×` had no such
/// derivation, and it decided assertion 4 by a 20% margin.
let foreignToneCeiling = 1.0 / 100.0

/// A tone counts as present at 20× the floor. Observed separation for a real
/// tone in Spike B's own earlier run was 207×, and for a genuinely absent one
/// under 10×, so 20 sits in a wide gap rather than being fitted to either
/// side. Both ratios are printed, so a run landing near the line is visible
/// instead of being silently rounded to a verdict.
let tonePresenceRatio = 20.0

struct TrackTones {
    let index: Int
    let rms: Double
    let a440: Double
    let a1k: Double
    let referenceMagnitudes: [Double]
    let channels: Int
    let sampleRate: Double

    /// Median of the reference bins.
    var noiseFloor: Double {
        let sorted = referenceMagnitudes.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
    var ratio440: Double { noiseFloor > 0 ? a440 / noiseFloor : .infinity }
    var ratio1k: Double { noiseFloor > 0 ? a1k / noiseFloor : .infinity }

    /// Digital silence, and the one place an absolute number is honest: this
    /// asks whether there are any non-zero samples at all, which no gain
    /// setting changes. It is a precondition on reading the ratios, not a
    /// tone verdict — a silent track has no noise floor to be relative to.
    var essentiallySilent: Bool { rms < 1e-5 }
    var has440: Bool { !essentiallySilent && ratio440 >= tonePresenceRatio }
    var has1k: Bool { !essentiallySilent && ratio1k >= tonePresenceRatio }

    var formatDescription: String { "\(channels)ch @\(Int(sampleRate))Hz" }

    /// How loud the tone that does NOT belong to this track is, relative to
    /// the one that does. Small means separated; near 1 means mixed.
    ///
    /// The denominator is this track's own dominant tone — a large, stable
    /// number — rather than a noise floor of five near-zero bins whose
    /// median moved by 2× between two reads of the same file, putting the
    /// same assertion on both sides of its threshold in one run.
    func foreignToNative(native: Double, foreign: Double) -> Double {
        native > 0 ? foreign / native : .infinity
    }
    var systemViewForeignRatio: Double { foreignToNative(native: a440, foreign: a1k) }
    var micViewForeignRatio: Double { foreignToNative(native: a1k, foreign: a440) }
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
    // The track's own format, read from the file rather than assumed from its
    // index. The two sources are distinguishable by it — system audio arrives
    // 2ch@48k and the microphone 1ch@44.1k on this machine — so "which track
    // is which" stops being an ordering assumption, which is the one thing a
    // separation test must not assume.
    let description = try? awaitFormat(track)
    return TrackTones(index: 0, rms: rms,
                       a440: goertzel(samples, 440, 48000), a1k: goertzel(samples, 1000, 48000),
                       referenceMagnitudes: referenceFrequencies.map { goertzel(samples, $0, 48000) },
                       channels: description?.channels ?? 0, sampleRate: description?.rate ?? 0)
}

/// The track's channel count and sample rate, from its format description.
func awaitFormat(_ track: AVAssetTrack) throws -> (channels: Int, rate: Double) {
    guard let fd = (track.formatDescriptions as [Any]).first,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd as! CMFormatDescription)?.pointee
    else { return (0, 0) }
    return (Int(asbd.mChannelsPerFrame), asbd.mSampleRate)
}

func analyse(_ url: URL, preRead: [TrackTones]? = nil) async throws {
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
    // One read, and the caller may pass the result back in. D-P4 rejected
    // "two records of one fact that drift apart silently" for storage; this
    // is the same rule at computation scope. Reading twice is exactly what
    // produced 34.0x and 16.0x for one quantity in one run.
    //
    // Worth writing down: that accidental duplicate WAS a cross-check, and
    // it is what caught the unstable criterion. Removing it is right, and it
    // means the new criterion has to be stable on its own — three orders of
    // magnitude rather than a 20% margin. Deliberately, not by luck.
    for (i, t) in audio.enumerated() {
        let tones = try preRead?[i] ?? readTones(track: t, asset: asset)
        print("  audio[\(i)]  \(tones.formatDescription)  samples-limited-rms \(String(format:"%.5f", tones.rms))")
        print(String(format: "     440 Hz %.6f  1000 Hz %.6f  noise floor (median of 5 non-harmonic bins) %.6f",
                     tones.a440, tones.a1k, tones.noiseFloor))
        if tones.essentiallySilent {
            print("     ESSENTIALLY SILENT (rms < 1e-5) — no tone conclusion possible. This is NOT " +
                  "'the tone was absent'; it is 'this track carries no signal at all'.")
        } else {
            print(String(format: "     440 is %.1fx the floor → present: %@   |   1k is %.1fx the floor → present: %@" +
                                 "   (threshold %.0fx)",
                         tones.ratio440, tones.has440 ? "YES" : "no",
                         tones.ratio1k, tones.has1k ? "YES" : "no", tonePresenceRatio))
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

/// Phase accumulator for the 440 Hz source node below.
///
/// A global with `nonisolated(unsafe)`, for the same reason
/// `displayReconfigurations` is one: the render block cannot be a closure
/// that captures local state, because under this build's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` such a closure is inferred
/// `@MainActor` — and CoreAudio calls it on a realtime thread, where
/// `dispatch_assert_queue` fails and the process traps with SIGTRAP.
///
/// **This is the "the probe is not the app" rule collecting.** The closure
/// form ran fine for four earlier Spike B runs. It broke the moment
/// `build.sh` was changed to compile against the SAME language-mode flags as
/// `Soredemo.xcodeproj` — which is exactly what that change was for: a spike
/// built under different isolation semantics can pass while the product
/// crashes.
nonisolated(unsafe) var tonePhase = 0.0

/// The 440 Hz generator, as a `nonisolated` free function rather than a
/// closure — see `tonePhase`.
nonisolated func renderToneBlock(_ isSilence: UnsafeMutablePointer<ObjCBool>,
                                  _ timestamp: UnsafePointer<AudioTimeStamp>,
                                  _ frameCount: AVAudioFrameCount,
                                  _ audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let increment = 2.0 * Double.pi * 440.0 / 48000.0
    for frame in 0..<Int(frameCount) {
        let value = Float(sin(tonePhase) * 0.25)
        tonePhase += increment
        if tonePhase > 2 * .pi { tonePhase -= 2 * .pi }
        for buffer in buffers {
            buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = value
        }
    }
    return noErr
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
    for (i, c) in d.segmentConfigurations.enumerated() {
        print("  segment \(i) configured: buffer \(c.bufferWidth)x\(c.bufferHeight)  " +
              "destination \(Int(c.destination.x)),\(Int(c.destination.y)) " +
              "\(Int(c.destination.width))x\(Int(c.destination.height))  scale \(c.scale)")
        print("    ContentScale over \(c.framesChecked) frames: " +
              "\(c.contentScaleMin.map { String(format: "%.4f", $0) } ?? "n/a") … " +
              "\(c.contentScaleMax.map { String(format: "%.4f", $0) } ?? "n/a")   " +
              "resampled \(c.framesResampled)")
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
    var step = VerificationStep(name: "1 — video only, no audio, WINDOW capture (D2-13a)")
    step.begin(repositoryPath: repositoryPath)
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
        step.preconditionFailed("the test window did not appear in SCShareableContent.currentProcess.")
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
        step.preconditionFailed("the test window is not smaller than the display-sized buffer on " +
                                "this machine, so the ContentScale check would be vacuous — the " +
                                "identity-transform case this step exists to avoid. Shrink the " +
                                "window in this file and re-run.")
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
    step.expect([
        ("buffer (pixels)", "\(bufferSize.width) x \(bufferSize.height)"),
        ("destinationRect being set", "x \(Int(expected.x)) y \(Int(expected.y)) " +
                                      "w \(Int(expected.width)) h \(Int(expected.height))"),
        ("content will span", "x ∈ [\(Int(expected.x)), \(Int(expected.x + expected.width))], " +
                              "y ∈ [\(Int(expected.y)), \(Int(expected.y + expected.height))]"),
        ("right-edge samples at", "x = \(Int(expected.x + expected.width) - 4) (inside, NOT black) " +
                                  "and \(Int(expected.x + expected.width) + 4) (outside, black)"),
        ("per-frame contentRect", "\(Int(expected.width / scale)) x \(Int(expected.height / scale)) points " +
                                  "at (\(Int(expected.x / scale)), \(Int(expected.y / scale)))"),
        ("ContentScale", "1.0 on every frame — the destination matches the source size"),
        ("frame accounting", "must balance"),
    ])

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
    let appendedResampled = session.diagnostics.appendedResampledFrameCount
    step.check("ContentScale was readable on \(checked) frames, and \(checked) > 0 — a checked count " +
               "of zero would satisfy \"every checked frame had ContentScale == 1\" vacuously",
               checked > 0)
    step.check("no resampled frame reached the MASTER — \(appendedResampled) appended, of " +
               "\(session.diagnostics.resampledFrameCount) delivered resampled",
               appendedResampled == 0)
    step.check("every complete frame is accounted for — \(session.diagnostics.frameAccounting)",
               session.diagnostics.everyCompleteFrameIsAccountedFor)

    let mediaURL = packageDir.appending(path: "media/master-00.mov")
    // Checked rather than left to `analyse` throwing out of `main`. When the
    // file was missing, the top-level error was an AVFoundation -11800 about
    // `assetProperty_Tracks` — which reads as "the movie is malformed" and
    // sent the first diagnosis at the writer. The file did not exist at all.
    guard FileManager.default.fileExists(atPath: mediaURL.path()) else {
        step.check("a master file exists at \(mediaURL.path())", false)
        step.finish(remedy: "The recording did not reach the package. The `segments discarded` lines " +
                            "above say why; if that count is 0 too, then nothing in this process " +
                            "knows, which is itself the finding.")
    }
    step.check("a master file exists in the package", true)
    try await analyse(mediaURL)
    try await checkPaddingGeometry(mediaURL, contentRect: session.diagnostics.lastContentRect,
                                   scale: scale, bufferSize: bufferSize,
                                   chosen: session.diagnostics.configuredDestinationRect)
    for (what, ok) in paddingChecks { step.check(what, ok) }
    step.finish(remedy: "Padding present but not at the computed boundary means the buffer layout and " +
                        "contentRect disagree — D2-13a's mapping is what is wrong, not the picture.")
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
    paddingChecks = checks + [("the per-frame contentRect × scale equals the destinationRect this " +
                               "process chose", matchesChosen)]
}

/// Filled by `checkPaddingGeometry`, read by step 1's `finish`. A global
/// rather than a return value only because the function has several early
/// exits that each already print their own reason.
nonisolated(unsafe) var paddingChecks: [(String, Bool)] = []

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
    var step = VerificationStep(name: "2 — two audio sources, distinguishable tones")
    step.begin(repositoryPath: repositoryPath)
    print("""
    ***  USE HEADPHONES.  ***
    Not a preference — assertion 4 is "the microphone track does NOT contain
    440 Hz", and if the 440 comes out of the Mac's speakers the microphone
    WILL pick it up. That assertion then fails for a reason that has nothing
    to do with the code, and the failure is indistinguishable from real
    mixing. ScreenCaptureKit captures the audio STREAM, not the speakers, so
    routing system audio to headphones still gets captured digitally while
    keeping it out of the room.

    Expect BEFORE running — FOUR assertions, not a track count. A count of 2
    cannot tell separation from duplication, and cannot tell a live track from
    a silent one:
      1. the 2-channel 48 kHz track (system audio) CONTAINS 440 Hz
      2. the same track does NOT contain 1 kHz
      3. the 1-channel track (microphone) CONTAINS 1 kHz
      4. the same track does NOT contain 440 Hz

    Tracks are identified by their FORMAT, not by their index and not by which
    tone they contain. Identifying them by tone would make assertions 1 and 3
    tautologies — the previous version of this step did exactly that.

    Presence is a RATIO to a noise floor (%.0fx, floor = median of five
    non-harmonic reference bins), never an absolute amplitude: output volume,
    microphone gain and room noise all move amplitude and this process
    controls none of them.

    You must, while this runs:
      - let it play 440 Hz itself (automatic, from this process)
      - hold a phone playing a steady 1 kHz tone NEAR THE MICROPHONE,
        for the whole recording, not just the start
    """.replacingOccurrences(of: "%.0fx", with: String(format: "%.0fx", tonePresenceRatio)))
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
        step.preconditionFailed("without microphone access this experiment cannot be read — one " +
                                "silent track would be indistinguishable from a real 'mic dropped' " +
                                "result. Grant it and re-run.")
    }

    // Which microphone, printed rather than assumed.
    //
    // The choice of input device decides assertion 4. Headphones WITH a
    // microphone make macOS switch input to that headset — whose microphone
    // sits centimetres from the earcup now playing the 440 Hz tone, which is
    // the leakage path headphones were supposed to remove, only shorter. So
    // the device is named here: if assertion 4 fails, this line says whether
    // the input was the built-in microphone or something clipped to the
    // sound source.
    if let inputDevice = AVCaptureDevice.default(for: .audio) {
        print("microphone input device: \(inputDevice.localizedName)")
    } else {
        print("microphone input device: NONE — no audio capture device is available at all.")
    }

    let display = try await firstDisplay()
    let source = CaptureSource.display(display)

    // 440 Hz generated by this process itself — one fewer human step, and it
    // removes the failure the original Spike B hit three runs out of four
    // (nothing playing at all, with "both tones present" reported over
    // silence).
    let engine = AVAudioEngine()
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    tonePhase = 0
    let src = AVAudioSourceNode(renderBlock: renderToneBlock)
    engine.attach(src)
    engine.connect(src, to: engine.mainMixerNode, format: fmt)
    try engine.start()
    print("\nplaying 440 Hz from this process (captured as system audio)")

    // ---- PRECONDITION: BOTH sources carrying signal, not just the mic ----
    //
    // Two-sided, deliberately. A run where the 440 never played produces
    // exactly the same file as a run where the system-audio track is broken:
    // one silent track and one live one. Gating on the microphone alone —
    // which is what this step used to do — leaves that pair
    // indistinguishable, and the wrong one of the two is the comfortable
    // conclusion.
    //
    // The gate uses a real `CaptureSession`, not a separate `AVAudioEngine`
    // tap, so it exercises the same path the recording will. `peakRMS` is
    // per track and comes from the product's own diagnostics.
    print("\nPRE-FLIGHT — 8s, checking BOTH sources carry signal before spending \(seconds)s.")
    print("PLAY THE 1 kHz TONE NEAR THE MIC NOW, and keep it playing.")
    try? FileManager.default.removeItem(at: verificationDir)
    let preflightPackage = verificationDir.appending(path: "preflight.soredemo", directoryHint: .isDirectory)
    let preflight = CaptureSession(source: source, scale: 2.0,
                                    displayUUID: displayUUID(for: display.displayID),
                                    packageURL: preflightPackage, epoch: bootEpoch())
    try await preflight.start()
    for i in (1...8).reversed() {
        try await Task.sleep(for: .seconds(1))
        let d = preflight.diagnostics
        print(String(format: "  %ds  system peak rms %@   mic peak rms %@", i,
                     d.systemAudioAccounting.peakRMS.map { String(format: "%.5f", $0) } ?? "(none yet)",
                     d.microphoneAccounting.peakRMS.map { String(format: "%.5f", $0) } ?? "(none yet)"))
    }
    _ = try? await preflight.stop()
    let pre = preflight.diagnostics

    // An absolute floor, and this is the one place that is honest: the
    // question here is "are there any non-zero samples", which no gain
    // setting changes. It is NOT a tone threshold — those are ratios.
    let silenceFloor = 1e-4
    let systemLive = (pre.systemAudioAccounting.peakRMS ?? 0) > silenceFloor
    let micLive = (pre.microphoneAccounting.peakRMS ?? 0) > silenceFloor
    print(String(format: "  system audio: %@ (peak rms %.5f)   microphone: %@ (peak rms %.5f)   floor %.5f",
                 systemLive ? "LIVE" : "SILENT", pre.systemAudioAccounting.peakRMS ?? 0,
                 micLive ? "LIVE" : "SILENT", pre.microphoneAccounting.peakRMS ?? 0, silenceFloor))
    guard systemLive, micLive else {
        engine.stop()
        step.preconditionFailed(
              (!systemLive && !micLive ? "NEITHER source is carrying signal."
               : !systemLive ? "the SYSTEM AUDIO source is silent: either the 440 is not reaching the "
                             + "capture path, or the output device produces nothing capturable."
               : "the MICROPHONE is silent: the 1 kHz tone is not reaching it, or the input device is muted.")
              + " A recording made now would produce one silent track, which is exactly what a real " +
              "failure looks like — and the two would not be distinguishable afterwards.")
    }
    // ---- PRECONDITION 2: the acoustic path, checked BEFORE spending 30s ----
    //
    // Assertion 4 ("the microphone track does not contain 440 Hz") is the one
    // assertion of the four that is NOT immune to the room. Assertion 2 is:
    // there is no path by which a sound in the room reaches a digitally
    // captured system-audio stream, so a failure there can only be the
    // writer mixing. But the 440 Hz playing out of a speaker reaches the
    // microphone through the air, and that is physics, not a defect —
    // measured at 1/2138 of the native tone through headphones and at 1/1
    // with the speakers audible.
    //
    // So the acoustic condition is a precondition, not a result. Checking it
    // here turns "assertion 4 failed after 30 seconds, and it is ambiguous
    // whether that means mixing or speakers" into "your speakers are
    // audible, put the headphones on", before the recording.
    let preflightMedia = preflightPackage.appending(path: "media/master-00.mov")
    if FileManager.default.fileExists(atPath: preflightMedia.path()) {
        let preAsset = AVURLAsset(url: preflightMedia)
        let preTracks = try await preAsset.loadTracks(withMediaType: .audio)
        let preTones = try preTracks.map { try readTones(track: $0, asset: preAsset) }
        if let preMic = preTones.first(where: { $0.channels == 1 }) {
            let leak = preMic.micViewForeignRatio
            print(String(format: "  acoustic leakage into the microphone: 440 Hz is %@ of the 1 kHz tone",
                         leak <= 0 ? "0" : (leak >= 1 ? String(format: "%.2f", leak) : "1/\(Int((1/leak).rounded()))")))
            guard leak <= foreignToneCeiling else {
                engine.stop()
                try? FileManager.default.removeItem(at: verificationDir)
                step.preconditionFailed(
                      "the 440 Hz this process is playing is reaching the MICROPHONE loudly enough " +
                      "that assertion 4 could not be read afterwards. That assertion asks whether the " +
                      "two tracks are mixed; with the speakers audible it would instead be measuring " +
                      "the room, and a failure would be indistinguishable from real mixing.\n" +
                      "Put HEADPHONES on (or mute the speakers) and re-run. Note assertion 2 — the " +
                      "other direction — needs no such condition: nothing in the room can reach a " +
                      "digitally captured system stream.")
            }
        }
    }
    try? FileManager.default.removeItem(at: verificationDir)
    print("  both sources live, and the acoustic path is quiet enough to read assertion 4 — proceeding\n")

    // ---- the real run ----
    let session = CaptureSession(source: source, scale: 2.0,
                                  displayUUID: displayUUID(for: display.displayID),
                                  packageURL: packageDir, epoch: bootEpoch())
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
    guard FileManager.default.fileExists(atPath: mediaURL.path()) else {
        step.check("a master file exists at \(mediaURL.path())", false)
        step.finish()
    }
    // Read ONCE. `analyse` is handed the result rather than re-reading, so
    // there is one producer for every number below.
    let asset = AVURLAsset(url: mediaURL)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    let tones = try audioTracks.map { try readTones(track: $0, asset: asset) }
    try await analyse(mediaURL, preRead: tones)

    guard audioTracks.count == 2 else {
        step.check("the file has 2 audio tracks, not \(audioTracks.count) — the WEAK check, since 2 " +
                   "tracks would not have proved separation either", false)
        step.finish()
    }

    // Identified by FORMAT — the layouts the session measured on the way in,
    // which have nothing to do with which tone is present. Identifying by
    // tone (what this step used to do) makes assertions 1 and 3 tautologies:
    // "the track containing 440 contains 440".
    let d = session.diagnostics
    print("\nsource layouts measured during capture:")
    print("  system audio: \(d.systemAudioLayout ?? "(none)")")
    print("  microphone:   \(d.microphoneLayout ?? "(none)")")
    guard let systemTrack = tones.first(where: { $0.channels == 2 }),
          let micTrack = tones.first(where: { $0.channels == 1 }) else {
        step.check("the two tracks are distinguishable by FORMAT " +
                   "(\(tones.map(\.formatDescription).joined(separator: ", "))) — identifying them by " +
                   "tone instead would make two of the four assertions circular, so this step " +
                   "refuses rather than falling back", false)
        step.finish()
    }

    // ---- setup diagnostic, printed whether or not anything fails ----
    //
    // The leakage ratio is a measured constant OF THIS PHYSICAL SETUP, not a
    // property of the code. Printing it means a future run that reports 1/50
    // is immediately diagnosable as "headphones off" or "speakers audible",
    // instead of arriving as a mysterious assertion failure. Same purpose as
    // the identity block at the top: let the output say what conditions
    // produced it.
    func ratioText(_ r: Double) -> String {
        r <= 0 ? "0" : (r >= 1 ? String(format: "%.2f", r) : "1/\(Int((1/r).rounded()))")
    }
    print("\nacoustic leakage measured on this setup (a property of the room and the headphones, " +
          "not of the code):")
    print("  microphone track: its 440 Hz is \(ratioText(micTrack.micViewForeignRatio)) of its own 1 kHz")
    print("  system track:     its 1 kHz is \(ratioText(systemTrack.systemViewForeignRatio)) of its own 440 Hz")
    print("  separation ceiling \(ratioText(foreignToneCeiling)) — leakage sits far below it; " +
          "genuine mixing would sit between 1/1 and 1/10")

    print("\nFOUR ASSERTIONS (tracks by format; presence vs the noise floor; separation vs the " +
          "track's OWN dominant tone):")
    let assertions: [(String, Bool)] = [
        ("system track (\(systemTrack.formatDescription)) CONTAINS 440 Hz " +
         "— \(String(format: "%.0fx", systemTrack.ratio440)) the floor", systemTrack.has440),
        ("system track is not MIXED with the microphone — its 1 kHz is " +
         "\(ratioText(systemTrack.systemViewForeignRatio)) of its own 440, ceiling " +
         "\(ratioText(foreignToneCeiling))", systemTrack.systemViewForeignRatio <= foreignToneCeiling),
        ("mic track (\(micTrack.formatDescription)) CONTAINS 1 kHz " +
         "— \(String(format: "%.0fx", micTrack.ratio1k)) the floor", micTrack.has1k),
        ("mic track is not MIXED with system audio — its 440 is " +
         "\(ratioText(micTrack.micViewForeignRatio)) of its own 1 kHz, ceiling " +
         "\(ratioText(foreignToneCeiling))", micTrack.micViewForeignRatio <= foreignToneCeiling),
    ]
    for (what, ok) in assertions { step.check(what, ok) }
    step.finish(remedy: "A foreign tone near 1/1 to 1/10 of the native one is MIXING. One near the " +
                        "leakage figures printed above, with the ceiling crossed anyway, means the " +
                        "acoustic setup changed — check headphones before checking the code.")
}


// ------------------------------------------- programmatic display mode change

/// Changes the display's mode from this process, so step 3's experiment
/// cannot silently fail to happen.
///
/// **Why this replaced a human step.** The first attempt asked a person to
/// change the resolution mid-recording. The run reported zero
/// reconfigurations, and that has two indistinguishable causes — the change
/// never happened, or it happened and the callback never fired — with no way
/// to tell them apart afterwards. The display was back at its default by the
/// time anyone looked. An experiment whose non-occurrence is invisible is
/// not an experiment.
///
/// **`kCGConfigureForAppOnly` is the safety net, and it is load-bearing.**
/// A configuration made with that scope is reverted by the window server
/// when this process exits — including if it crashes mid-recording. The
/// explicit restore below is the normal path; this is what stops a spike
/// leaving someone's display in a mode they did not choose.
func displayModes(of id: CGDirectDisplayID) -> [CGDisplayMode] {
    (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode]) ?? []
}

func setDisplayMode(_ id: CGDirectDisplayID, _ mode: CGDisplayMode) -> CGError {
    var config: CGDisplayConfigRef?
    let began = CGBeginDisplayConfiguration(&config)
    guard began == .success, let config else { return began }
    let configured = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
    guard configured == .success else {
        CGCancelDisplayConfiguration(config)
        return configured
    }
    return CGCompleteDisplayConfiguration(config, .forAppOnly)
}

// --------------------------------------------------------- Step 3: reconfig

func runReconfig(seconds: Int) async throws {
    var step = VerificationStep(name: "3 — display reconfiguration (LAST — changes system state)")
    step.begin(repositoryPath: repositoryPath)
    print("""
    Expect BEFORE running:
      - at the midpoint THIS PROCESS changes the display's resolution itself,
        and restores it afterwards — no human step, because a human step that
        does not happen is indistinguishable from a callback that does not fire
      - the recording produces >= 2 segments in the returned SegmentTable
      - the segment before the change has endedBy == .displayReconfigured(...)
      - the two segments carry DIFFERENT GeometryRevision values
      - diagnostics.displayReconfigurationsHandled >= 1
      - and NO resampled frame reaches the MASTER, across the change. Frames
        DELIVERED resampled during the switch are expected and are dropped;
        the claim is about the file, not the stream
    This step changes your display's resolution for about 20 seconds and then
    changes it back. The configuration scope is .forAppOnly, so the window
    server reverts it when this process exits even if it crashes.
    """)
    requireScreenRecording()
    try? FileManager.default.removeItem(at: verificationDir)
    let display = try await firstDisplay()
    let source = CaptureSource.display(display)
    let session = CaptureSession(source: source, scale: 2.0, displayUUID: displayUUID(for: display.displayID),
                                  packageURL: packageDir, epoch: bootEpoch())
    let registration = CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)
    print("spike's own reconfiguration callback registration: CGError \(registration.rawValue)")
    guard registration == .success else {
        step.preconditionFailed("the spike could not register its own reconfiguration callback, so " +
                                "its OS-level count would be zero for a reason unrelated to the session.")
    }
    try await session.start()
    // The before-value, printed before the recording, so "the revision
    // changed" has something to have changed FROM in the same log.
    let before = source.geometry(scale: 2.0, displayUUID: displayUUID(for: display.displayID))
    step.expect([
        ("display now", "\(display.width) x \(display.height) points"),
        ("buffer now", "\(before.pixelWidth) x \(before.pixelHeight) pixels"),
        ("revision now", "\(before.revision)"),
        ("after the change", "a DIFFERENT revision, in a SECOND segment, the first ended with " +
                             ".displayReconfigured, and no resampled frame in the master"),
    ])

    // The change is made by THIS PROCESS at a known instant, not by a person
    // at an approximate one. See `setDisplayMode` for why.
    guard let currentMode = CGDisplayCopyDisplayMode(display.displayID) else {
        step.preconditionFailed("cannot read the display's current mode; nothing to change from.")
    }
    let candidates = displayModes(of: display.displayID).filter {
        $0.pixelWidth != currentMode.pixelWidth && $0.pixelWidth >= 1280 && $0.pixelHeight >= 800
    }
    guard let target = candidates.max(by: { $0.pixelWidth < $1.pixelWidth }) else {
        step.preconditionFailed("this display offers no alternative mode at or above 1280x800 " +
                                "(\(displayModes(of: display.displayID).count) modes total).")
    }
    print("will switch \(currentMode.pixelWidth)x\(currentMode.pixelHeight) -> " +
          "\(target.pixelWidth)x\(target.pixelHeight) at t-\(seconds / 2)s, and restore it afterwards " +
          "(scope .forAppOnly, so a crash reverts it too)")
    print("recording \(seconds)s ...")

    let switchTask = Task {
        try? await Task.sleep(for: .seconds(seconds / 2))
        let e = setDisplayMode(display.displayID, target)
        print("  *** switched display mode programmatically, CGError \(e.rawValue)" +
              (e == .success ? "" : "  <- NON-ZERO: the change did not happen"))
    }
    defer {
        switchTask.cancel()
        let restored = setDisplayMode(display.displayID, currentMode)
        print("restored \(currentMode.pixelWidth)x\(currentMode.pixelHeight), CGError \(restored.rawValue)")
    }
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
    // FIVE assertions, one per line of the expectation table above. The
    // previous version listed five and checked two — `endedBy` and
    // `displayReconfigurationsHandled` were printed and then never compared
    // against anything, which is the same shape as an expectation table
    // whose rows quietly stop being checks.
    guard displayReconfigurations > 0 else {
        step.didNotHappen("the display was never reconfigured during this run, so nothing this step " +
                          "verifies was exercised.")
    }
    let handled = session.diagnostics.displayReconfigurationsHandled
    let revisions = Set(table.segments.map(\.revision))
    let reconfiguredBoundaries = table.segments.filter {
        if case .displayReconfigured = $0.endedBy { return true } else { return false }
    }
    let reconfigChecks: [(String, Bool)] = [
        ("the session registered its observer successfully — CGError " +
         "\(session.diagnostics.reconfigurationObserverRegistration?.rawValue.description ?? "not recorded")",
         session.diagnostics.reconfigurationObserverRegistration == CGError.success),
        ("the OS reported \(displayReconfigurations) reconfiguration(s)", displayReconfigurations >= 1),
        ("the session HANDLED \(handled) of them — an OS callback the session never acted on would " +
         "leave every other check below passing for the wrong reason", handled >= 1),
        ("the recording split into \(table.segments.count) segments (>= 2)", table.segments.count >= 2),
        ("\(reconfiguredBoundaries.count) segment(s) ended with .displayReconfigured",
         !reconfiguredBoundaries.isEmpty),
        ("the segments carry \(revisions.count) distinct GeometryRevisions (> 1) — a split that " +
         "reused one revision would lose the very fact the split exists to record",
         revisions.count > 1),
        // Added after the first passing run, where it was printed and not
        // checked. That run split correctly, minted two revisions, and
        // resampled 335 of 664 frames — every frame after the change —
        // because the new segment's buffer followed the new display while
        // its destinationRect still described the old one. Six assertions
        // passed over a master that D2-8 says must not exist.
        // The subject is the MASTER, not the stream. ScreenCaptureKit
        // delivers resampled frames across a reconfiguration no matter what
        // this process does; what D2-8 claims is that none of them are
        // written. Asserting on `resampledFrameCount` would fail over a
        // master that is entirely unresampled — the same stream-versus-file
        // confusion that reported 310 complete frames into a zero-byte file.
        ("no resampled frame reached the MASTER — \(session.diagnostics.appendedResampledFrameCount) " +
         "appended, of \(session.diagnostics.resampledFrameCount) delivered resampled out of " +
         "\(session.diagnostics.contentScaleCheckedCount) checked. The delivered ones are dropped " +
         "between the reconfiguration callback and the new segment opening, and counted as " +
         "awaiting-reconfiguration in the accounting above",
         session.diagnostics.appendedResampledFrameCount == 0),
    ]
    for (what, ok) in reconfigChecks { step.check(what, ok) }
    step.finish(remedy: "A split that happened but resampled frames usually means geometry and the " +
                        "destination rectangle were derived from different sources, or the display's " +
                        "backing scale changed with its mode and the session reused the old one.")
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
