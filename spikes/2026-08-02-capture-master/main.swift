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

let verificationDir = URL(filePath: NSHomeDirectory())
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
    try await session.start()
    print("\nrecording \(seconds)s, video only, WINDOW capture, to \(packageDir.path()) ...")
    for s in stride(from: seconds, to: 0, by: -5) {
        try await Task.sleep(for: .seconds(min(5, s)))
        print("  t-\(max(0, s-5))s  \(session.diagnostics.completeFrameCount) complete frames so far")
    }
    let table = try await session.stop()
    testWindow.orderOut(nil)

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
        print("\nPASS — checked \(checked) frames, \(checked) > 0, of which \(passing) had ContentScale == 1.")
    } else {
        print("\nFAIL — checked \(checked) frames, of which only \(passing) had ContentScale == 1 " +
              "(\(checked - passing) were resampled). The master was NOT unresampled here — see D2-8.")
    }

    let mediaURL = packageDir.appending(path: "media/master-00.mov")
    try await analyse(mediaURL)
    print("\nCHECK BY EYE: open \"\(mediaURL.path())\" and confirm a solid blue rectangle, padded by black " +
          "on the sides — NOT a stretched or cropped full-frame image.")
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
    let table = try await session.stop()
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
    let table = try await session.stop()
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
