@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Geometry
import Project
import Timeline

/// The master, written by `AVAssetWriter`. `ROADMAP.md`'s `capture-stream` and
/// `audio-tracks` rows — one object because they are one writer: the thing
/// that takes three ScreenCaptureKit streams and produces a `MasterSegment`.
///
/// **`SCRecordingOutput` is not usable at our floor** (design doc F2-4,
/// measured over four runs): it mixes the microphone into the system-audio
/// track, and the property that would stop it, `mixesAudioWithMicrophone`, is
/// `API_AVAILABLE(macos(27.0))` — confirmed against
/// `ScreenCaptureKit/SCRecordingOutput.h` directly before writing a line of
/// this file, not assumed from the design doc's paraphrase. `audio-tracks`
/// requires independent tracks, so this type takes `SCStreamOutputTypeScreen`,
/// `.audio` and `.microphone` as three separate `SCStreamOutput` deliveries
/// and writes them to three `AVAssetWriterInput`s of its own.
///
/// **`showsCursor = false`, and why (Step 0).** The master is unprocessed
/// evidence (D2-8); the cursor is a derived value the compositor draws later
/// from the pointer track, spring-smoothed. Burning it into the master would
/// put a producer's output into the evidence layer.
///
/// **The master is a sequence, not one file (D2-9).** `pause` and `resume`
/// appear zero times in `ScreenCaptureKit.framework`'s headers — confirmed by
/// grep across every header in the framework, not inferred from prose — so
/// there is no way to suspend and continue one `SCStream`/`AVAssetWriter`
/// pair. `pause()` therefore finalises the current segment and tears the
/// whole stream down; `resume()` builds a new one. Same mechanism handles
/// display reconfiguration (D2-10) and a hard stream failure: all three are
/// "close this segment, for this reason" events, and `SegmentBoundary`
/// already has a case for each.
///
/// **Colour space is pinned, per D2-15, and the choice here is a documented
/// placeholder, not a settled answer.** `SCStreamConfiguration.colorSpaceName`
/// defaults to "the same color space as the display" — confirmed against the
/// header (`SCStream.h`) — which makes an unset master's colour meaning
/// *machine-dependent*, the same failure shape `GeometryRevision` exists to
/// prevent on the geometry axis. D2-15 leaves open whether to pin sRGB or a
/// wider gamut, and says explicitly that deciding needs a measurement of
/// whether a wide-gamut master survives the (not-yet-built) compositor
/// unchanged — a measurement this task cannot make, because there is no
/// compositor yet. `kCGColorSpaceSRGB` is pinned here as the conservative
/// choice — well-understood, matches what most viewers of an eventual export
/// will have, and is what the human verification's Step 1 checks was
/// actually written to the file, rather than assumed.
///
/// **Locking.** Every mutable property below is read or written only inside
/// `lock.withLock { … }` — never via raw `lock.lock()`/`.unlock()`, which
/// `NSLocking` marks `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` on this SDK (measured
/// by compiling this file: the first draft used raw lock/unlock inside
/// `async` methods and `swiftc` rejected it outright, "Use async-safe scoped
/// locking instead" — a compile error, not a style preference). Critical
/// sections are kept synchronous and short; nothing awaits while holding the
/// lock.
public final class CaptureSession: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    // MARK: - Configuration knobs held for the life of the session

    private let source: CaptureSource
    private let scale: Double
    private let displayUUID: UUID
    private let packageURL: URL
    private let epoch: BootEpoch

    /// Every Nth complete video frame is luminance-sampled for the black-frame
    /// detector (Step 3). **Placeholder — not calibrated.** Chosen so a 30
    /// fps capture checks roughly once a second; there is no measured
    /// distribution behind this number, exactly as D4 requires such a number
    /// to be labelled until one exists.
    /// `nonisolated` on all three constants below — read from
    /// `checkForBlackFrame`, which is itself `nonisolated` (called
    /// synchronously from the `SCStreamOutput` callback), and an
    /// unannotated `static let` is implicitly `@MainActor` here exactly
    /// like every other case this task's report documents.
    private nonisolated static let blackFrameCheckEveryNFrames = 30
    /// Consecutive *checks* (not frames) with every grid sample at floor
    /// before the detector logs. **Placeholder.** At the check cadence above,
    /// 10 checks is roughly 10 seconds of a uniformly black signal — long
    /// enough that a brief real black frame (a cut, a flash) will not trip
    /// it, short enough to notice a revoked grant inside a short recording.
    /// Not fitted to any measured recording; see the doc comment on
    /// `checkForBlackFrame` for why this only logs.
    private nonisolated static let blackFrameConsecutiveThreshold = 10
    /// "At floor" for a BGRA byte, normalised 0...1. Placeholder alongside
    /// the two above — the whole detector is one undivided placeholder,
    /// labelled as such per `AGENTS.md`/D4 rather than split into an
    /// individually-tuned constant that would look more considered than it
    /// is.
    private nonisolated static let blackFrameLuminanceFloor = 0.02

    // MARK: - Public result types

    public enum SessionError: Error, Equatable {
        case alreadyRunning
        case notRunning
        case noSegmentOpen
        case writerFailed(String)
        case streamFailed(String)
    }

    /// What this session has observed, for `input-observation` and
    /// `observation-log` (neither built yet) to consume — see the task
    /// report for the exact shape those two rows need from here. Not
    /// persisted by this type; `stop()`'s caller reads it after the fact.
    public struct Diagnostics: Sendable {
        /// Keyed by `SCFrameStatus.rawValue` — 0 complete, 1 idle, 2 blank,
        /// 3 suspended, 4 started, 5 stopped. F2-4 measured idle at 42–84% of
        /// callbacks across four runs; this is what lets a caller reproduce
        /// that measurement from a real session instead of trusting the
        /// figure.
        public internal(set) var frameStatusCounts: [Int: Int] = [:]
        public internal(set) var completeFrameCount = 0
        /// Frames whose `SCStreamFrameInfoContentScale` was not 1 — D2-13a:
        /// "a frame whose content scale is not 1 *was* resampled", which is
        /// what makes "the master is unresampled" (D2-8's core claim)
        /// checkable rather than assumed. See `recordContentScale` for the
        /// assert-vs-record decision.
        public internal(set) var resampledFrameCount = 0
        public internal(set) var minContentScaleObserved: Double?
        public internal(set) var maxContentScaleObserved: Double?
        /// The most recently observed `ContentRect`/`ScreenRect`, bridged to
        /// `PointRect` immediately on extraction (never held as `CGRect` —
        /// rule 5). D2-13a: these carry the window's extrinsic mapping and
        /// "must not enter the digest" — kept here only as a diagnostic, the
        /// latest value rather than a full per-frame history, which belongs
        /// to `observation-log` once it exists.
        public internal(set) var lastContentRect: PointRect?
        public internal(set) var lastScreenRect: PointRect?
        /// A count only, per boundary this session actually closed with
        /// `.displayReconfigured` — not every callback the OS delivered.
        public internal(set) var displayReconfigurationsHandled = 0
        /// One entry per time the black-frame detector's placeholder
        /// threshold was reached. Logged, never causes a `.failed` boundary
        /// on its own — see `checkForBlackFrame`.
        public internal(set) var blackFrameDetections: [(segmentIndex: Int, consecutiveChecks: Int)] = []
        /// PTS → callback latency, nanoseconds, one entry per complete video
        /// frame — F2-4 measured p50 ~2 ms, p90 ~9 ms, a tail to 175 ms; this
        /// is what lets that be reproduced from a real run rather than only
        /// quoted from the spike.
        public internal(set) var ptsToCallbackLatencyNanos: [Int64] = []
    }

    public nonisolated var diagnostics: Diagnostics { lock.withLock { _diagnostics } }

    // MARK: - Mutable session state, all behind `lock`
    //
    // `nonisolated(unsafe)` on every stored property below, deliberately —
    // not left to `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Verified by
    // compiling this file: with no annotation, each property is implicitly
    // `@MainActor`, and `handleScreenSample`/`appendAudio` (called
    // synchronously from `SCStreamOutput`'s callback, which cannot be
    // `async`) cannot touch a `@MainActor` property without one — the
    // compiler's own error was "can not be mutated from a nonisolated
    // context" against nearly every property here in turn. `unsafe` is
    // honest, not a suppression: nothing here is protected by actor
    // isolation, everything is protected by `lock`, and `withLock`'s closure
    // is what actually keeps concurrent access safe. This is the same
    // `@unchecked Sendable` contract the class itself already declares, one
    // level down at the property.

    private let lock = NSLock()
    private let sampleQueue = DispatchQueue(label: "video.soredemo.CaptureSession.samples")

    private nonisolated(unsafe) var _diagnostics = Diagnostics()
    private nonisolated(unsafe) var ledger = SegmentLedger()
    private nonisolated(unsafe) var isRunning = false
    private nonisolated(unsafe) var stream: SCStream?
    private nonisolated(unsafe) var writer: AVAssetWriter?
    private nonisolated(unsafe) var videoInput: AVAssetWriterInput?
    private nonisolated(unsafe) var systemAudioInput: AVAssetWriterInput?
    private nonisolated(unsafe) var micInput: AVAssetWriterInput?
    private nonisolated(unsafe) var writerTempURL: URL?
    private nonisolated(unsafe) var writerSessionStarted = false
    private nonisolated(unsafe) var currentGeometry: DisplayGeometry?
    private nonisolated(unsafe) var currentMediaFilename: String?
    private nonisolated(unsafe) var lastFrameInstant: HostInstant?
    private nonisolated(unsafe) var frameCounterForBlackCheck = 0
    private nonisolated(unsafe) var blackFrameConsecutive = 0
    /// Opaque token for `CGDisplayRegisterReconfigurationCallback`'s
    /// `userInfo`, so the free-function callback can reach back into this
    /// instance without a global. `Unmanaged.passUnretained` — the callback
    /// is unregistered in `stop()`/`deinit` before the session can be freed.
    private nonisolated(unsafe) var reconfigToken: Unmanaged<CaptureSession>?

    // MARK: - Init

    /// `scale` and `displayUUID` are supplied by the caller, exactly
    /// mirroring `CaptureSource.geometry(scale:displayUUID:)`'s own
    /// parameters (Task 7) — this type does not derive them itself, for the
    /// same reason that function does not: deriving a display's UUID/scale
    /// is ambient CoreGraphics/AppKit state this file has no need to own,
    /// and the caller (eventually `capture-permissions`'s successor in
    /// `app-shell`) already has to compute them once to drive the picker.
    ///
    /// `packageURL` is the `.soredemo` package each segment's media is
    /// written into via `ProjectPackageIO.writeSidecar`, so the write-once
    /// refusal applies to every segment this session produces. `epoch` is
    /// the recording's `BootEpoch` (`Minting.bootEpoch()`), supplied once so
    /// every `HostInstant` this session mints shares one epoch — the same
    /// reasoning `SegmentTable.init(segments:)`'s `mixedEpochs` guard exists
    /// to catch if it were ever wrong.
    public init(source: CaptureSource, scale: Double, displayUUID: UUID, packageURL: URL, epoch: BootEpoch) {
        self.source = source
        self.scale = scale
        self.displayUUID = displayUUID
        self.packageURL = packageURL
        self.epoch = epoch
        super.init()
    }

    deinit {
        // No lock here: by the time `deinit` runs there is, by definition,
        // no other reference through which a concurrent access could occur.
        if let reconfigToken {
            CGDisplayRemoveReconfigurationCallback(CaptureSession.reconfigurationCallback,
                                                    reconfigToken.toOpaque())
        }
    }

    // MARK: - Public lifecycle

    /// Opens segment 0. Registers the display-reconfiguration observer
    /// **before** starting capture, per D2-10: unregistered, reconfiguration
    /// is inferred later from frames stopping or sizes not matching, after
    /// the file is already wrong.
    public nonisolated func start() async throws {
        let wasAlreadyRunning = lock.withLock { () -> Bool in
            if isRunning { return true }
            isRunning = true
            return false
        }
        guard !wasAlreadyRunning else { throw SessionError.alreadyRunning }

        registerReconfigurationObserver()
        let geometry = source.geometry(scale: scale, displayUUID: displayUUID)
        try await beginSegment(geometry: geometry)
    }

    /// Finalises the current segment with `.paused` and tears the stream
    /// down. There is no pause in ScreenCaptureKit (D2-9) — this is the
    /// whole mechanism, not a partial one.
    public nonisolated func pause() async throws {
        try await finalizeCurrentSegment(endedBy: .paused)
    }

    /// Opens the next segment, same geometry revision as before pausing —
    /// pausing is a user action, not a display change, so nothing here
    /// re-derives geometry the way `handleReconfiguration` does.
    public nonisolated func resume() async throws {
        let (running, savedGeometry) = lock.withLock { (isRunning, currentGeometry) }
        guard running else { throw SessionError.notRunning }
        let geometry = savedGeometry ?? source.geometry(scale: scale, displayUUID: displayUUID)
        try await beginSegment(geometry: geometry)
    }

    /// Finalises the current segment with `.stopped`, unregisters the
    /// reconfiguration observer, and returns the `SegmentTable` — the
    /// validated, ordered record `SegmentTable.init(segments:)` (Task 4)
    /// throws out of if anything is out of order, overlapping, or spans two
    /// boot epochs.
    @discardableResult
    public nonisolated func stop() async throws -> SegmentTable {
        guard lock.withLock({ isRunning }) else { throw SessionError.notRunning }

        // A stop with no segment open (e.g. called again after a stream
        // failure already finalised the last one) is not an error — it
        // just has nothing left to close.
        if lock.withLock({ ledger.isSegmentOpen }) {
            try await finalizeCurrentSegment(endedBy: .stopped, stopping: true)
        } else {
            unregisterReconfigurationObserver()
            lock.withLock { isRunning = false }
        }

        return try lock.withLock { try ledger.finish() }
    }

    // MARK: - Segment open/close

    /// Shared by `start()`, `resume()`, and reconfiguration handling: mint a
    /// filename, build a fresh `AVAssetWriter` with three inputs, build a
    /// fresh `SCStream` sized to `geometry`, and open the ledger's next
    /// segment. The write-once refusal (`ProjectPackageIO.writeSidecar`)
    /// applies once the segment's bytes are finished — see
    /// `finalizeCurrentSegment` for why it cannot apply here, at open time.
    private nonisolated func beginSegment(geometry: DisplayGeometry) async throws {
        let index = lock.withLock { ledger.closedSegments.count }
        let mediaFilename = "master-\(String(format: "%02d", index)).mov"

        // AVAssetWriter refuses to write to a path that already exists (its
        // own header: "Writing will fail if a file already exists at the
        // specified URL"), so it cannot target `media/<name>` directly —
        // `writeSidecar`'s own write-once check would have to run *after*
        // the writer already created that file, which is too late. Instead
        // the writer targets a scratch path outside the package, and the
        // finished bytes are handed to `writeSidecar` whole once recording
        // of this segment ends — see `finalizeCurrentSegment`. `.mappedIfSafe`
        // there avoids doubling this in RAM.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soredemo-capture-\(Minting.newIdentifier().uuidString).mov")

        let writer = try AVAssetWriter(url: tempURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: geometry.pixelWidth,
            AVVideoHeightKey: geometry.pixelHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // Passthrough (`nil` settings), deliberately, for both audio tracks
        // — not AAC. The master is unprocessed evidence (D2-8); lossy
        // compression is exactly the kind of processing that principle
        // argues against, and passthrough into a QuickTime movie needs no
        // format hint (the header: a hint is only required for a
        // non-QuickTime container). This also sidesteps having to predict
        // the microphone's own native format, which
        // `SCStreamConfiguration.sampleRate`/`.channelCount` do not control
        // (those govern only the *system-audio* stream — confirmed against
        // `SCStream.h`'s wording for each property).
        let systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        systemAudioInput.expectsMediaDataInRealTime = true
        let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        micInput.expectsMediaDataInRealTime = true

        for input in [videoInput, systemAudioInput, micInput] {
            guard writer.canAdd(input) else {
                throw SessionError.writerFailed("AVAssetWriter.canAdd(_:) refused \(input.mediaType.rawValue) input")
            }
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw SessionError.writerFailed(writer.error?.localizedDescription ?? "startWriting() returned false")
        }

        let configuration = SCStreamConfiguration()
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight
        configuration.showsCursor = false                 // Step 0 / D2-8
        configuration.scalesToFit = false                  // D2-13a
        configuration.preservesAspectRatio = true           // D2-13a
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB    // D2-15 — pinned, placeholder gamut choice
        // A floor, not a cadence (F2-4: 9–37 fps observed against 60
        // requested) — presentation times are taken from each sample
        // buffer, never assumed from this number.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let filter = source.filter()
        let scStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try scStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)

        lock.withLock {
            self.stream = scStream
            self.writer = writer
            self.videoInput = videoInput
            self.systemAudioInput = systemAudioInput
            self.micInput = micInput
            self.writerTempURL = tempURL
            self.writerSessionStarted = false
            self.currentGeometry = geometry
            self.currentMediaFilename = mediaFilename
            self.lastFrameInstant = nil
            self.frameCounterForBlackCheck = 0
            self.blackFrameConsecutive = 0
            let openInstant = HostInstant(epoch: epoch, hostTime: Minting.hostNow())
            ledger.openSegment(at: openInstant, revision: geometry.revision, mediaFilename: mediaFilename)
        }

        try await scStream.startCapture()
    }

    /// Stops the current `SCStream`, finishes the current `AVAssetWriter`,
    /// copies its finished bytes into the package through
    /// `ProjectPackageIO.writeSidecar`, and closes the ledger with
    /// `boundary`. `stopping` skips re-registering anything, since `stop()`
    /// is the terminal call.
    private nonisolated func finalizeCurrentSegment(endedBy boundary: SegmentBoundary, stopping: Bool = false) async throws {
        struct Snapshot {
            let scStream: SCStream?
            let writer: AVAssetWriter?
            let tempURL: URL?
            let mediaFilename: String?
            let endInstant: HostInstant
        }
        guard let snapshot = lock.withLock({ () -> Snapshot? in
            guard isRunning, ledger.isSegmentOpen else { return nil }
            let instant = lastFrameInstant ?? HostInstant(epoch: epoch, hostTime: Minting.hostNow())
            return Snapshot(scStream: stream, writer: writer, tempURL: writerTempURL,
                             mediaFilename: currentMediaFilename, endInstant: instant)
        }) else {
            throw SessionError.noSegmentOpen
        }

        if let scStream = snapshot.scStream {
            try? await scStream.stopCapture()
        }
        if let writer = snapshot.writer, writer.status == .writing {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
        }

        if let writer = snapshot.writer, writer.status == .completed,
           let tempURL = snapshot.tempURL, let mediaFilename = snapshot.mediaFilename {
            // `.mappedIfSafe`: the finished file can be large (design doc:
            // "several GB of video"); mapping avoids doubling that in RAM
            // the way `Data(contentsOf:)`'s default eager read would.
            let bytes = try Data(contentsOf: tempURL, options: .mappedIfSafe)
            try ProjectPackageIO.writeSidecar(bytes, named: mediaFilename, into: packageURL)
            try? FileManager.default.removeItem(at: tempURL)
        } else if let tempURL = snapshot.tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }

        lock.withLock {
            ledger.closeSegment(at: snapshot.endInstant, endedBy: boundary)
            self.stream = nil
            self.writer = nil
            self.videoInput = nil
            self.systemAudioInput = nil
            self.micInput = nil
            self.writerTempURL = nil
            self.currentMediaFilename = nil
            if stopping { isRunning = false }
        }

        if stopping {
            unregisterReconfigurationObserver()
        }
    }

    // MARK: - SCStreamOutput

    /// **Deliberately `nonisolated`, not left to `SWIFT_DEFAULT_ACTOR_ISOLATION
    /// = MainActor`.** `SCStreamOutput`/`SCStreamDelegate` are plain ObjC
    /// protocols, not documented to call back on the main thread — this
    /// project's own `CaptureSourcePicker` (Task 7) made the identical call
    /// for the identical reason, and ScreenCaptureKit explicitly delivers
    /// these on the `sampleHandlerQueue` supplied to `addStreamOutput`,
    /// which here is `sampleQueue`, never the main queue.
    public nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                                    of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleScreenSample(sampleBuffer)
        case .audio:
            appendAudio(sampleBuffer, isSystemAudio: true)
        case .microphone:
            appendAudio(sampleBuffer, isSystemAudio: false)
        @unknown default:
            break
        }
    }

    /// A revoked Screen Recording grant does not reach here — F2-4/D2-8's
    /// TCC finding is that it produces **black frames**, not a stream error
    /// (see `checkForBlackFrame`). What does reach here is a genuine stream
    /// failure — the display sleeping in a way ScreenCaptureKit cannot
    /// recover from, the process losing its grant entirely mid-run, etc.
    /// Closed with `.failed`, from a detached `Task`: there is no user
    /// action to wait for, unlike `pause`, and this callback itself must
    /// stay synchronous and non-async, matching the protocol.
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task {
            try? await self.finalizeCurrentSegment(endedBy: .failed(reason: String(describing: error)))
        }
    }

    private nonisolated func handleScreenSample(_ sampleBuffer: CMSampleBuffer) {
        let callbackInstant = Minting.hostNow()

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else { return }

        let statusRaw = (attachments[.status] as? Int) ?? -1
        lock.withLock { _diagnostics.frameStatusCounts[statusRaw, default: 0] += 1 }

        // A callback is not a frame (F2-4: idle was 42–84% of callbacks
        // across four runs) — append only `.complete`.
        guard statusRaw == SCFrameStatus.complete.rawValue else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.timescale > 0 else { return }
        // Integer nanoseconds, not `CMTimeGetSeconds(pts) * 1e9` — `Nanoseconds`
        // is deliberately never a `Double` (its own doc comment), and this is
        // the one place a `CMTime` crosses into that type.
        let ptsNanos = Int64(pts.value) * 1_000_000_000 / Int64(pts.timescale)
        let frameInstant = HostInstant(epoch: epoch, hostTime: Nanoseconds(ptsNanos))
        let latencyNanos = callbackInstant.rawValue - ptsNanos

        recordContentScale(from: attachments)
        recordExtrinsicRects(from: attachments)

        let (shouldCheckBlack, writerRef, videoInputRef, sessionAlreadyStarted) = lock.withLock {
            () -> (Bool, AVAssetWriter?, AVAssetWriterInput?, Bool) in
            _diagnostics.completeFrameCount += 1
            if latencyNanos >= 0 { _diagnostics.ptsToCallbackLatencyNanos.append(latencyNanos) }
            lastFrameInstant = frameInstant
            frameCounterForBlackCheck += 1
            let shouldCheck = frameCounterForBlackCheck % Self.blackFrameCheckEveryNFrames == 0
            return (shouldCheck, writer, videoInput, writerSessionStarted)
        }

        if shouldCheckBlack, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            checkForBlackFrame(pixelBuffer)
        }

        guard let writerRef, writerRef.status == .writing,
              let videoInputRef, videoInputRef.isReadyForMoreMediaData else { return }
        if !sessionAlreadyStarted {
            writerRef.startSession(atSourceTime: pts)
            lock.withLock { writerSessionStarted = true }
        }
        _ = videoInputRef.append(sampleBuffer)
    }

    private nonisolated func appendAudio(_ sampleBuffer: CMSampleBuffer, isSystemAudio: Bool) {
        let (writerRef, inputRef, sessionAlreadyStarted) = lock.withLock {
            () -> (AVAssetWriter?, AVAssetWriterInput?, Bool) in
            (writer, isSystemAudio ? systemAudioInput : micInput, writerSessionStarted)
        }
        guard let writerRef, writerRef.status == .writing,
              let inputRef, inputRef.isReadyForMoreMediaData,
              // Audio arriving before the first complete video frame has
              // opened the writer's session has nowhere valid to land —
              // dropped rather than starting the session off an audio PTS,
              // keeping "the master's session starts at the first video
              // frame" a single, simple rule instead of a race between
              // three streams.
              sessionAlreadyStarted else { return }
        _ = inputRef.append(sampleBuffer)
    }

    // MARK: - `SCStreamFrameInfoContentScale` — D2-13a: recorded, not asserted

    /// **Decision: record, not assert.** `ContentScale != 1` means this
    /// frame was resampled, which is exactly what D2-8 says the master must
    /// never be — so the tempting move is `precondition(scale == 1)`. Two
    /// reasons that would be the wrong instrument here, both from
    /// `AGENTS.md`'s own vocabulary:
    ///
    /// 1. **The failure mode of a false-positive crash is catastrophic and
    ///    irreversible.** A `precondition` mid-recording does not fail this
    ///    frame; it kills the process and discards the segment already
    ///    captured, for a value this task cannot fully characterise across
    ///    every combination of window/display capture, HiDPI displays, and
    ///    the resize edge case D2-13a itself names ("if a window grows past
    ///    the whole display", `scalesToFit = false` resamples it *by
    ///    design*, on a fixed, display-sized buffer). Trapping recording
    ///    over a case the design doc already says can legitimately occur is
    ///    the "measurement with no safe default" rule pointed at itself: a
    ///    crash is not a safer answer than a wrong number when the
    ///    alternative to both is simply recording what happened.
    /// 2. **It matches this task's own black-frame detector's stance,** for
    ///    the same reason: log now, because the threshold for "this is bad
    ///    enough to abort" is not calibrated against a real recording yet
    ///    (D4). A future producer reading `resampledFrameCount` can decide
    ///    the master is unusable; this recorder's job is to make that
    ///    decision possible, not to make it here, mid-capture, with no
    ///    calibration behind it.
    ///
    /// So: every complete frame's `ContentScale` is read, tallied, and its
    /// range tracked in `Diagnostics` — D2-8's "the master is unresampled"
    /// claim becomes a number a caller can check after the fact, per the
    /// design doc's own framing ("checkable per frame ... rather than
    /// assumed"), without recording putting that check ahead of finishing
    /// the recording.
    private nonisolated func recordContentScale(from attachments: [SCStreamFrameInfo: Any]) {
        let scaleValue: Double?
        if let d = attachments[.contentScale] as? Double {
            scaleValue = d
        } else if let n = attachments[.contentScale] as? NSNumber {
            scaleValue = n.doubleValue
        } else {
            scaleValue = nil
        }
        guard let scale = scaleValue else { return }
        lock.withLock {
            if scale != 1 { _diagnostics.resampledFrameCount += 1 }
            _diagnostics.minContentScaleObserved = min(_diagnostics.minContentScaleObserved ?? scale, scale)
            _diagnostics.maxContentScaleObserved = max(_diagnostics.maxContentScaleObserved ?? scale, scale)
        }
    }

    /// `SCStreamFrameInfoContentRect`/`.screenRect` are `CGRect`-valued
    /// (wrapped in `NSValue`, matching `SCStreamFrameInfoDirtyRects`'s
    /// documented shape in the header) — bridged through
    /// `CGGeometryBridge.pointRect(from:)` immediately, never held as
    /// `CGRect` past this function (rule 5). D2-13a: this is the extrinsic
    /// mapping and "must not enter the digest" — kept only as the latest
    /// diagnostic value, never fed into `GeometryRevision` computation
    /// anywhere in this file.
    private nonisolated func recordExtrinsicRects(from attachments: [SCStreamFrameInfo: Any]) {
        if let value = attachments[.contentRect] as? NSValue {
            let point = CGGeometryBridge.pointRect(from: value.rectValue)
            lock.withLock { _diagnostics.lastContentRect = point }
        }
        if let value = attachments[.screenRect] as? NSValue {
            let point = CGGeometryBridge.pointRect(from: value.rectValue)
            lock.withLock { _diagnostics.lastScreenRect = point }
        }
    }

    // MARK: - Step 3: black-frame detection

    /// A revoked Screen Recording grant yields black frames, not an error
    /// (F2-4/TCC section) — a status check at start does not cover this,
    /// because the grant can be revoked *during* a recording. This samples
    /// a small fixed grid's luminance on every Nth complete frame.
    ///
    /// **The threshold is a placeholder and is labelled as one** (see the
    /// three `blackFrame*` constants at the top of this file). A genuinely
    /// black screen exists — a screensaver, a full-screen dark video — so
    /// until this is calibrated against real recordings, **detection only
    /// logs**; it never closes the segment with `.failed` on its own. The
    /// mechanism to do so (`finalizeCurrentSegment(endedBy: .failed(...))`)
    /// exists and is exercised by `stream(_:didStopWithError:)`, so wiring
    /// this detector to it later is a threshold change, not new plumbing.
    private nonisolated func checkForBlackFrame(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else { return }

        // A small fixed grid — 4x4 interior points, never the very edge
        // (which can carry menu-bar/notch chrome at a different luminance
        // than the content). BGRA, 8 bits per channel, matching the pixel
        // format this session configures.
        let buffer = base.assumingMemoryBound(to: UInt8.self)
        var allAtFloor = true
        outer: for row in 1...4 {
            for col in 1...4 {
                let x = min(width - 1, (width * col) / 5)
                let y = min(height - 1, (height * row) / 5)
                let offset = y * bytesPerRow + x * 4
                let b = Double(buffer[offset]) / 255.0
                let g = Double(buffer[offset + 1]) / 255.0
                let r = Double(buffer[offset + 2]) / 255.0
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if luminance > Self.blackFrameLuminanceFloor {
                    allAtFloor = false
                    break outer
                }
            }
        }

        let (consecutive, segmentIndex) = lock.withLock { () -> (Int, Int) in
            blackFrameConsecutive = allAtFloor ? blackFrameConsecutive + 1 : 0
            return (blackFrameConsecutive, ledger.closedSegments.count)
        }

        if consecutive == Self.blackFrameConsecutiveThreshold {
            lock.withLock {
                _diagnostics.blackFrameDetections.append((segmentIndex: segmentIndex, consecutiveChecks: consecutive))
            }
            // Logged, not acted on — see this function's doc comment.
            FileHandle.standardError.write(Data((
                "CaptureSession: possible black-frame condition — \(consecutive) consecutive checks " +
                "at floor luminance \(Self.blackFrameLuminanceFloor), segment \(segmentIndex). " +
                "Threshold is an uncalibrated placeholder; not aborting.\n"
            ).utf8))
        }
    }

    // MARK: - Step 2: display reconfiguration as an observed event

    /// Registered before `startCapture()`, per D2-10: unregistered,
    /// reconfiguration is inferred later from frames stopping or sizes not
    /// matching, after the file is already wrong.
    private nonisolated func registerReconfigurationObserver() {
        let token = Unmanaged.passUnretained(self)
        lock.withLock { reconfigToken = token }
        CGDisplayRegisterReconfigurationCallback(CaptureSession.reconfigurationCallback, token.toOpaque())
    }

    private nonisolated func unregisterReconfigurationObserver() {
        let token = lock.withLock { () -> Unmanaged<CaptureSession>? in
            let t = reconfigToken
            reconfigToken = nil
            return t
        }
        if let token {
            CGDisplayRemoveReconfigurationCallback(CaptureSession.reconfigurationCallback, token.toOpaque())
        }
    }

    /// A free function, not a closure over `self` — `CGDisplayRegisterReconfigurationCallback`
    /// takes a plain C function pointer, which cannot capture context;
    /// `userInfo` is how `self` crosses that boundary (mirrors the spike's
    /// own `reconfigCallback`, except this one recovers a specific instance
    /// instead of writing to a global). **`nonisolated`, deliberately** —
    /// left to this file's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// default, this `static let` becomes `@MainActor`-isolated and neither
    /// `deinit` (which cannot be actor-isolated) nor a plain C callback
    /// context can reference it; caught by `swiftc`, not by inspection.
    private nonisolated static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        // `.beginConfigurationFlag` fires paired with the real change —
        // count only the completed one, matching the spike's own comment.
        guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
        let session = Unmanaged<CaptureSession>.fromOpaque(userInfo).takeUnretainedValue()
        Task { await session.handleReconfiguration(of: displayID) }
    }

    /// Only `.display` sources participate in reconfiguration-triggered
    /// segment splitting. `.window` sources deliberately do not — D2-13a: a
    /// window's buffer is fixed for the whole segment and its resize is
    /// carried per-frame as an *extrinsic* mapping (`ContentRect`), not as a
    /// new `GeometryRevision`; "One revision per segment. No
    /// `windowResized` case on `SegmentBoundary`. Nothing new." A window's
    /// *owning display* reconfiguring is a real, separate gap this
    /// deliberately leaves open — see the task report.
    private nonisolated func handleReconfiguration(of displayID: CGDirectDisplayID) async {
        guard case .display(let capturedDisplay) = source, capturedDisplay.displayID == displayID else { return }
        guard lock.withLock({ ledger.isSegmentOpen }) else { return }

        guard let content = try? await SCShareableContent.current,
              let freshDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            // Cannot re-derive geometry without a fresh `SCDisplay` — logged
            // rather than silently continuing on stale dimensions, which
            // would be exactly the "inferred after the file is already
            // wrong" failure D2-10 registers this callback to avoid.
            FileHandle.standardError.write(Data((
                "CaptureSession: display \(displayID) reconfigured but SCShareableContent.current " +
                "did not return it; segment NOT split — geometry may now be stale.\n"
            ).utf8))
            return
        }

        let newSource = CaptureSource.display(freshDisplay)
        let newGeometry = newSource.geometry(scale: scale, displayUUID: displayUUID)

        lock.withLock { _diagnostics.displayReconfigurationsHandled += 1 }

        try? await finalizeCurrentSegment(endedBy: .displayReconfigured(newRevision: newGeometry.revision))
        try? await beginSegment(geometry: newGeometry)
    }
}

// MARK: - Segment lifecycle bookkeeping (Task 8's "yours" half)

/// Pure segment-lifecycle bookkeeping: mint an index, open a segment, close
/// it with a `HostRange` and a `SegmentBoundary`, and hand the accumulated
/// list to `SegmentTable.init(segments:)` (Task 4) — which throws — when
/// asked to `finish()`. No `ScreenCaptureKit`, no `AVFoundation`, no
/// permission, no picker: this is the piece the task brief calls "segment
/// lifecycle against a fake frame source", and it is tested that way in
/// `scripts/cross-boundary-digest-probe.swift` — a fake frame source there
/// is nothing more than a sequence of synthetic `HostInstant`s and
/// `SegmentBoundary`s fed straight to this type's two mutating methods.
///
/// **`precondition`, not `throw`, on `openSegment`/`closeSegment` misuse.**
/// Calling `closeSegment` with nothing open, or `openSegment` while a
/// segment is already open, is `CaptureSession`'s own state machine calling
/// this type incorrectly — mis-plumbed state, not a runtime condition to
/// recover from, the same stance this project takes on `HostInstant.<`
/// comparing across boot epochs. `SegmentTable.init(segments:)`'s own
/// `throw`s (`outOfOrder`, `overlapping`, `mixedEpochs`) are the boundary
/// where untrusted-shaped input (two segments that individually look fine
/// but disagree with each other) gets a recoverable error instead — this
/// type does not duplicate that validation, it defers to it in `finish()`.
struct SegmentLedger {
    private(set) var closedSegments: [MasterSegment] = []
    private var open: (start: HostInstant, revision: GeometryRevision, mediaFilename: String)?

    /// `nonisolated` on every member of this type — unannotated, this
    /// struct's methods are implicitly `@MainActor` under this target's
    /// default isolation, and `CaptureSession` (this file) must call them
    /// from inside its `nonisolated` `SCStreamOutput` callbacks, which
    /// cannot be `async`. Verified by compiling this file: `swiftc`
    /// rejected `ledger.openSegment(...)` called from `beginSegment` (itself
    /// `nonisolated` for the same reason) with "call to main actor-isolated
    /// instance method ... in a synchronous nonisolated context" — the same
    /// shape as `Minting.swift`'s and `CGGeometryBridge.swift`'s own fixes
    /// in this task, applied one level down to a plain `struct` rather than
    /// an `enum` of static functions. This type touches no ambient state at
    /// all — every value it holds is a parameter its caller supplied — so
    /// `nonisolated` matches what was already true of the implementation.
    nonisolated var isSegmentOpen: Bool { open != nil }

    nonisolated mutating func openSegment(at start: HostInstant, revision: GeometryRevision, mediaFilename: String) {
        precondition(open == nil,
                     "SegmentLedger.openSegment called while segment \(closedSegments.count) is already open")
        open = (start, revision, mediaFilename)
    }

    /// `end` must share `open`'s start's boot epoch. Silently computing a
    /// duration from two instants on different clocks would be exactly
    /// `AGENTS.md`'s "measurement with no safe default" — a plausible,
    /// in-range `Nanoseconds` value for a subtraction that never should have
    /// happened. `HostInstant.<` already traps on this same mismatch for
    /// ordering; this is the identical stance applied to duration.
    @discardableResult
    nonisolated mutating func closeSegment(at end: HostInstant, endedBy boundary: SegmentBoundary) -> MasterSegment {
        guard let openSegment = open else {
            preconditionFailure("SegmentLedger.closeSegment called with no segment open")
        }
        precondition(end.epoch == openSegment.start.epoch,
                     "SegmentLedger.closeSegment: end instant's boot epoch does not match the open " +
                     "segment's start — mis-plumbed state, not a duration to compute")
        let range = HostRange(epoch: openSegment.start.epoch,
                               start: openSegment.start.hostTime,
                               duration: end.hostTime - openSegment.start.hostTime)
        let segment = MasterSegment(index: closedSegments.count, mediaFilename: openSegment.mediaFilename,
                                     hostRange: range, revision: openSegment.revision, endedBy: boundary)
        closedSegments.append(segment)
        open = nil
        return segment
    }

    /// Traps if a segment is still open — `stop()` must close it first. A
    /// table silently missing its last segment's `endedBy` is the "gap
    /// indistinguishable from a crash" this project's rules keep re-deriving
    /// — not a value this method should quietly produce by leaving the open
    /// segment out.
    nonisolated func finish() throws -> SegmentTable {
        precondition(open == nil, "SegmentLedger.finish() called with a segment still open — close it first")
        return try SegmentTable(segments: closedSegments)
    }
}
