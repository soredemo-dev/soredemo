import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Framing
import Geometry
import Project
import Render
import Testing
import Timeline
// `@testable`, not a plain import: `MasterWriting`, `MasterTrackWriting` and
// `LegacyMasterWriter` are internal to `Capture`. They are internal for a good reason — the app
// reaches the master writer through `CaptureSession` and nothing outside `Capture` has business
// opening one — and widening them to `public` so a test could reach them would make the test the
// justification for a wider product surface. `@testable` is the mechanism that exists precisely
// so it does not have to be.
@testable import Capture
@testable import Compositing

// MARK: - what this file is, and what it is not
//
// **The ROADMAP's `smoke-tests` row: record → review → edit → export, in one pass, through the
// product's own code at every step.** Every other test in this package checks one tier against
// inputs written for it. That is the right shape for a unit test and it leaves one class of
// defect entirely unwatched: the JOINS. A recorder whose log the reader cannot open, a media
// filename the log-locator does not recognise, an edit the compositor is not looking at — each
// of those is invisible to a suite where the writer's output and the reader's input are two
// different fixtures maintained by hand.
//
// So the recording here is MADE, not loaded. `LegacyMasterWriter` writes the movie and
// `ObservationWriter` writes the log — the same two objects a real take uses — and everything
// downstream is handed what they produced rather than what a fixture author thought they
// produce.
//
// **Three things this deliberately does not cover, stated rather than left to be discovered.**
//
//  1. **The app tier.** `RecordingCoordinator`, the menu bar panel, the settings window and the
//     region picker are in the Xcode app target, which has no test target at all (`ROADMAP.md`,
//     `project-format`). `scripts/run-cross-boundary-probe.sh` is the app tier's instrument and
//     it does not reach the coordinator either. A camera left on screen after the panel said
//     "No camera" was found by reading, not by a gate, and this file would not have caught it.
//  2. **ScreenCaptureKit.** Nothing here opens an `SCStream`. The chain starts at the first
//     thing downstream of the frame callback — the master writer — because a real capture needs
//     a TCC grant, a display and a person, and a gate that needs those is not a gate.
//  3. **The package assembly.** A real take routes its bytes through `ProjectDocument.addMedia`,
//     which is app tier. Here the two writers are pointed straight at a package-shaped directory
//     built in the temporary folder. What that costs is stated: the `media/master-NN.mov` ↔
//     `observations/segment-NN.jsonl` naming is asserted below rather than inherited, so this
//     file would notice the convention drifting even though it does not exercise the code that
//     normally establishes it.
//
// **Why it lives in `CompositingTests` and not a target of its own.** `StageCompositor`'s
// configuration is process-global — AVFoundation owns compositor instances, so there is nowhere
// else to hang it — and `swift test` runs every test target in ONE process (measured: one
// `Test run with N tests in M suites` line for the whole package, not one per target). Swift
// Testing parallelises across suites in different modules just as readily as within one, so a
// smoke suite in its own target would race `MP4ExporterTests` over `observationLogURL` and
// `editTimeline` and fail intermittently in whichever of the two lost. Extending
// `StageCompositorTests` inherits its `.serialized` trait, which is the only thing in this
// package that serialises those writes. The cost is that `CompositingTests` now links `Capture`;
// `theSmokeTestIsTheOnlyCompositingTestThatImportsCapture` in `AppSourceTests` is what keeps that
// a single sanctioned crossing rather than an open door.

extension StageCompositorTests {

    // MARK: - the recording, and the fixed facts it is built from

    /// Fixed rather than minted, so a failure here reproduces from the same numbers. Nothing in
    /// this file needs a distinct boot session; what it needs is that the epoch the writer
    /// stamps into the header is the epoch the reader checks every record against, which a
    /// constant states more plainly than a fresh UUID would.
    private static let smokeEpoch = BootEpoch(
        id: UUID(uuidString: "6E1A0C74-2F58-4B0D-9C31-6A5F7D2E8B41")!)
    private static let smokeRevision = GeometryRevision(id: 7)

    /// The host time the recording's clock starts at. Non-zero on purpose: an anchor at zero
    /// would let a caller that dropped the anchor term entirely still land on the right instant,
    /// which is exactly the arithmetic `EpochAnchor.instant(atOffset:)` exists to own.
    private static let smokeAnchorHostTime = Nanoseconds(9_000_000_000)

    /// **The SOURCE's cadence, which is not the export's.** 30 rather than 60 because a screen
    /// recording is not constant-rate to begin with — ScreenCaptureKit emits a frame when the
    /// screen changes — and because the export resamples to its own rate regardless, which is
    /// the behaviour `theExportIsConstantFrameRateWhateverTheSourceCadenceIs` pins. A source at
    /// the export's own rate would let a resampler that did nothing pass.
    private static let smokeSourceFrameRate = 60 / 2
    /// `MP4Exporter`'s default, and what the exported track must report.
    private static let smokeExportFrameRate = 60

    /// **Three seconds, and the length is set by the camera rather than by taste.** A `ZoomBlock`
    /// covers [click − 0.4 s, click + 1.0 s], so two clicks less than 1.4 s apart merge into one
    /// block aimed at the UNION of their targets. Measured here: with the two clicks 1.0 s apart
    /// the union came out 0.55 × 0.55 of the screen, `FramingDepth.zoom` answered 1.0 — correctly,
    /// a target that large is not worth moving the camera for — and
    /// `aReviewersDecisionReachesTheExportedPixels` compared two exports in which the camera had
    /// genuinely never moved. Three seconds gives the two clicks 1.7 s of daylight, so each keeps
    /// its own block and the reviewer's rectangle is the only thing the second block is aimed at.
    private static let smokeSeconds = 3.0
    private static let smokeFrameCount = 90
    private static let smokeWidth = 320
    private static let smokeHeight = 180

    /// Where the two clicks sit inside the take, as offsets from the anchor.
    private static let framedClickOffset = Nanoseconds(500_000_000)
    private static let refusedClickOffset = Nanoseconds(2_200_000_000)

    /// A recording on disk, plus the facts a reviewer would need to talk about it.
    private struct SmokeRecording {
        let packageURL: URL
        let mediaURL: URL
        let logURL: URL
        let anchor: EpochAnchor
        /// The click the gate accepts, and the one it refuses. Held as instants because every
        /// downstream question — which entry, which override, which frame — is asked in terms
        /// of them.
        let framedClick: HostInstant
        let refusedClick: HostInstant
    }

    /// One 32BGRA frame, timed at `frame`/60.
    ///
    /// **The lower-left quadrant is painted, and that is not decoration.** The first version of
    /// this fixture was a flat fill, on the reasoning that this chain's assertions are about
    /// times and lengths rather than pixels. `aReviewersDecisionReachesTheExportedPixels` then
    /// compared two exports that differed only in a framing override and found them
    /// byte-identical — because zooming into a uniform image is the identity, so a camera that
    /// moved correctly produced exactly the frames a camera that never moved would. A fixture
    /// with no features cannot witness a camera, and the test would have read that as the
    /// override doing nothing.
    private static func smokeVideoSample(frame: Int) throws -> CMSampleBuffer {
        let pixelBuffer = try makePixelBuffer(width: smokeWidth, height: smokeHeight,
                                              fill: sourceFill)
        try paintQuadrant(pixelBuffer, width: smokeWidth, height: smokeHeight,
                          colour: (r: 250, g: 240, b: 40))
        let format = try CMFormatDescription(imageBuffer: pixelBuffer)
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(smokeSourceFrameRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(frame),
                                          timescale: CMTimeScale(smokeSourceFrameRate)),
            decodeTimeStamp: .invalid)
        return try CMSampleBuffer(imageBuffer: pixelBuffer, formatDescription: format,
                                  sampleTiming: timing)
    }

    /// One block of silent 48 kHz stereo Float32, the shape `CaptureSession` feeds both audio
    /// tracks unprocessed.
    ///
    /// **The block length is DERIVED from the video rate, and that is load-bearing.** One block is
    /// appended per video frame, so a block that does not span exactly one frame's worth of time
    /// makes the two tracks' presentation timestamps drift apart by the difference on every
    /// iteration. `AVAssetWriter` stops signalling `isReadyForMoreMediaData` on an input that has
    /// run far ahead of its siblings, so the drift eventually stalls the feed on any writer that
    /// does not relax interleaving. Measured in `scripts/cross-boundary-digest-probe.swift`, whose
    /// header records the two stalls (video frame 84, then frame 78) that located it with a
    /// hardcoded 1024-frame block against 60 fps video. Writing it as a division rather than as
    /// the constant that division happens to produce is what keeps it true if the source rate
    /// above moves.
    private static func smokeAudioSample(frame: Int) throws -> CMSampleBuffer {
        let framesPerBlock = 48_000 / smokeSourceFrameRate
        let bytesPerFrame = 8

        var format: CMFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        // `unsafe`: C constructors writing through out-parameters. Safe here — `asbd` and
        // `format` are locals that outlive the call, and the result is taken through `#require`,
        // which fails the test rather than reading an unwritten handle.
        _ = unsafe CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let description = try #require(format)

        // `memoryBlock: nil` with `kCMBlockBufferAssureMemoryNowFlag`: CoreMedia allocates and
        // owns the block, so there is no manual allocation here to leak on a throw. That memory
        // is uninitialised, so it is filled — silence, which is all the audio assertions below
        // ask of these samples: that audio reached the file at all, not what it sounded like.
        // Uninitialised would still encode, and would make the fixture's bytes differ run to
        // run for no reason anyone could see.
        var block: CMBlockBuffer?
        _ = unsafe CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: framesPerBlock * bytesPerFrame, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: framesPerBlock * bytesPerFrame,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let data = try #require(block)
        #expect(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0,
                                           dataLength: framesPerBlock * bytesPerFrame)
                == kCMBlockBufferNoErr)

        var buffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: CMTimeValue(frame * framesPerBlock),
                                          timescale: 48_000),
            decodeTimeStamp: .invalid)
        // **`sampleSizeEntryCount: 1` with the real per-frame size, not `0`/`nil`.** The `0`/`nil`
        // form says "these samples have no size", which is legal for a buffer nobody muxes and
        // fatal for one handed to `AVAssetWriter`: it fails the WHOLE writer, every input, with
        // `-12735` (`kCMSampleBufferError_BufferHasNoSampleSizes`) buried two levels down inside
        // an `AVErrorUnknown`. Measured here, and the shape of the report is worth recording —
        // the writer did not refuse the audio append that caused it. It accepted the block,
        // failed asynchronously in the muxer, and surfaced the failure on the next VIDEO append,
        // at frame 34 of 120. A chain that reported "export produced nothing" would have sent
        // the next reader looking in the wrong tier entirely.
        var sampleSize = bytesPerFrame
        _ = unsafe CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: description,
            sampleCount: framesPerBlock, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &buffer)
        return try #require(buffer)
    }

    /// An AX chain the gate accepts: a small rectangle containing the click, read quickly, at the
    /// click's own revision, on a walk that reached the root. Built through the record's own
    /// initialiser rather than as JSON — the on-disk shape belongs to `AXChainRecord` and is
    /// pinned by its own round-trip tests.
    private static func framedChain(at instant: HostInstant) -> AXChainRecord {
        let click = NormalizedPoint(x: 0.5, y: 0.5)
        let frame = NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                                    size: NormalizedSize(width: 0.2, height: 0.2),
                                    revision: smokeRevision)
        let readInterval = HostRange(epoch: smokeEpoch, start: instant.hostTime,
                                     duration: Nanoseconds(200_000))
        return AXChainRecord(
            instant: instant,
            clickPosition: click,
            clickRevision: smokeRevision,
            hitTestGlobalX: 640, hitTestGlobalY: 360,
            // Well under `FramingGate.stalenessBudget`; a slower read would be refused as
            // `.staleObservation` and this chain would stop being the accepted one.
            hitTestInterval: HostRange(epoch: smokeEpoch, start: instant.hostTime,
                                       duration: Nanoseconds(200_000)),
            hit: AXElementRecord(role: "AXButton", title: "Send", frame: frame,
                                 readInterval: readInterval),
            ancestors: [], children: nil,
            // `.reachedRoot` is what makes an empty `ancestors` legal: the walk finished, so
            // this element genuinely has none. Any other truncation with no ancestors is
            // `.bestCandidateOnTheTruncationBoundary`.
            truncation: .reachedRoot,
            axCalls: 3, depthCap: 12, walkBudgetNanos: 8_000_000)
    }

    /// A chain the gate refuses, with the reason a real machine produces most often: the
    /// hit-test returned nothing, which is what an ungranted Accessibility permission looks like
    /// from here.
    private static func refusedChain(at instant: HostInstant) -> AXChainRecord {
        AXChainRecord(
            instant: instant,
            clickPosition: NormalizedPoint(x: 0.25, y: 0.75),
            clickRevision: smokeRevision,
            hitTestGlobalX: 320, hitTestGlobalY: 180,
            hitTestInterval: HostRange(epoch: smokeEpoch, start: instant.hostTime,
                                       duration: Nanoseconds(150_000)),
            hit: nil, ancestors: [], children: nil,
            truncation: .hitTestReturnedNothing,
            axCalls: 1, depthCap: 12, walkBudgetNanos: 8_000_000)
    }

    /// **The record leg.** Writes a package-shaped directory with a real movie and a real
    /// observation log, both through the objects the product uses, and returns where they are.
    ///
    /// The caller removes `packageURL`.
    private static func makeSmokeRecording() async throws -> SmokeRecording {
        let packageURL = FileManager.default.temporaryDirectory
            .appending(path: "smoke-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
        let mediaDirectory = packageURL.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        // `master-00.mov`, the exact `%02d` form `CaptureSession` mints, because
        // `ObservationWriter.expectedLogURL(forMediaURL:)` parses it and this chain asserts that
        // it still resolves.
        let mediaURL = mediaDirectory.appending(path: "master-00.mov", directoryHint: .notDirectory)

        let writer = try LegacyMasterWriter(
            outputURL: mediaURL,
            videoSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: smokeWidth, AVVideoHeightKey: smokeHeight],
            // Neither closure is reachable with these settings — see `MasterWriterTests`'
            // `aWriterThatCannotOpenItsOutputThrows`, which records that a refusal-producing
            // setting traps inside `AVAssetWriterInput` before either could fire. They are
            // required by the signature, so they name the situation rather than returning a
            // placeholder that would read as expected.
            refusedInput: { SmokeChainError.writerRefusedAnInput($0) },
            startFailed: { SmokeChainError.writerRefusedToStart($0 ?? "start() reported nothing") })
        try #require(writer.status == .writing, "a fresh master writer must already be writing")

        writer.startSession(at: .zero)
        for frame in 0..<smokeFrameCount {
            try await waitUntilReady(writer.video, label: "video", frame: frame, writer: writer)
            guard writer.video.append(try smokeVideoSample(frame: frame)) else {
                throw SmokeChainError.appendRefused(track: "video", frame: frame,
                                                    status: writer.status.name,
                                                    detail: writer.errorDescription)
            }
            for (label, track) in [("systemAudio", writer.systemAudio),
                                   ("microphone", writer.microphone)] {
                try await waitUntilReady(track, label: label, frame: frame, writer: writer)
                guard track.append(try smokeAudioSample(frame: frame)) else {
                    throw SmokeChainError.appendRefused(track: label, frame: frame,
                                                        status: writer.status.name,
                                                        detail: writer.errorDescription)
                }
            }
        }
        await writer.finish()
        guard writer.status == .completed else {
            throw SmokeChainError.writerDidNotComplete(status: writer.status.name,
                                                       detail: writer.errorDescription)
        }

        // The log. Its anchor is the recording's clock, and every instant below is derived from
        // it by `EpochAnchor.instant(atOffset:)` rather than by adding two numbers — the
        // conversion has one owner and this is it.
        let anchor = EpochAnchor(epoch: smokeEpoch, hostTime: smokeAnchorHostTime,
                                 wallClockUnixNanos: 1_756_000_000_000_000_000)
        let header = ObservationLogHeader(anchor: anchor, segmentIndex: 0,
                                          mediaFilename: "master-00.mov",
                                          revision: smokeRevision,
                                          // Nothing was blind: this recording had every
                                          // observer it wanted. `[]` asserts that was checked.
                                          blindness: [])
        let log = try ObservationWriter.open(segment: header, in: packageURL)

        let framedClick = anchor.instant(atOffset: framedClickOffset)
        let refusedClick = anchor.instant(atOffset: refusedClickOffset)

        // A pointer sample every 100 ms across the whole take, so the exported video has a
        // cursor track to place and the reader has something to merge the chains into.
        let pointerSteps = Int(smokeSeconds * 10)
        for step in 0...pointerSteps {
            let instant = anchor.instant(atOffset: Nanoseconds(Int64(step) * 100_000_000))
            let progress = Double(step) / Double(pointerSteps)
            try log.append(PointerSample(
                instant: instant,
                position: NormalizedPoint(x: 0.1 + 0.8 * progress, y: 0.5),
                revision: smokeRevision))
        }
        try log.append(framedChain(at: framedClick))
        try log.append(refusedChain(at: refusedClick))

        let takeNanos = Int64(smokeSeconds * 1_000_000_000)
        let span = HostRange(epoch: smokeEpoch, start: anchor.hostTime,
                             duration: Nanoseconds(takeNanos))
        try log.close(
            endedBy: .stopped,
            hostRange: span,
            // One row per `GapSite`, because the trailer refuses to decode without them: an
            // absent site reads as "no gaps there" and is indistinguishable from "this version
            // did not look". These say the sites were watched and saw nothing, which is the
            // truth of a synthesised take.
            gapWatches: [
                .tapDisabled(tapEnabledPolls: 60, tapPollingSpanNanos: takeNanos,
                             tapDisabledIntervals: 0, tapBlindNanos: 0),
                .secureInput(secureInputChecks: 60, secureInputCheckSpanNanos: takeNanos,
                             secureInputIntervals: 0, suppressedNanos: 0),
                .videoFramesNotProduced(frameCallbacksObserved: smokeFrameCount,
                                        observationSpanNanos: takeNanos, idleFrames: 0),
                .axAncestorWalk(chainsRecorded: 2, observationSpanNanos: takeNanos,
                                truncatedWalks: 0),
            ])

        return SmokeRecording(packageURL: packageURL, mediaURL: mediaURL, logURL: log.url,
                              anchor: anchor, framedClick: framedClick, refusedClick: refusedClick)
    }

    /// Polls one track's readiness with a bounded wait. Bounded because an unbounded one turns a
    /// writer that has stopped accepting into a `swift test` that never finishes and says
    /// nothing — the failure mode this package's export deadline exists for one tier down.
    private static func waitUntilReady(_ track: any MasterTrackWriting, label: String,
                                       frame: Int, writer: any MasterWriting) async throws {
        var waits = 0
        while !track.isReadyForMoreMediaData {
            waits += 1
            // 750 × 2 ms = 1.5 s. Short deliberately: the measured stall this bound exists for
            // does not recover with patience, so a longer wait makes a real failure slower to
            // report without turning it into a pass.
            guard waits < 750 else {
                throw SmokeChainError.trackNeverBecameReady(track: label, frame: frame,
                                                            status: writer.status.name,
                                                            detail: writer.errorDescription)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Named failures, so a red smoke test says which leg broke without anyone reading the
    /// source. A chain of five stages reporting one generic error is a chain that has to be
    /// bisected by hand every time it fails.
    private enum SmokeChainError: Error, CustomStringConvertible {
        case writerRefusedAnInput(String)
        case writerRefusedToStart(String)
        case appendRefused(track: String, frame: Int, status: String, detail: String?)
        case trackNeverBecameReady(track: String, frame: Int, status: String, detail: String?)
        case writerDidNotComplete(status: String, detail: String?)
        case frameHadNoPixels(atSeconds: Double, export: String)

        var description: String {
            switch self {
            case .writerRefusedAnInput(let which):
                "the master writer refused the \(which) input"
            case .writerRefusedToStart(let detail):
                "the master writer would not start: \(detail)"
            case .appendRefused(let track, let frame, let status, let detail):
                "\(track) refused frame \(frame) — writer \(status): \(detail ?? "no error recorded")"
            case .trackNeverBecameReady(let track, let frame, let status, let detail):
                "\(track) never became ready for frame \(frame) — writer \(status): "
                + "\(detail ?? "no error recorded")"
            case .writerDidNotComplete(let status, let detail):
                "the master writer finished as \(status): \(detail ?? "no error recorded")"
            case .frameHadNoPixels(let seconds, let export):
                "the \(export) export produced no pixels at \(seconds)s"
            }
        }
    }

    // MARK: - record → review

    /// **The seam no unit test watches: the log the recorder wrote is one the reviewer can
    /// open.** Every other test of the reading side supplies its own log, and every other test
    /// of the writing side reads back only what it just appended. Between them sits the question
    /// neither asks — whether the bytes one produces are the bytes the other accepts — and it is
    /// answered here by handing the reader nothing but a path the writer returned.
    ///
    /// The naming convention is asserted rather than assumed for the same reason. A real take
    /// puts the movie in the package through `ProjectDocument.addMedia`, which is app tier and
    /// out of reach; what `expectedLogURL(forMediaURL:)` promises is that given media of the
    /// shape the recorder mints, the log is findable by name alone. Nothing else in this package
    /// checks that promise against a filename the recorder's own `%02d` form produced.
    @Test func aRecordingsOwnLogIsFoundByNameAndReadByTheReviewer() async throws {
        let recording = try await Self.makeSmokeRecording()
        defer { try? FileManager.default.removeItem(at: recording.packageURL) }

        let located = try #require(
            ObservationWriter.expectedLogURL(forMediaURL: recording.mediaURL),
            "the log locator did not recognise the filename the recorder minted")
        #expect(located == recording.logURL, """
            the recorder wrote \(recording.logURL.lastPathComponent) beside \
            \(recording.mediaURL.lastPathComponent), and the locator looked for \
            \(located.lastPathComponent). The `media/master-NN.mov` ↔ \
            `observations/segment-NN.jsonl` pairing has drifted apart.
            """)

        let plan = try FramingPlanReader.plan(fromObservationLogAt: located)
        #expect(plan.entries.count == 2, "the reader found \(plan.entries.count) clicks, not 2")
        #expect(plan.framedCount == 1)
        #expect(plan.rejectionCounts[.hitTestReturnedNothing] == 1)

        // In time order, not append order — the plan is a timeline.
        let instants = plan.entries.map(\.instant)
        #expect(instants == [recording.framedClick, recording.refusedClick])

        // The accepted click carries what the gate concluded, all the way from the record the
        // writer encoded: the role is the one field that could only have survived a full
        // round trip through the file.
        let framed = try #require(plan.entries.first)
        if case .framed(let target) = framed.decision {
            #expect(target.role == "AXButton",
                    "the framed target's role arrived as \(target.role ?? "nil")")
        } else {
            Issue.record("the first click was refused as \(String(describing: framed.decision))")
        }
    }

    /// **A reviewer's decision is first-class, and re-deriving does not undo it.** The rectangle
    /// authored here is one no AX element in the log ever reported, which is what makes the
    /// assertion mean something: a resolution that returns it can only have come from the
    /// author, not from the producer re-running.
    @Test func areviewersOverrideOfARefusedClickSurvivesRederivation() async throws {
        let recording = try await Self.makeSmokeRecording()
        defer { try? FileManager.default.removeItem(at: recording.packageURL) }

        let plan = try FramingPlanReader.plan(fromObservationLogAt: recording.logURL)
        let authored = NormalizedFrame(origin: NormalizedPoint(x: 0.05, y: 0.05),
                                       size: NormalizedSize(width: 0.1, height: 0.1),
                                       revision: Self.smokeRevision)
        let override = FramingOverride(epoch: Self.smokeEpoch,
                                       instant: recording.refusedClick.hostTime,
                                       action: .frame(authored))

        let resolved = plan.resolved(with: [override])
        let reviewed = try #require(resolved.first { $0.instant == recording.refusedClick })
        #expect(reviewed.target?.frame == authored,
                "the authored rectangle did not survive resolution")
        guard case .authored(let over) = reviewed.origin else {
            Issue.record("the overridden click resolved as \(String(describing: reviewed.origin))")
            return
        }
        // The refusal is kept beside the override rather than discarded: a reviewer looking at
        // this later should be able to see what they overrode.
        #expect(over?.rejection == .hitTestReturnedNothing)

        // And the click the gate accepted is untouched by an override aimed at the other one.
        let untouched = try #require(resolved.first { $0.instant == recording.framedClick })
        #expect(untouched.origin == .derived)
    }

    // MARK: - record → review → edit → export

    /// **The whole row in one test: a recording this suite made, reviewed, cut, and exported —
    /// and the file that comes out is the length the edit says it is.**
    ///
    /// The length is the assertion because it is the one fact every stage can corrupt and none
    /// can fake. `EditTimeline` computes it as a sum of clip durations; `EditedAsset` has to
    /// build a composition that agrees; `MP4Exporter` has to generate an output timeline over it
    /// at a constant rate; and the writer has to close a file a reader then measures
    /// independently. A stage that dropped the cut, applied it twice, or resampled against the
    /// wrong timeline lands somewhere else.
    @Test func theWholeChainProducesAVideoTheLengthTheEditSaysItIs() async throws {
        let recording = try await Self.makeSmokeRecording()
        defer { try? FileManager.default.removeItem(at: recording.packageURL) }

        // — review —
        let plan = try FramingPlanReader.plan(fromObservationLogAt: recording.logURL)
        let override = FramingOverride(
            epoch: Self.smokeEpoch, instant: recording.refusedClick.hostTime,
            action: .frame(NormalizedFrame(origin: NormalizedPoint(x: 0.05, y: 0.05),
                                           size: NormalizedSize(width: 0.1, height: 0.1),
                                           revision: Self.smokeRevision)))
        #expect(plan.resolved(with: [override]).contains { $0.wasOverridden },
                "the review leg produced nothing for the export leg to honour")

        // — edit — cut the middle fifth out of the take.
        let source = AVURLAsset(url: recording.mediaURL)
        let recordedSeconds = try await source.load(.duration).seconds
        #expect(abs(recordedSeconds - Self.smokeSeconds) < 0.1,
                "the recording came out \(recordedSeconds)s, not the \(Self.smokeSeconds)s written")
        let recordedNanos = Int64(recordedSeconds * 1_000_000_000)
        let edit = EditTimeline.whole(duration: Nanoseconds(recordedNanos))
            .removing(sourceRange: (recordedNanos * 2 / 5)..<(recordedNanos * 3 / 5))
        #expect(edit.clips.count == 2, "a cut through the middle leaves two clips, not \(edit.clips.count)")

        let cut = try await EditedAsset.make(from: source, by: edit)
        let expectedSeconds = Double(edit.outputDuration.rawValue) / 1_000_000_000
        let cutSeconds = try await cut.load(.duration).seconds
        #expect(abs(cutSeconds - expectedSeconds) < 0.05,
                "the cut asset runs \(cutSeconds)s, the timeline says \(expectedSeconds)s")

        // — export — through the same compositor the preview uses, configured with the log this
        // recording wrote and the decision the review leg authored.
        //
        // `settings()`/`apply(_:)` rather than assigning the statics back by hand: a partial
        // restore leaves whichever field was forgotten pointing at this test's temporary
        // directory, and the suite this extends runs serially precisely so the next test sees
        // what it expects. `renderer` is deliberately outside `Settings` — it is a shared
        // `CIContext`, not part of what a frame looks like — so it is set, not restored.
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        StageCompositor.renderer = try CoreImageFrameRenderer()
        StageCompositor.style = .default
        StageCompositor.observationLogURL = recording.logURL
        StageCompositor.overrides = []
        StageCompositor.framingOverrides = [override]
        StageCompositor.editTimeline = edit

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "smoke-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let report = try await MP4Exporter.export(
            asset: cut, to: outputURL, outputWidth: Self.smokeWidth, outputHeight: Self.smokeHeight,
            // `assetIsAlreadyEdited: true` — the cut was made above so the compositor could be
            // handed the same timeline. Passing `edit` without it would cut the already-cut
            // asset a second time.
            edit: edit, assetIsAlreadyEdited: true)

        #expect(report.framesWritten > 0, "the export wrote no frames")
        #expect(report.frameRate == Self.smokeExportFrameRate)
        #expect(report.audioSamplesWritten > 0,
                "the master's two audio tracks did not reach the export")

        let exported = AVURLAsset(url: outputURL)
        let exportedSeconds = try await exported.load(.duration).seconds
        #expect(abs(exportedSeconds - expectedSeconds) < 0.05, """
            the exported file runs \(exportedSeconds)s; the edit says \(expectedSeconds)s and \
            the recording was \(recordedSeconds)s. A stage lost the cut, applied it twice, or \
            resampled against the wrong timeline.
            """)

        // One mixed audio track out of the master's two: a viewer has one pair of ears, and an
        // export carrying two tracks plays whichever the player picks.
        let audioTracks = try await exported.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1, "expected one mixed audio track, got \(audioTracks.count)")
    }

    /// **The review leg is not decoration: a reviewer's decision changes the exported pixels.**
    ///
    /// Everything above this point checks that the chain is WIRED — the log opens, the plan
    /// resolves, the file comes out the right length. None of it would notice an export that
    /// read `framingOverrides` and then ignored them, which is the failure that costs a person
    /// their afternoon: they correct a zoom, watch the preview obey, export, and ship the
    /// uncorrected video.
    ///
    /// So the recording is exported TWICE with one difference between the runs — the override —
    /// and the same frame is read out of each. Two exports rather than one absolute expectation
    /// because there is no rectangle anyone can assert a frame "should" look like; what can be
    /// asserted is that the decision made a difference, and a difference is only attributable
    /// when it is the only variable. The same shape `theCameraIsInTheExportedPictureAndNotOnlyIn
    /// ThePreview` uses in `EditedAssetTests`.
    ///
    /// **No edit here, deliberately.** With the timeline uncut, output time is source time, so
    /// the instant sampled is the instant the click was recorded at and nothing has to be
    /// converted to know where to look.
    @Test func aReviewersDecisionReachesTheExportedPixels() async throws {
        let recording = try await Self.makeSmokeRecording()
        defer { try? FileManager.default.removeItem(at: recording.packageURL) }

        let override = FramingOverride(
            epoch: Self.smokeEpoch, instant: recording.refusedClick.hostTime,
            action: .frame(NormalizedFrame(origin: NormalizedPoint(x: 0.05, y: 0.05),
                                           size: NormalizedSize(width: 0.1, height: 0.1),
                                           revision: Self.smokeRevision)))

        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        StageCompositor.renderer = try CoreImageFrameRenderer()

        // Three samples across the reviewed click's own zoom block rather than one: the camera
        // eases in and out, so a single instant could land where two different targets happen to
        // agree, and a test that measured that would report "the override did nothing" about a
        // build where it worked.
        let clickSeconds = Double(Self.refusedClickOffset.rawValue) / 1_000_000_000
        let sampleSeconds = [clickSeconds - 0.2, clickSeconds, clickSeconds + 0.2]
        let reviewed = try await Self.exportFramesForReview(of: recording, overrides: [override],
                                                            label: "reviewed", at: sampleSeconds)
        let unreviewed = try await Self.exportFramesForReview(of: recording, overrides: [],
                                                             label: "unreviewed", at: sampleSeconds)

        #expect(reviewed.count == sampleSeconds.count && unreviewed.count == sampleSeconds.count,
                "a sampled frame was missing, so this comparison would be over nothing")
        #expect(reviewed != unreviewed, """
            the exported frames around the reviewed click are byte-identical with and without \
            the override. Either the reviewer's decision is not reaching `CameraMotion`, or the \
            camera is not reaching the picture. The preview reads the same statics, so a person \
            correcting a zoom would see the correction on screen and ship the uncorrected video.
            """)
    }

    /// Exports `recording` whole, with `overrides` as the only variable, and returns the bytes of
    /// the decoded frames at `seconds`. Small on purpose — 160×90 — because this is a comparison
    /// rather than a picture anybody looks at.
    private static func exportFramesForReview(of recording: SmokeRecording,
                                              overrides: [FramingOverride],
                                              label: String,
                                              at seconds: [Double]) async throws -> [Data] {
        StageCompositor.style = .default
        StageCompositor.observationLogURL = recording.logURL
        StageCompositor.overrides = []
        StageCompositor.editTimeline = nil
        StageCompositor.framingOverrides = overrides

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "smoke-review-\(label)-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = try await MP4Exporter.export(asset: AVURLAsset(url: recording.mediaURL),
                                         to: outputURL, outputWidth: 160, outputHeight: 90)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        // Both tolerances zero: a tolerant generator is free to answer with a neighbouring frame,
        // and two runs that answered from different frames would differ for a reason that has
        // nothing to do with the override.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [Data] = []
        for second in seconds {
            let image = try await generator
                .image(at: CMTime(seconds: second, preferredTimescale: 600)).image
            guard let data = image.dataProvider?.data as Data? else {
                throw SmokeChainError.frameHadNoPixels(atSeconds: second, export: label)
            }
            frames.append(data)
        }
        return frames
    }

    /// **The pairing that keeps the reviewed video and the shipped video the same video.**
    ///
    /// `MP4Exporter` cannot be handed the compositor along with the edit — AVFoundation owns
    /// compositor instances — so the two are compared instead, and an export whose asset was cut
    /// one way while the static said another is refused rather than shipped with every cursor
    /// and every zoom displaced by the difference. `MP4ExporterTests` checks that comparison
    /// against a fixture; this checks it at the end of a real chain, where the mismatch is the
    /// mistake a person actually makes: cutting, then forgetting to tell the compositor.
    @Test func anExportIsRefusedWhenTheCompositorIsLookingAtADifferentEdit() async throws {
        let recording = try await Self.makeSmokeRecording()
        defer { try? FileManager.default.removeItem(at: recording.packageURL) }

        let source = AVURLAsset(url: recording.mediaURL)
        let recordedNanos = Int64(try await source.load(.duration).seconds * 1_000_000_000)
        let whole = EditTimeline.whole(duration: Nanoseconds(recordedNanos))
        let cutEdit = whole.removing(sourceRange: (recordedNanos * 2 / 5)..<(recordedNanos * 3 / 5))
        let cut = try await EditedAsset.make(from: source, by: cutEdit)

        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        StageCompositor.renderer = try CoreImageFrameRenderer()
        StageCompositor.observationLogURL = recording.logURL
        // The forgotten line: the compositor still believes nothing was cut.
        StageCompositor.editTimeline = whole

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "smoke-mismatch-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // `do`/`catch` rather than `#expect(throws:)`: the closure would have to capture the
        // non-`Sendable` `AVAsset`, which Swift 6 refuses.
        do {
            _ = try await MP4Exporter.export(
                asset: cut, to: outputURL, outputWidth: Self.smokeWidth,
                outputHeight: Self.smokeHeight, edit: cutEdit, assetIsAlreadyEdited: true)
            Issue.record("the export went ahead against an edit the compositor was not looking at")
        } catch let error as MP4Exporter.ExportError {
            // `if case`, not `==`: `ExportError` is deliberately not `Equatable` — several of
            // its cases carry a payload describing what went wrong, and giving it an equality
            // that ignored them would invite comparisons that pass on the wrong instance.
            guard case .editTimelineMismatch = error else {
                Issue.record("refused, but as \(error) rather than the edit mismatch")
                return
            }
        }

        // And nothing was left where a person asked for their video: a half-written file looks
        // like an export that worked.
        #expect(!FileManager.default.fileExists(atPath: outputURL.path),
                "a refused export left a file behind")
    }
}
