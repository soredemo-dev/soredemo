import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Synchronization

/// **Spike D — does `AVAssetWriterInput`'s successor receiver hang?**
///
/// One field report ([Apple Developer Forums thread 813867], January 2026, no
/// reply) says `AVAssetWriterInput.PixelBufferReceiver.append` suspends and
/// never resumes: no crash, no error, CPU to zero, and it happens on the first
/// run or the fifth with no pattern. That is one point with unknown
/// reproducibility, and D6b-27 currently records it as exactly that.
///
/// It matters because `AVAssetWriterInput.append(_:)` — what
/// `CaptureSession.swift` already ships — is deprecated at macOS 27.0 and its
/// named successor is a receiver. So the report threatens the migration of a
/// path that is already written, not only a path Phase 2B has not chosen yet.
///
/// **Two receivers, because the type table cannot say whether the hang is
/// type-specific.** `AVAssetWriterInput` carries three sibling classes —
/// `PixelBufferReceiver`, `SampleBufferReceiver`, `TaggedPixelBufferGroupReceiver`
/// — with identical method shapes (`append`, `appendImmediately`, `finish`) and
/// **no shared protocol**. No conformance in common is not evidence of separate
/// machinery; it is the absence of evidence either way. The report names
/// `PixelBufferReceiver`; our write path's successor is `SampleBufferReceiver`;
/// the report's own suspected locus is "the writer's input", which all three
/// share. So both are pushed, in the same process, under the same conditions.
///
/// **The assertion is a deadline, not a result.** A hang produces no signal at
/// all — that is what makes it a hang — so a spike that waits for `append` to
/// return waits forever and looks exactly like a spike that is still working.
/// Same shape as the `.listenOnly` tap, which is disabled without delivering
/// `kCGEventTapDisabledByTimeout`: a failure with no signal has to be turned
/// into one by a clock.
///
/// **The watchdog is a real `Thread`, and that is the load-bearing choice.**
/// The suspected cause is a deadlock involving the writer's input, and
/// `await append` suspends a Swift concurrency task. A watchdog written as a
/// `Task` shares the cooperative thread pool with the thing it is watching: if
/// that pool is what is stuck, the watchdog never runs and the spike hangs
/// silently — the detector failing in the same way, at the same moment, as the
/// thing detected. A `Thread` has its own OS thread and cannot be starved by
/// the pool. This is the rule this project already applies to the tap poll:
/// the instrument must not share the mechanism it is measuring.
///
/// Needs **no TCC grant of any kind**: it writes synthetic frames to a
/// temporary directory and deletes it. It reads no screen, no window, no input.
/// Runs unattended.
///
/// [Apple Developer Forums thread 813867]: https://developer.apple.com/forums/thread/813867

// MARK: - Progress, shared with the watchdog thread

/// What the watchdog reads. Plain C atomics rather than a lock: the watchdog
/// must be able to read this while the main thread is inside a suspended
/// `append`, and a lock the appending side might hold is one more thing that
/// can deadlock the detector along with the detected.
/// **`nonisolated`, and this is not a style choice.** This spike builds with
/// `-default-isolation MainActor`, matching the app target, so an unannotated
/// declaration is MainActor-isolated. The watchdog runs on a raw `Thread`,
/// which is not the main actor: calling an isolated member from it traps at
/// runtime (`dispatch_assert_queue_fail`, SIGTRAP) with **only a warning at
/// compile time** — the failure this project already met in `ObservationWriter`
/// and `LiveAXElementSource`.
///
/// Here it would be worse than usual. The watchdog would die on its first tick,
/// leaving a process that appends until it stalls and then sits there forever
/// with no output — which is exactly the appearance the watchdog exists to
/// distinguish from "still working". The detector would fail silently in the
/// same way as the thing it detects, and the spike would report nothing while
/// looking busy.
nonisolated final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var _appended = 0
    private var _inFlightSinceNanos: UInt64 = 0
    private var _label = ""
    private var _writerStatus = "not recorded"
    private var _directories: [URL] = []

    var appended: Int { lock.withLock { _appended } }

    func beginAppend(_ label: String, writerStatus: String) {
        lock.withLock {
            _inFlightSinceNanos = mach_absolute_time()
            _label = label
            _writerStatus = writerStatus
        }
    }

    /// The writer's own state as of the last append that STARTED.
    ///
    /// Recorded because the first reading of this spike's result was about to
    /// be "the successor receiver stops accepting frames", and a failed
    /// `AVAssetWriter` produces exactly that symptom from a fault in the rig
    /// rather than in the API: once `status == .failed`, the input never
    /// reports ready again and every append stalls forever. The watchdog must
    /// be able to tell those apart, and it cannot touch the writer itself while
    /// the appending task is suspended inside it.
    var writerStatus: String { lock.withLock { _writerStatus } }

    /// Every temp directory this run has opened.
    ///
    /// `Rig` deletes its own in a `defer`, and that was not enough: the
    /// watchdog ends the process with `exit`, which runs no `defer` and no
    /// `deinit`. So the run that MATTERS — the one that stalls — was the one
    /// leaving a directory behind, and three of them were found on disk after
    /// the first stalling runs. The standing rule is that a spike writes to a
    /// temp directory and deletes it, and "except when it fails" is not a
    /// version of that rule.
    func track(_ url: URL) { lock.withLock { _directories.append(url) } }

    func deleteEverythingWritten() {
        for url in lock.withLock({ _directories }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func endAppend() {
        lock.withLock { _inFlightSinceNanos = 0; _appended += 1 }
    }

    /// `(nanoseconds in flight, what)` or nil when nothing is in flight.
    func inFlight(timebase: (numer: UInt64, denom: UInt64)) -> (nanos: UInt64, label: String)? {
        lock.withLock {
            guard _inFlightSinceNanos != 0 else { return nil }
            let ticks = mach_absolute_time() - _inFlightSinceNanos
            return (ticks * timebase.numer / timebase.denom, _label)
        }
    }
}

nonisolated func timebase() -> (numer: UInt64, denom: UInt64) {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(info.denom))
}

/// Fires once, from its own OS thread, and takes the process down with a
/// verdict. `exit` rather than a thrown error on purpose: there is no one to
/// throw to — the appending task is suspended and will not resume to catch it.
@discardableResult
nonisolated func startWatchdog(progress: Progress, deadlineSeconds: Double, totalFrames: Int) -> Bool {
    let thread = Thread {
        let tb = timebase()
        let deadlineNanos = UInt64(deadlineSeconds * 1e9)
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            guard let flight = progress.inFlight(timebase: tb) else { continue }
            if flight.nanos > deadlineNanos {
                let seconds = Double(flight.nanos) / 1e9
                print("""

                ================= WATCHDOG =================
                REPRODUCED. `\(flight.label)` has been in flight for \
                \(String(format: "%.1f", seconds)) s against a \
                \(String(format: "%.1f", deadlineSeconds)) s deadline.
                \(progress.appended) of \(totalFrames) frame(s) appended before it stopped
                returning. Writer state at the last append that started: \(progress.writerStatus)

                This is the reported failure: no crash, no thrown error, no
                diagnostic. Without this thread the process would sit here
                looking exactly like one that is still working.
                ============================================
                """)
                progress.deleteEverythingWritten()
                exit(3)
            }
        }
    }
    thread.name = "spike-d-watchdog"
    thread.qualityOfService = .userInitiated
    thread.start()
    return true
}

/// BGRA at the size under test. One helper because both runs must push the
/// SAME pixels through two receivers: a difference in the frames would make a
/// difference in the results unattributable to the receiver.
/// A distinct directory per rig within one process, so two rigs in one run
/// cannot delete each other's output while the first is still open.
nonisolated func mediaCounter() -> Int {
    rigCounter.withLock { $0 += 1; return $0 }
}

nonisolated let rigCounter = Mutex<Int>(0)

nonisolated func bgraAttributes(width: Int, height: Int) -> CVPixelBufferCreationAttributes {
    CVPixelBufferCreationAttributes(
        pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
        size: CVImageSize(width: width, height: height),
        compatibility: [], bytesPerRowAlignment: nil, planeAlignment: nil, extendedPixels: nil)
}

// MARK: - The writer under test

enum ReceiverKind: String {
    case pixel      // AVAssetWriterInput.PixelBufferReceiver — the type the report names
    case sample     // AVAssetWriterInput.SampleBufferReceiver — our write path's successor
}

nonisolated struct Rig {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let directory: URL

    static func make(width: Int, height: Int) throws -> Rig {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "spike-d-\(ProcessInfo.processInfo.processIdentifier)-\(mediaCounter())",
                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progressShared.track(directory)
        let url = directory.appending(path: "out.mov", directoryHint: .notDirectory)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        // FALSE, deliberately, and it is not a detail. `true` tells the writer
        // to drop rather than block when it cannot keep up, which is the
        // setting that would hide a stall behind a dropped frame. An export
        // writes as fast as it can and must not drop, so `false` is both the
        // honest setting for the thing being measured and the one that lets a
        // stall be a stall.
        input.expectsMediaDataInRealTime = false
        return Rig(writer: writer, input: input, directory: directory)
    }

    /// **The two lifecycles, and the reason this is a knob rather than a fix.**
    ///
    /// The successor stack has its own lifecycle, and the header says so in the
    /// deprecation messages rather than anywhere a reader would look:
    /// `addInput:` says *use the appropriate `AVAssetWriter.inputReceiver(for:…)`
    /// overload*, and `startWriting` says *use `start()` instead*. The first
    /// version of this spike called `writer.add(input)` **and** took a receiver
    /// for the same input, then started with the deprecated `startWriting()` —
    /// mixing the two. That is a usage error, and a usage error produces a stall
    /// that looks exactly like a broken API.
    ///
    /// So both orders stay, selectable, because the comparison is the
    /// experiment: if the stall survives the new lifecycle it is not about the
    /// lifecycle, and if it does not, the earlier reading was wrong.
    /// The combination this spike shipped in its first version, kept verbatim so
    /// the discriminating run has a faithful "before" arm: the input added the
    /// old way, a NEW receiver taken for it, and then the OLD `startWriting()`.
    /// This is what stalled at frame 137.
    func addInputTheOldWay() {
        writer.add(input)
    }

    func startTheOldWay() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func startLegacy() {
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func startNew() throws {
        // No `add(_:)`: the receiver call attaches the input itself.
        try writer.start()
        writer.startSession(atSourceTime: .zero)
    }

    /// `AVAssetWriter.status` and its error, as text. Read on the appending
    /// side (the only side that may touch the writer) and handed to the
    /// watchdog through `Progress`.
    var statusDescription: String {
        let name: String
        switch writer.status {
        case .unknown: name = "unknown"
        case .writing: name = "writing"
        case .completed: name = "completed"
        case .failed: name = "FAILED"
        case .cancelled: name = "cancelled"
        @unknown default: name = "unrecognised(\(writer.status.rawValue))"
        }
        let ready = input.isReadyForMoreMediaData ? "ready" : "NOT ready"
        return "\(name), input \(ready)" + (writer.error.map { ", error: \($0)" } ?? "")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A pixel buffer with something actually in it. An all-zero buffer can be
/// encoded away to almost nothing, and a pipeline that never does real work is
/// not the pipeline the report describes.
///
/// Through `accessUnsafeMutableRawPlaneBytes` rather than
/// `CVPixelBufferGetBaseAddress`, because the successor types do not vend the
/// raw buffer: `CVMutablePixelBuffer.unsafeBuffer` is `internal`. That is the
/// redesign doing what it says — the buffer is reachable only inside a scope
/// that owns the lock — and it means a spike cannot reach around the new API
/// to the old one even by accident.
nonisolated func fill(_ buffer: inout CVMutablePixelBuffer, frame: Int) {
    buffer.accessUnsafeMutableRawPlaneBytes { planes in
        for plane in planes {
            guard let base = plane.bytes.baseAddress else { continue }
            memset(base, Int32(frame & 0xFF), plane.bytes.count)
        }
    }
}

// MARK: - The two runs

@main
enum SpikeD {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String, _ fallback: String) -> String {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return fallback }
            return arguments[i + 1]
        }
        let frames = Int(value("--frames", "600")) ?? 600
        let deadline = Double(value("--deadline", "20")) ?? 20
        let only = value("--only", "both")
        let poolThreshold = Int(value("--pool-threshold", "1000")) ?? 1000
        let mode = value("--mode", "await")   // await | immediate
        let width = Int(value("--width", "1280")) ?? 1280
        let height = Int(value("--height", "720")) ?? 720
        // Whether to hold every buffer this run has appended, instead of letting
        // it go. One of the two knobs the competing hypotheses disagree about:
        // if the stall is the pool running dry, holding references should move
        // the stall EARLIER and releasing them should move it later. If the
        // index does not move, the pool is not what stalls.
        let holdBuffers = arguments.contains("--hold-buffers")
        let lifecycle = value("--lifecycle", "new")   // new | legacy

        // THE SUBJECT IS THE RUNTIME, NOT THE SDK. A hang happens in the OS that
        // is executing, and this spike is about to be cited in a register whose
        // trigger is a version bump — so the version it ran on has to be in the
        // output, not inferred from when the file was committed.
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        let buildID = (try? String(contentsOf: URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"),
                                   encoding: .utf8))
            .flatMap { text -> String? in
                guard let r = text.range(of: "<key>ProductBuildVersion</key>") else { return nil }
                let tail = text[r.upperBound...]
                guard let open = tail.range(of: "<string>"), let close = tail.range(of: "</string>")
                else { return nil }
                return String(tail[open.upperBound..<close.lowerBound])
            } ?? "unknown"
        print("RUNTIME:  \(build), build \(buildID)")
        print("GEOMETRY: \(width)x\(height), mode \(mode), lifecycle \(lifecycle), pool threshold \(poolThreshold)"
              + (holdBuffers ? ", HOLDING every appended buffer" : ""))

        var step = VerificationStep(name: "spike D — does the successor receiver hang?")
        step.expect([
            .init("induced-frames-pushed",
                  "what is induced",
                  "at least \(frames) append(_:) calls per receiver, each one awaited",
                  reds: [.init("the stimulus",
                              "set --frames 0: every assertion below is then about a receiver "
                              + "nothing ever pushed, and this row is what says so")]),
            .init("pixel-receiver",
                  "PixelBufferReceiver — the type the report names",
                  "\(frames) frames appended, no append in flight past \(Int(deadline)) s",
                  reds: [.init("the deadline",
                              "run with --deadline 0.001: the watchdog fires on the first "
                              + "append and the process exits 3, so the deadline is doing "
                              + "the work and not the return value")]),
            .init("sample-receiver",
                  "SampleBufferReceiver — what CaptureSession.append(_:) becomes at 27.0",
                  "\(frames) frames appended, no append in flight past \(Int(deadline)) s",
                  reds: [.init("the type",
                              "the two receivers are pushed separately and reported "
                              + "separately; a single combined verdict could not say which "
                              + "of them stalled")]),
            .init("watchdog-armed",
                  "the detector is not on the pool it watches",
                  "a Thread, started before the first append, observed firing",
                  reds: [.init("the thread",
                              "written as a Task instead: with the cooperative pool blocked "
                              + "it never runs, and the spike hangs with no output — the "
                              + "detector failing in the same way as the detected")]),
        ])

        let watchdogArmed = startWatchdog(progress: progressShared,
                                          deadlineSeconds: deadline,
                                          totalFrames: frames * 2)
        // `Thread.current` is unavailable from an async context, which is the
        // compiler making this spike's own point: the appending side does not
        // run on a thread it can name. What is checkable is that the watchdog
        // was armed before the first append — a detector started afterwards
        // cannot see the append it was meant to watch.
        step.check("watchdog-armed",
                   "the watchdog thread was started before the first append was issued, on its own "
                   + "OS thread rather than on the cooperative pool the appends suspend on",
                   watchdogArmed)

        print("\n---- pushing, one receiver at a time ----")
        if only == "legacy" {
            let legacy = await runLegacy(frames: frames, width: width, height: height)
            announce("legacy AVAssetWriterInput.append", legacy, frames: frames)
            print("  THE CONTROL: if this reached \(frames) and the receivers did not, the stall "
                  + "belongs to the successor stack. If it stopped too, this spike's rig is wrong.")
            exit(legacy.appended == frames && legacy.error == nil ? 0 : 4)
        }
        let pixelResult = only == "sample"
            ? Result(skipped: true)
            : await runPixelReceiver(frames: frames, width: width, height: height,
                                     poolThreshold: poolThreshold, mode: mode,
                                     holdBuffers: holdBuffers, lifecycle: lifecycle)
        announce("PixelBufferReceiver", pixelResult, frames: frames)
        report(&step, id: "pixel-receiver", kind: "PixelBufferReceiver", result: pixelResult,
               frames: frames, deadline: deadline)

        let sampleResult = only == "pixel"
            ? Result(skipped: true)
            : await runSampleReceiver(frames: frames, width: width, height: height, mode: mode,
                                      lifecycle: lifecycle)
        announce("SampleBufferReceiver", sampleResult, frames: frames)
        report(&step, id: "sample-receiver", kind: "SampleBufferReceiver", result: sampleResult,
               frames: frames, deadline: deadline)

        step.check("induced-frames-pushed",
                   "the stimulus ran: \(pixelResult.appended) + \(sampleResult.appended) = "
                   + "\(pixelResult.appended + sampleResult.appended) append calls were issued and "
                   + "awaited. A run that pushed nothing reaches every deadline trivially",
                   pixelResult.appended + sampleResult.appended >= frames)

        step.finish(remedy: "If a receiver stalled, the watchdog has already exited 3 with the "
                    + "frame count. A clean pass here is NOT proof the report is wrong — it is "
                    + "one non-reproduction of a failure the reporter called random. Record it "
                    + "with the frame count and the machine, and do not upgrade it to 'fixed'.")
    }

    struct Result {
        var appended = 0
        var maxAppendNanos: UInt64 = 0
        var error: String?
        /// A receiver `--only` excluded. Reported as SKIPPED, never as a pass:
        /// "0 frames stalled" and "this receiver was never pushed" are the same
        /// number and not the same fact.
        var skipped = false
    }

    /// Prints the line AND records the assertion, in that order.
    ///
    /// The first version only recorded, and `VerificationStep.finish()` printed
    /// everything at the end. Then the second receiver stalled, the watchdog
    /// took the process down before `finish()` ran, and the first receiver's
    /// result — a full run, already measured — was lost with it. A spike whose
    /// output all arrives at the end has no output at all in exactly the case
    /// it was built for. Same shape as the probe that dies mid-section and
    /// prints no verdict for the checks below it.
    static func report(_ step: inout VerificationStep, id: String, kind: String,
                       result: Result, frames: Int, deadline: Double) {
        let worst = Double(result.maxAppendNanos) / 1e6
        step.check(id,
                   "\(kind): \(result.appended) of \(frames) frames appended, slowest single "
                   + "append \(String(format: "%.1f", worst)) ms, against a "
                   + "\(String(format: "%.0f", deadline)) s deadline"
                   + (result.error.map { " — threw: \($0)" } ?? ""),
                   result.appended == frames && result.error == nil && !result.skipped)
    }

    static func announce(_ kind: String, _ result: Result, frames: Int) {
        if result.skipped {
            print("  [\(kind)] SKIPPED by --only. Not a pass: nothing was pushed at it.")
            return
        }
        let worst = Double(result.maxAppendNanos) / 1e6
        print("  [\(kind)] \(result.appended)/\(frames) appended, slowest append "
              + "\(String(format: "%.1f", worst)) ms"
              + (result.error.map { ", threw: \($0)" } ?? "")
              + " — printed here, not at the end, because the end may not arrive")
    }

    /// `nonisolated`, like its sibling: an exporter does not append frames on
    /// the main actor, and running them there would measure a queue this code
    /// will never use. It also keeps the `CMSampleBuffer` built inside
    /// `withUnsafeBuffer` from crossing an isolation region on the way out,
    /// which Swift 6 rejects outright rather than warning about.
    /// `allocationThreshold` is a CAP, not a hint: the first version passed 0
    /// and every `makeMutablePixelBuffer` returned
    /// `kCVReturnWouldExceedAllocationThreshold (-6689)`, so the pixel path
    /// appended nothing at all — and the run still looked like a result until
    /// the per-receiver line was printed.
    nonisolated static func runPixelReceiver(frames: Int, width: Int, height: Int,
                                             poolThreshold: Int, mode: String,
                                             holdBuffers: Bool, lifecycle: String) async -> Result {
        var result = Result()
        do {
            let rig = try Rig.make(width: width, height: height)
            defer { rig.cleanUp() }
            let attributes = bgraAttributes(width: width, height: height)
            if lifecycle == "mixed" { rig.addInputTheOldWay() }
            let receiver = try rig.writer.inputPixelBufferReceiver(
                for: rig.input, pixelBufferAttributes: attributes)
            if lifecycle == "mixed" { rig.startTheOldWay() } else { try rig.startNew() }
            guard let pool = receiver.pixelBufferPool else {
                result.error = "the receiver vended no pixel buffer pool"
                return result
            }
            let tb = timebase()
            var held: [CVReadOnlyPixelBuffer] = []
            for frame in 0..<frames {
                var mutable = try pool.makeMutablePixelBuffer(.init(allocationThreshold: poolThreshold))
                fill(&mutable, frame: frame)
                let readOnly = CVReadOnlyPixelBuffer(mutable)
                let time = CMTime(value: CMTimeValue(frame), timescale: 60)
                progressShared.beginAppend("PixelBufferReceiver.\(mode) frame \(frame)",
                                           writerStatus: rig.statusDescription)
                let began = mach_absolute_time()
                if mode == "immediate" {
                    var accepted = false
                    while !accepted {
                        accepted = try receiver.appendImmediately(readOnly, with: time)
                        if !accepted { try await Task.sleep(for: .milliseconds(2)) }
                    }
                } else {
                    try await receiver.append(readOnly, with: time)
                }
                let spent = (mach_absolute_time() - began) * tb.numer / tb.denom
                result.maxAppendNanos = max(result.maxAppendNanos, spent)
                progressShared.endAppend()
                if holdBuffers { held.append(readOnly) }
                result.appended += 1
            }
            receiver.finish()
            await rig.writer.finishWriting()
        } catch {
            result.error = "\(error)"
        }
        return result
    }

    /// The sample path builds its pixel buffers with `CVPixelBufferCreate`
    /// rather than from a `CVMutablePixelBuffer.Pool`, and that is deliberate
    /// twice over. It is closer to the real path — `SCStream` hands
    /// `CaptureSession` a `CMSampleBuffer` whose backing it did not allocate —
    /// and it keeps a non-`Sendable` `CMSampleBuffer` from having to leave the
    /// closure `withUnsafeBuffer` scopes it to, which Swift 6 rejects outright.
    /// What is being measured is whether `append` returns; where the pixels
    /// came from does not enter that question.
    nonisolated static func runSampleReceiver(frames: Int, width: Int, height: Int,
                                              mode: String, lifecycle: String) async -> Result {
        var result = Result()
        do {
            let rig = try Rig.make(width: width, height: height)
            defer { rig.cleanUp() }
            if lifecycle == "mixed" { rig.addInputTheOldWay() }
            let receiver = try rig.writer.inputReceiver(for: rig.input)
            if lifecycle == "mixed" { rig.startTheOldWay() } else { try rig.startNew() }
            let tb = timebase()
            for frame in 0..<frames {
                let sample = try makeSampleBuffer(width: width, height: height, frame: frame)
                progressShared.beginAppend("SampleBufferReceiver.\(mode) frame \(frame)",
                                           writerStatus: rig.statusDescription)
                let began = mach_absolute_time()
                if mode == "immediate" {
                    // The non-suspending variant, and the control that separates
                    // "this API hangs" from "this spike used it wrong". If the
                    // awaiting form never resumes while this one keeps returning
                    // false and then true, the fault is in the suspension, not in
                    // the caller's pacing.
                    var accepted = false
                    while !accepted {
                        accepted = try receiver.appendImmediately(sample)
                        if !accepted { try await Task.sleep(for: .milliseconds(2)) }
                    }
                } else {
                    try await receiver.append(sample)
                }
                let spent = (mach_absolute_time() - began) * tb.numer / tb.denom
                result.maxAppendNanos = max(result.maxAppendNanos, spent)
                progressShared.endAppend()
                result.appended += 1
            }
            receiver.finish()
            await rig.writer.finishWriting()
        } catch {
            result.error = "\(error)"
        }
        return result
    }

    /// **The positive control, and the run that decides what this spike means.**
    ///
    /// The same writer, the same settings, the same frames, through the API the
    /// successors replace: `AVAssetWriterInput.append(_:)` paced by
    /// `isReadyForMoreMediaData`, both deprecated at 27.0. If this sails past
    /// the frame where the receivers stop, the stall is a property of the
    /// successor stack. If it stops in the same place, the rig is wrong and
    /// every other result here is about this file rather than about
    /// AVFoundation.
    ///
    /// Deprecation warnings are expected on this function. They are the point.
    nonisolated static func runLegacy(frames: Int, width: Int, height: Int) async -> Result {
        var result = Result()
        do {
            let rig = try Rig.make(width: width, height: height)
            defer { rig.cleanUp() }
            rig.startLegacy()
            let tb = timebase()
            for frame in 0..<frames {
                let sample = try makeSampleBufferRaw(width: width, height: height, frame: frame)
                progressShared.beginAppend("legacy AVAssetWriterInput.append frame \(frame)",
                                           writerStatus: rig.statusDescription)
                let began = mach_absolute_time()
                while !rig.input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard rig.input.append(sample) else {
                    result.error = "the legacy append refused frame \(frame): \(rig.statusDescription)"
                    return result
                }
                let spent = (mach_absolute_time() - began) * tb.numer / tb.denom
                result.maxAppendNanos = max(result.maxAppendNanos, spent)
                progressShared.endAppend()
                result.appended += 1
            }
            rig.input.markAsFinished()
            await rig.writer.finishWriting()
        } catch {
            result.error = "\(error)"
        }
        return result
    }

    /// Wraps a freshly-made pixel buffer as the `CMReadySampleBuffer` that
    /// `SampleBufferReceiver.append(_:)` takes.
    nonisolated static func makeSampleBuffer(width: Int, height: Int, frame: Int) throws
        -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let buffer = try makeSampleBufferRaw(width: width, height: height, frame: frame)
        // Not failable: `CMReadySampleBuffer` is the type-level statement that
        // the buffer is ready, so the narrowing is total rather than a check.
        return CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: buffer)
    }

    nonisolated static func makeSampleBufferRaw(width: Int, height: Int, frame: Int) throws
        -> CMSampleBuffer {
        var raw: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &raw)
        guard status == kCVReturnSuccess, let pixelBuffer = raw else {
            throw SpikeError.pixelBufferCreateFailed(status)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(frame & 0xFF),
                   CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let format = try CMFormatDescription(imageBuffer: pixelBuffer)
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 60),
            decodeTimeStamp: .invalid)
        return try CMSampleBuffer(imageBuffer: pixelBuffer,
                                  formatDescription: format,
                                  sampleTiming: timing)
    }

    enum SpikeError: Error { case pixelBufferCreateFailed(CVReturn) }
}

nonisolated let progressShared = Progress()
