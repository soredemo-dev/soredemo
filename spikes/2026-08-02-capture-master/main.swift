// Spike B — what "the master" is, as a file.
//
// Three questions, one SCStream run:
//   1. Does SCRecordingOutput at our floor keep system audio and microphone apart?
//   2. What happens when the recorded display is reconfigured mid-recording?
//   3. Frame PTS -> callback latency (the original, taken along the way).
//
// Question 1 is deliberately NOT measured as "how many audio tracks", because
// count == 1 cannot distinguish MIXED from MIC-DROPPED and both are legal
// values — the failure lands inside the valid range (AGENTS.md). So both
// sources carry a distinguishable tone and the analyse mode looks for each.
//
// Needs Screen Recording. Records the WHOLE SCREEN to a file — delete it after.

import AVFoundation
import AVFAudio
import ScreenCaptureKit
import CoreGraphics
import Darwin

let tb: mach_timebase_info_data_t = {
    var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
}()
@inline(__always) func nowNs() -> UInt64 { mach_absolute_time() &* UInt64(tb.numer) / UInt64(tb.denom) }

let out = URL(filePath: NSHomeDirectory()).appending(path: "soredemo-spike-b.mov")

// ---------------------------------------------------------------- analyse
func goertzel(_ x: [Float], _ freq: Double, _ rate: Double) -> Double {
    guard x.count > 0 else { return 0 }
    let k = Int(0.5 + Double(x.count) * freq / rate)
    let w = 2.0 * Double.pi * Double(k) / Double(x.count)
    let c = 2.0 * cos(w)
    var s0 = 0.0, s1 = 0.0, s2 = 0.0
    for v in x { s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
    return sqrt(s1*s1 + s2*s2 - c*s1*s2) / Double(x.count)
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
    }
    print()
    if audio.isEmpty { print("  NO AUDIO TRACK AT ALL — a third outcome the table did not list."); return }

    for (i, t) in audio.enumerated() {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000.0,
        ]
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: settings)
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
        let a440 = goertzel(samples, 440, 48000)
        let a1k  = goertzel(samples, 1000, 48000)
        let noise = goertzel(samples, 3000, 48000)      // reference: nothing should be here
        print("  audio[\(i)]  samples \(samples.count)  rms \(String(format:"%.5f", rms))")
        print(String(format: "     440 Hz %.6f   1000 Hz %.6f   3000 Hz (ref) %.6f", a440, a1k, noise))
        // A ratio against a zero reference passes for anything above zero, which
        // is how a silent file was reported as containing both tones. Absolute
        // floor first, ratio second — AGENTS.md: failure must land outside the
        // value range, and "present" is inside it.
        let floor = 1e-4
        if rms < 1e-3 {
            print("     TRACK IS ESSENTIALLY SILENT (rms \(String(format: "%.5f", rms))).")
            print("     No tone conclusion is possible. This is not a finding about mixing.")
        } else {
            let has440 = a440 > floor && a440 > noise * 4
            let has1k  = a1k  > floor && a1k  > noise * 4
            print("     440 present: \(has440)    1k present: \(has1k)   (floor \(floor))")
        }
    }
    print("\n  A 1 kHz result near the 3 kHz reference means EITHER the mic was mixed out")
    print("  OR no 1 kHz tone was played. This spike cannot tell those apart — play the")
    print("  tone, or the row below is unreadable.")
    print("\n  Read the table with the tone results, NOT with the track count:")
    print("    2 tracks                  -> separated, SCRecordingOutput usable")
    print("    1 track, 440 and 1k both  -> MIXED")
    print("    1 track, 440 only         -> MIC DROPPED")
    print("    1 track, 1k only          -> system audio dropped (unlisted, would also matter)")
}

// ---------------------------------------------------------------- record
nonisolated(unsafe) var displayReconfigurations = 0

func reconfigCallback(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                      _ userInfo: UnsafeMutableRawPointer?) {
    // .beginConfiguration fires paired with the real change; count only the real one.
    if !flags.contains(.beginConfigurationFlag) {
        displayReconfigurations += 1
        print("  *** display \(id) reconfigured, flags 0x\(String(flags.rawValue, radix: 16))")
    }
}

final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate,
                      @unchecked Sendable {
    var frames = 0
    var latencies: [UInt64] = []
    var sizes = Set<String>()
    var stoppedWithError: String?
    var statusCounts: [Int: Int] = [:]
    // The file is not readable until this fires. Reading before it does gives
    // AVFoundation -11829 "This media may be damaged", which is a true statement
    // about a file that is simply not finished.
    var finished = false
    var started = false

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stoppedWithError = String(describing: error)
        print("\n*** stream(_:didStopWithError:) — \(error)")
    }
    func recordingOutput(_ o: SCRecordingOutput, didFailWithError e: Error) {
        print("\n*** recordingOutput didFailWithError — \(e)")
    }
    func recordingOutputDidStartRecording(_ o: SCRecordingOutput) {
        started = true; print("recordingOutputDidStartRecording")
    }
    func recordingOutputDidFinishRecording(_ o: SCRecordingOutput) {
        finished = true
        print("recordingOutputDidFinishRecording — duration \(CMTimeGetSeconds(o.recordedDuration))s, \(o.recordedFileSize) bytes")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let cb = nowNs()
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let st = arr.first?[.status] as? Int {
            statusCounts[st, default: 0] += 1
            guard st == SCFrameStatus.complete.rawValue else { return }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let ptsNs = UInt64(max(0, CMTimeGetSeconds(pts) * 1e9))
        if ptsNs > 0 && cb > ptsNs { latencies.append(cb - ptsNs) }
        if let px = CMSampleBufferGetImageBuffer(sb) {
            sizes.insert("\(CVPixelBufferGetWidth(px))x\(CVPixelBufferGetHeight(px))")
        }
        frames += 1
    }
}

func record(seconds: Int) async throws {
    guard CGPreflightScreenCaptureAccess() else {
        print("Screen Recording NOT granted.")
        _ = CGRequestScreenCaptureAccess()
        print("""

        Grant it, then QUIT AND RELAUNCH. Screen Recording differs from Input
        Monitoring: the grant does not apply to a running process, and the app
        only appears in the list after it has attempted a capture once — which
        it just did.
        """)
        exit(2)
    }
    // A precondition that is not measured is a precondition that silently did not
    // happen — and an unmet one produces a result that looks exactly like a real
    // finding. AGENTS.md: a measurement has no safe default.
    let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
    let micNames: [AVAuthorizationStatus: String] =
        [.notDetermined: "notDetermined", .restricted: "restricted",
         .denied: "denied", .authorized: "authorized"]
    print("microphone authorization: \(micNames[micAuth] ?? "?")")
    if micAuth == .notDetermined {
        print("  requesting…")
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        print("  now: \(micNames[AVCaptureDevice.authorizationStatus(for: .audio)] ?? "?")")
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        print("""

        ABORTING rather than recording an invalid experiment. Without microphone
        access the audio question cannot be answered: one track with only the
        system tone would be indistinguishable from a real "mic dropped" result.
        Grant it in System Settings -> Privacy & Security -> Microphone and re-run.
        """)
        exit(4)
    }

    print("\nChecking the microphone is actually receiving signal before spending 30 s…")
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
        print("""

        ABORTING. The microphone is receiving essentially nothing (peak rms
        \(String(format: "%.5f", micRMS))), so a recording made now could not
        distinguish "mixed out" from "no tone was played". Play the tone and
        re-run.
        """)
        exit(5)
    }
    print("  mic is live (peak rms \(String(format: "%.4f", micRMS))) — proceeding\n")

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else { print("no display"); exit(3) }
    print("display \(display.displayID)  \(display.width)x\(display.height)")

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.capturesAudio = true
    cfg.captureMicrophone = true
    cfg.showsCursor = false                       // the master is unprocessed evidence — D2-8
    cfg.width = display.width * 2
    cfg.height = display.height * 2
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)

    try? FileManager.default.removeItem(at: out)
    let rcfg = SCRecordingOutputConfiguration()
    rcfg.outputURL = out
    rcfg.outputFileType = .mov
    rcfg.videoCodecType = .h264
    print("available file types: \(rcfg.availableOutputFileTypes)")
    print("available codecs:     \(rcfg.availableVideoCodecTypes)")

    let rec = Recorder()
    let stream = SCStream(filter: filter, configuration: cfg, delegate: rec)
    try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: .global())
    let ro = SCRecordingOutput(configuration: rcfg, delegate: rec)
    try stream.addRecordingOutput(ro)
    // Generate the system-audio tone ourselves. One fewer precondition a human
    // has to remember, and the run that forgot it is the run that produced a
    // false positive.
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

    CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)
    try await stream.startCapture()
    print("\nRECORDING for \(seconds)s -> \(out.path())")
    print("  * play a steady 440 Hz tone from another app (system audio)")
    print("  * play 1 kHz near the microphone from a phone")
    print("  * at ~half way, CHANGE THE RESOLUTION of this display in System Settings")
    print("    (the dangerous case: reconfiguring the display being recorded — no second monitor needed)\n")

    for s in stride(from: seconds, to: 0, by: -5) {
        try await Task.sleep(for: .seconds(5))
        print("  t-\(s-5)s  frames \(rec.frames)  sizes seen \(rec.sizes.sorted())  stopped=\(rec.stoppedWithError != nil)")
        if rec.stoppedWithError != nil { break }
    }
    engine.stop()
    if rec.stoppedWithError == nil { try await stream.stopCapture() }
    // Wait for the finalise callback rather than guessing a duration.
    for _ in 0..<100 where !rec.finished { try await Task.sleep(for: .milliseconds(100)) }
    print(rec.finished ? "finalised" : "NOT finalised after 10 s — the file below may be unreadable")

    print("\n--- record summary ---")
    print("frames \(rec.frames)   frame status counts \(rec.statusCounts)  (0=complete, 1=idle, 2=blank, 3=suspended, 4=started, 5=stopped)")
    print("distinct frame sizes seen: \(rec.sizes.sorted())")
    print("display reconfigurations observed: \(displayReconfigurations)")
    if displayReconfigurations == 0 {
        print("  -> the display was NOT reconfigured during this run, so question 2 was NOT tested.")
        print("     Not a finding. The experiment did not happen.")
    } else {
        print("  -> reconfiguration happened and the stream \(rec.stoppedWithError == nil ? "SURVIVED" : "STOPPED").")
        print("     frame sizes seen: \(rec.sizes.count) distinct")
    }
    print("stopped with error: \(rec.stoppedWithError ?? "no")")
    if !rec.latencies.isEmpty {
        let s = rec.latencies.sorted()
        func p(_ q: Double) -> Double { Double(s[min(Int(Double(s.count)*q), s.count-1)]) / 1e6 }
        print(String(format: "PTS -> callback  p50 %.2f ms  p90 %.2f ms  max %.2f ms  (n=%d)",
                     p(0.5), p(0.9), Double(s.last!)/1e6, s.count))
    }
    print()
    do { try await analyse(out) }
    catch { print("analyse failed: \(error)\n(if this is -11829, the file was not finalised)") }
}

@main enum SpikeB {
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // a crash must not swallow the log
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "analyse" {
            try await analyse(args.count > 2 ? URL(filePath: args[2]) : out)
        } else {
            try await record(seconds: 30)
        }
    }
}
