// `@unsafe` because `@preconcurrency` suppresses the concurrency checking that would
// otherwise catch a data race across this import — what `.strictMemorySafety()` asks be
// named, and never measured while this file was in the app target. Safe in the sense the
// mark asks for: every ScreenCaptureKit value here is confined to the stream's own
// delivery queue or published once under `lock` before any callback can see it.
@unsafe @preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Geometry
import Project
import Timeline

/// Takes three ScreenCaptureKit streams (screen, system audio, microphone) and
/// writes them to a `MasterSegment` via three `AVAssetWriterInput`s.
/// `SCRecordingOutput` is unusable: it mixes the microphone into the
/// system-audio track, and `mixesAudioWithMicrophone` is macOS 27.0+.
///
/// ScreenCaptureKit has no pause/resume, so `pause()` finalises the current
/// segment and tears the stream down while `resume()` builds a new one; display
/// reconfiguration and stream failure use the same mechanism.
/// `showsCursor = false` — the compositor draws the cursor later from the
/// pointer track. `colorSpaceName` is pinned to sRGB (a placeholder choice);
/// unset, it follows the display and the master's colour meaning becomes
/// machine-dependent.
///
/// Locking: every mutable property is touched only inside `lock.withLock { … }`
/// — raw `lock()`/`unlock()` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — and nothing
/// awaits while holding the lock.
///
/// Where a finished master segment's bytes go. A protocol so `CaptureSession`
/// cannot reach `ProjectPackageIO.writeSidecar` directly, which would write into
/// `media/` with no manifest reference and be deleted as an orphan by the next
/// `compactMedia()`. `@MainActor` on the requirement rather than the protocol:
/// the shipping conformer is `NSDocument`-derived while `finalizeCurrentSegment`
/// reaches it from a `nonisolated async` context.
public protocol MediaSink: Sendable {
    @MainActor func acceptMedia(_ data: Data, named name: String) throws

    /// Where `CaptureSession` opens an `ObservationWriter` beside the media,
    /// following the `media/master-NN.mov` ↔ `observations/segment-NN.jsonl`
    /// pairing. `nil` when there is no package yet (an unsaved document): no
    /// package means no observation log and no media for that segment.
    @MainActor var packageURL: URL? { get }
}

/// `@safe`, not `@unsafe` — the compiler offers both and they say opposite things about
/// callers. The unsafe storage is `reconfigToken: Unmanaged<CaptureSession>?`, and it is
/// ENCAPSULATED: the token is registered in `start()`, unregistered in `stop()`/`deinit`
/// before the session can be freed, and never handed out. `@unsafe` would say this type is
/// unsafe to USE, which would push a mark onto every caller — including `ContentView`,
/// which has no way to misuse a token it cannot reach. Surfaced by Phase 3A-3: the app
/// target never applied `.strictMemorySafety()` to this file.
@safe
public final class CaptureSession: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    // MARK: - Configuration knobs held for the life of the session

    private let source: CaptureSource
    private let scale: Double
    private let displayUUID: UUID
    private let mediaSink: any MediaSink
    private let epoch: BootEpoch
    /// Passed through to `InputObserver` — see its doc for why this is a closure.
    private let pointerShapeReader: @Sendable () -> PointerShape?

    /// Every Nth complete video frame is luminance-sampled for the black-frame
    /// detector. Uncalibrated placeholder. `nonisolated` on all three constants
    /// below because `checkForBlackFrame` reads them from the `SCStreamOutput`
    /// callback, and an unannotated `static let` is implicitly `@MainActor` here.
    private nonisolated static let blackFrameCheckEveryNFrames = 30
    /// Consecutive *checks* (not frames) with every grid sample at floor before
    /// the detector logs. Uncalibrated placeholder.
    private nonisolated static let blackFrameConsecutiveThreshold = 10
    /// "At floor" for a BGRA byte, normalised 0...1. Uncalibrated placeholder.
    private nonisolated static let blackFrameLuminanceFloor = 0.02

    // MARK: - Public result types

    public enum SessionError: Error, Equatable {
        case alreadyRunning
        case notRunning
        case noSegmentOpen
        case writerFailed(String)
        case streamFailed(String)
    }

    /// What this session has observed. Not persisted by this type; `stop()`'s
    /// caller reads it after the fact.
    public struct Diagnostics: Sendable {
        /// Keyed by `SCFrameStatus.rawValue` — 0 complete, 1 idle, 2 blank,
        /// 3 suspended, 4 started, 5 stopped.
        public internal(set) var frameStatusCounts: [Int: Int] = [:]
        public internal(set) var completeFrameCount = 0
        /// Frames whose `SCStreamFrameInfoContentScale` could be read at all.
        /// A caller must check this is `> 0` before trusting
        /// `resampledFrameCount` or the min/max fields below, which are
        /// vacuously clean at zero.
        public internal(set) var contentScaleCheckedCount = 0
        /// Frames whose `SCStreamFrameInfoContentScale` was not 1, i.e. frames
        /// ScreenCaptureKit resampled.
        public internal(set) var resampledFrameCount = 0
        /// Resampled frames actually **written to the master**, as opposed to
        /// merely delivered: frames delivered during a display reconfiguration
        /// are counted in `resampledFrameCount` but deliberately dropped.
        public internal(set) var appendedResampledFrameCount = 0
        public internal(set) var minContentScaleObserved: Double?
        public internal(set) var maxContentScaleObserved: Double?
        /// The most recently observed `ContentRect`/`ScreenRect`, bridged to
        /// `PointRect` on extraction (never held as `CGRect` — rule 5). These
        /// carry the extrinsic mapping and must not enter the digest.
        public internal(set) var lastContentRect: PointRect?
        public internal(set) var lastScreenRect: PointRect?
        /// Boundaries this session actually closed with `.displayReconfigured`,
        /// not every callback the OS delivered.
        public internal(set) var displayReconfigurationsHandled = 0
        /// One entry per time the black-frame detector's placeholder threshold
        /// was reached. Logged only; never causes a `.failed` boundary.
        public internal(set) var blackFrameDetections: [(segmentIndex: Int, consecutiveChecks: Int)] = []
        /// PTS → callback latency, nanoseconds, one entry per complete video frame.
        public internal(set) var ptsToCallbackLatencyNanos: [Int64] = []
        /// Complete frames dropped because their presentation timestamp could
        /// not be expressed as `Nanoseconds` (non-positive timescale, or too
        /// large for `Int64` nanoseconds). Counted separately from
        /// `completeFrameCount`; non-zero means the master is missing frames
        /// the OS did deliver. Expected to stay at zero — `SCStream` uses host
        /// time at timescale 1e9, which is always convertible.
        public internal(set) var unconvertiblePresentationTimeCount = 0

        /// A segment whose media never reached the package. Non-empty means at
        /// least one `SegmentTable.mediaFilename` has no file behind it, which
        /// the table itself cannot express.
        public struct DiscardedSegment: Sendable {
            public let mediaFilename: String
            public let writerStatus: String
            /// `AVAssetWriter.error`, stringified at the point of failure — the
            /// writer is released immediately afterwards.
            public let writerError: String
            /// The scratch file, deliberately **not** deleted: these are the
            /// captured bytes, recoverable until the OS reclaims the temp dir.
            public let retainedScratchPath: String
        }
        public internal(set) var discardedSegments: [DiscardedSegment] = []

        /// Frames `AVAssetWriterInput.append(_:)` **accepted**, as distinct from
        /// `completeFrameCount`, which counts frames that arrived. Separate
        /// counts because a run in which every append failed would otherwise be
        /// indistinguishable from a perfect one.
        public internal(set) var appendedVideoFrameCount = 0
        public internal(set) var appendedAudioSampleCount = 0
        /// Appends that returned `false`, by media type.
        public internal(set) var failedVideoAppendCount = 0
        public internal(set) var failedAudioAppendCount = 0
        /// The writer's status and error at the **first** append that returned
        /// `false`. `AVAssetWriter` latches the first failure and rejects
        /// everything afterwards, so the last error describes a consequence.
        public internal(set) var firstAppendFailure: String?

        /// `ObservationWriter.append`/`.close` calls that threw, across every
        /// record kind and segment. `.logIsClosed` is the one case that can
        /// legitimately fire, which is why `finalizeCurrentSegment` waits on
        /// `axObserver.waitForQueuedClicks()` before closing.
        public internal(set) var observationAppendFailures = 0
        /// The first observation append/close failure, for the same reason
        /// `firstAppendFailure` captures the first rather than the last.
        public internal(set) var firstObservationAppendFailure: String?

        /// Observations `appendObservation` found with `writer == nil` while a
        /// real segment was actively closing (`finalizingCurrentSegment ==
        /// true`). A genuine loss: the record was never written anywhere. The
        /// window spans `observationWriter = nil` through
        /// `waitForQueuedClicks()` and `close(...)`, at every segment boundary,
        /// and the event tap keeps running throughout.
        public internal(set) var observationsDroppedAfterSegmentClose = 0

        /// Observations `appendObservation` found with `writer == nil` while no
        /// segment was open at all (`finalizingCurrentSegment == false`).
        ///
        /// A record belongs to a segment if and only if its `instant` falls
        /// inside that segment's `hostRange`; attribution is by time, never by
        /// which property happened to be `nil`. Every case reaching this counter
        /// has an `instant` outside every `hostRange`: before the first segment
        /// opens, between `pause()` and `resume()`, across a reconfiguration's
        /// close/reopen gap, and between `stop()`'s finalize and the tap
        /// teardown. Not a defect count — a long pause with an active mouse can
        /// dominate it legitimately.
        ///
        /// This holds only because `beginSegment` sets `observationWriter` and
        /// computes `openInstant` in one `lock.withLock` block, with
        /// `startCapture()` strictly after it; changing that ordering invalidates
        /// this counter's meaning.
        public internal(set) var observationsOutsideAnOpenSegment = 0

        /// The layout of the first audio buffer each source delivered.
        public internal(set) var systemAudioLayout: String?
        public internal(set) var microphoneLayout: String?

        /// The same conservation law as the video path, per audio track — the
        /// two sources have different layouts and sample rates, so a summed
        /// total cannot say which one lost buffers. `delivered` is incremented
        /// at the top of `appendAudio`, before any filter.
        public struct AudioTrackAccounting: Sendable {
            public internal(set) var delivered = 0
            public internal(set) var appended = 0
            public internal(set) var refused = 0
            public internal(set) var skippedWriterNotWriting = 0
            public internal(set) var skippedInputNotReady = 0
            /// Buffers that arrived before the first complete video frame
            /// opened the writer's session. Normal at the head of a
            /// recording; a large value means video never started.
            public internal(set) var skippedSessionNotStarted = 0
            /// Buffers `AudioInterleave` could not re-lay-out.
            public internal(set) var uninterleavable = 0

            /// No legitimate violation. Every delivered buffer leaves
            /// `appendAudio` by exactly one of the six paths below.
            public var balances: Bool {
                delivered == appended + refused + skippedWriterNotWriting
                    + skippedInputNotReady + skippedSessionNotStarted + uninterleavable
            }
            public var accounting: String {
                "delivered \(delivered) = appended \(appended) + refused \(refused)"
                    + " + writer-not-writing \(skippedWriterNotWriting)"
                    + " + input-not-ready \(skippedInputNotReady)"
                    + " + session-not-started \(skippedSessionNotStarted)"
                    + " + uninterleavable \(uninterleavable)"
                    + "  → \(balances ? "balances" : "DOES NOT BALANCE")"
            }
            /// Loudest RMS seen on this track, 0…1, or `nil` if no buffer was
            /// readable as interleaved Float32. The counts all balance over
            /// digital silence, so this is the only field distinguishing
            /// "nothing was lost" from "there was nothing".
            public internal(set) var peakRMS: Double?

            /// A track that was delivered buffers and wrote none of them — the
            /// state that produces a file with one audio track where two were
            /// expected.
            public var deliveredButWroteNothing: Bool { delivered > 0 && appended == 0 }
        }
        public internal(set) var systemAudioAccounting = AudioTrackAccounting()
        public internal(set) var microphoneAccounting = AudioTrackAccounting()

        /// Frames whose rect attachments could not be decoded at all. Non-zero
        /// means `lastContentRect`/`lastScreenRect` are stale for a reason
        /// inside this process, not because ScreenCaptureKit withheld them.
        public internal(set) var unreadableContentRectCount = 0
        public internal(set) var unreadableScreenRectCount = 0

        /// The result of `CGDisplayRegisterReconfigurationCallback`. Anything
        /// other than `.success` means segment splitting cannot happen at all.
        public internal(set) var reconfigurationObserverRegistration: CGError?

        /// The values handed to `SCStreamConfiguration`, one entry per
        /// `beginSegment`, in order, recorded where they are set.
        public struct SegmentConfiguration: Sendable {
            public let bufferWidth: Int
            public let bufferHeight: Int
            public let destination: PixelRect
            public let scale: Double
            /// `ContentScale` observed while this segment was the open one —
            /// which a session-wide min/max cannot attribute.
            public internal(set) var contentScaleMin: Double?
            public internal(set) var contentScaleMax: Double?
            public internal(set) var framesChecked = 0
            public internal(set) var framesResampled = 0
        }
        public internal(set) var segmentConfigurations: [SegmentConfiguration] = []

        /// The `destinationRect` this session configured, recorded at the moment
        /// it was set — what was *asked for*, against `lastContentRect`'s what
        /// was *delivered*. Recomputing it at check time would compare a fresh
        /// computation against its own inputs.
        public internal(set) var configuredDestinationRect: PixelRect?

        /// Complete frames the video path skipped without appending, by reason.
        /// Skipping is legitimate (backpressure), but a skip no counter names is
        /// indistinguishable from a frame that never arrived.
        public internal(set) var skippedWriterNotWritingCount = 0
        public internal(set) var skippedInputNotReadyCount = 0
        /// Frames dropped between a display-reconfiguration callback and the new
        /// segment opening; the alternative is writing resampled frames into the
        /// master.
        public internal(set) var skippedAwaitingReconfigurationCount = 0

        /// A conservation law: every complete video frame leaves the handler
        /// exactly one way, so the counts must sum to `completeFrameCount` on
        /// every run, with no tolerance. It is a sum rather than
        /// `completeFrameCount == appendedVideoFrameCount` because a real-time
        /// input under backpressure legitimately refuses frames.
        public var everyCompleteFrameIsAccountedFor: Bool {
            completeFrameCount == appendedVideoFrameCount
                + failedVideoAppendCount
                + skippedWriterNotWritingCount
                + skippedInputNotReadyCount
                + skippedAwaitingReconfigurationCount
                + unconvertiblePresentationTimeCount
        }

        /// The same law, as the numbers, for a report a human reads.
        public var frameAccounting: String {
            "complete \(completeFrameCount) = appended \(appendedVideoFrameCount)"
                + " + refused \(failedVideoAppendCount)"
                + " + writer-not-writing \(skippedWriterNotWritingCount)"
                + " + input-not-ready \(skippedInputNotReadyCount)"
                + " + awaiting-reconfiguration \(skippedAwaitingReconfigurationCount)"
                + " + pts-unconvertible \(unconvertiblePresentationTimeCount)"
                + "  → \(everyCompleteFrameIsAccountedFor ? "balances" : "DOES NOT BALANCE")"
        }
    }

    public nonisolated var diagnostics: Diagnostics { lock.withLock { unsafe _diagnostics } }

    // MARK: - Mutable session state, all behind `lock`
    //
    // `nonisolated(unsafe)` on every stored property below: unannotated they
    // are implicitly `@MainActor` under this target's default isolation, and
    // `handleScreenSample`/`appendAudio` touch them synchronously from the
    // `SCStreamOutput` callback. Nothing here is protected by actor isolation;
    // everything is protected by `lock`.

    private let lock = NSLock()
    private let sampleQueue = DispatchQueue(label: "video.soredemo.CaptureSession.samples")

    // MARK: - state guarded by `lock`
    //
    // **Every access to the `nonisolated(unsafe)` properties below is marked `unsafe` at
    // its own expression, and one argument covers all 137 of them**: each is read and
    // written only inside a `lock.withLock` block, or before the instance is handed to
    // `SCStream`. `nonisolated(unsafe)` is what lets an `@unchecked Sendable` class hold
    // mutable state under a lock; the compiler cannot see the lock, so the marks state
    // what it cannot check. Repeating that sentence 137 times would say nothing extra —
    // the discipline is a property of the type, not of any one line.
    //
    // Surfaced by Phase 3A-3: `.strictMemorySafety()` applies to package targets and this
    // file was in the app target until then, so none of these had ever been measured.
    private nonisolated(unsafe) var _diagnostics = Diagnostics()
    private nonisolated(unsafe) var ledger = SegmentLedger()
    private nonisolated(unsafe) var isRunning = false
    private nonisolated(unsafe) var stream: SCStream?
    /// The master file, behind `MasterWriting` rather than a bare
    /// `AVAssetWriter`: everything it holds is deprecated at macOS 27.0, so the
    /// seam is where that migration will land. See `MasterWriter.swift`.
    private nonisolated(unsafe) var master: (any MasterWriting)?
    private nonisolated(unsafe) var writerTempURL: URL?
    private nonisolated(unsafe) var writerSessionStarted = false
    private nonisolated(unsafe) var currentGeometry: DisplayGeometry?
    /// Held alongside `currentGeometry` and always set with it, so `resume()`
    /// cannot restore one and re-derive the other.
    private nonisolated(unsafe) var currentDestination: PixelRect?
    /// Set synchronously by `reconfigurationCallback`, cleared when the next
    /// segment opens. While true, complete frames are counted and dropped
    /// rather than appended.
    private nonisolated(unsafe) var suspendAppendsForReconfiguration = false
    private nonisolated(unsafe) var currentMediaFilename: String?
    private nonisolated(unsafe) var lastFrameInstant: HostInstant?
    private nonisolated(unsafe) var frameCounterForBlackCheck = 0
    private nonisolated(unsafe) var blackFrameConsecutive = 0
    /// Opaque token for `CGDisplayRegisterReconfigurationCallback`'s `userInfo`,
    /// so the free-function callback can reach this instance without a global.
    /// `Unmanaged.passUnretained` is safe because the callback is unregistered
    /// in `stop()`/`deinit` before the session can be freed.
    private nonisolated(unsafe) var reconfigToken: Unmanaged<CaptureSession>?

    // MARK: - Observation
    //
    // One `InputObserver` and one `AXObserver` for the life of the SESSION, not
    // one per segment: both are expensive and permission-gated, and an AX chain
    // may outlive the segment boundary its click happened in. Only
    // `observationWriter` rotates per segment.

    private nonisolated(unsafe) var inputObserver: InputObserver?
    private nonisolated(unsafe) var axObserver: AXObserver?
    /// What `setUpObservation()` found when starting the tap and asking for
    /// Accessibility. Read once for the whole session, not per segment.
    private nonisolated(unsafe) var observationBlindness: [ObservationBlindness] = []
    private nonisolated(unsafe) var observationWriter: ObservationWriter?
    /// `InputObserver`/`AXObserver` diagnostics as of the current segment's
    /// open. Both are session-cumulative, so a segment's `GapWatch` rows are
    /// this snapshot subtracted from the diagnostics read at close.
    private nonisolated(unsafe) var inputDiagnosticsAtSegmentStart = InputObserver.Diagnostics()
    private nonisolated(unsafe) var axDiagnosticsAtSegmentStart = AXObserver.Diagnostics()
    private nonisolated(unsafe) var frameStatusCountsAtSegmentStart: [Int: Int] = [:]
    /// Sum of every `SecureInputInterval.interval.duration` routed to the
    /// current segment's writer, reset at each `beginSegment`. Not derivable by
    /// subtraction from `InputObserver.Diagnostics`, which counts intervals but
    /// never their total width.
    private nonisolated(unsafe) var secureInputSuppressedNanosAtCurrentSegment: Int64 = 0
    /// `true` from the instant `finalizeCurrentSegment` nils `observationWriter`
    /// until it finishes closing it. `appendObservation` reads it to choose
    /// between `observationsDroppedAfterSegmentClose` (`true`) and
    /// `observationsOutsideAnOpenSegment` (`false`).
    private nonisolated(unsafe) var finalizingCurrentSegment = false

    // MARK: - Init

    /// `scale` and `displayUUID` are supplied by the caller rather than derived
    /// here, mirroring `CaptureSource.geometry(scale:displayUUID:)`.
    ///
    /// `mediaSink` is where each finished segment's bytes go, and it is
    /// non-optional: media must go through `ProjectDocument.addMedia(_:named:)`,
    /// which records the manifest reference and marks the document dirty.
    /// `ProjectPackageIO.writeSidecar` alone leaves an orphan the next
    /// `compactMedia()` deletes.
    ///
    /// `epoch` is supplied once so every `HostInstant` this session mints shares
    /// one `BootEpoch`.
    public init(source: CaptureSource, scale: Double, displayUUID: UUID,
                mediaSink: any MediaSink, epoch: BootEpoch,
                pointerShapeReader: @escaping @Sendable () -> PointerShape? = { nil }) {
        self.source = source
        self.scale = scale
        self.displayUUID = displayUUID
        self.mediaSink = mediaSink
        self.epoch = epoch
        self.pointerShapeReader = pointerShapeReader
        super.init()
    }

    deinit {
        // No lock: at `deinit` no other reference can concurrently access this.
        if let reconfigToken = unsafe reconfigToken {
            unsafe CGDisplayRemoveReconfigurationCallback(CaptureSession.reconfigurationCallback,
                                                    reconfigToken.toOpaque())
        }
    }

    // MARK: - Public lifecycle

    /// Opens segment 0. Registers the display-reconfiguration observer **before**
    /// starting capture; otherwise a reconfiguration is only inferred later,
    /// after the file is already wrong.
    public nonisolated func start() async throws {
        let wasAlreadyRunning = lock.withLock { () -> Bool in
            if unsafe isRunning { return true }
            unsafe isRunning = true
            return false
        }
        guard !wasAlreadyRunning else { throw SessionError.alreadyRunning }

        registerReconfigurationObserver()
        // Once per SESSION, not once per segment.
        await setUpObservation()
        try await beginSegment(geometry: source.geometry(scale: scale, displayUUID: displayUUID),
                                destination: source.destinationRect(scale: scale))
    }

    /// Constructs this session's `InputObserver`/`AXObserver`, asks for
    /// Accessibility, starts the tap, and records what happened as
    /// `observationBlindness`.
    ///
    /// `@MainActor`, unlike most of this file, because
    /// `InputObserver.start(onObservation:)` is MainActor-isolated (it touches
    /// `CFRunLoopGetMain()`) and `CapturePermissions.requestAccessibilityAccess()`
    /// reads process state. Nothing here pre-checks Input Monitoring;
    /// `CaptureError.inputMonitoringUnavailable` is caught as a normal outcome.
    @MainActor
    private func setUpObservation() async {
        // Asked once, before the AX walk's first use; this return value is the
        // session's whole accessibility reading. `CapturePermissions.status(of:
        // .accessibility)` is deliberately not read here too — a second reader
        // would be a second policy about what the grant means.
        let accessibilityGranted = CapturePermissions.requestAccessibilityAccess()

        // The pointer normalises against WHAT IS RECORDED; the AX walk still routes through
        // the whole arrangement, because an accessibility hit-test is a global-space
        // question and a window's chrome can be answered by an element outside its rect.
        let viewport = source.viewport(scale: scale, displayUUID: displayUUID)
        let arrangement = InputObserver.currentArrangement()
        let input = InputObserver(viewport: viewport, epoch: epoch,
                                  pointerShapeReader: pointerShapeReader)
        let ax = AXObserver(arrangement: arrangement, epoch: epoch)

        var blindness: [ObservationBlindness] = []
        if !accessibilityGranted { blindness.append(.accessibilityUnavailable) }

        do {
            try input.start(onObservation: { [weak self] observation in
                self?.routeInputObservation(observation)
            })
        } catch let error as CaptureError {
            // NOT "no events happened" — see `CaptureError`'s own cases.
            if let mapped = error.blindness { blindness.append(mapped) }
        } catch {
            // `InputObserver.start` only throws `CaptureError`; an unrecognised
            // error is not absorbed into a blindness case that would misname it.
            FileHandle.standardError.write(Data((
                "CaptureSession: InputObserver.start threw an unexpected error: \(error)\n"
            ).utf8))
        }

        lock.withLock {
            unsafe self.inputObserver = input
            unsafe self.axObserver = ax
            unsafe self.observationBlindness = blindness
        }
    }

    /// Finalises the current segment with `.paused` and tears the stream down.
    /// ScreenCaptureKit has no pause, so this is the whole mechanism.
    public nonisolated func pause() async throws {
        try await finalizeCurrentSegment(endedBy: .paused)
    }

    /// Opens the next segment with the same geometry revision as before pausing;
    /// pausing is a user action, not a display change, so geometry is not
    /// re-derived the way `handleReconfiguration` does.
    public nonisolated func resume() async throws {
        let (running, savedGeometry, savedDestination) =
            lock.withLock { unsafe (isRunning, currentGeometry, currentDestination) }
        guard running else { throw SessionError.notRunning }
        // Both saved values, or both re-derived — never one of each.
        if let savedGeometry, let savedDestination {
            try await beginSegment(geometry: savedGeometry, destination: savedDestination)
        } else {
            try await beginSegment(geometry: source.geometry(scale: scale, displayUUID: displayUUID),
                                    destination: source.destinationRect(scale: scale))
        }
    }

    /// The result of stopping a recording. Not a bare `SegmentTable`, because a
    /// table names a `mediaFilename` per segment but cannot say whether a file
    /// exists behind that name; a caller must state which case they are in
    /// before reaching the table.
    public enum Outcome: Sendable {
        /// Every segment's media is in the package.
        case complete(SegmentTable)
        /// At least one segment's media never reached the package. The
        /// discarded entries carry the writer's error and the retained
        /// scratch path for each.
        case incomplete(SegmentTable, discarded: [Diagnostics.DiscardedSegment])
    }

    /// Finalises the current segment with `.stopped`, unregisters the
    /// reconfiguration observer, and returns an `Outcome` carrying the validated
    /// `SegmentTable`. Deliberately not `@discardableResult`: the record of what
    /// was just recorded is the only interesting output.
    public nonisolated func stop() async throws -> Outcome {
        guard lock.withLock({ unsafe isRunning }) else { throw SessionError.notRunning }

        // A stop with no segment open (e.g. after a stream failure already
        // finalised the last one) is not an error.
        if lock.withLock({ unsafe ledger.isSegmentOpen }) {
            try await finalizeCurrentSegment(endedBy: .stopped, stopping: true)
        } else {
            unregisterReconfigurationObserver()
            lock.withLock { unsafe isRunning = false }
        }

        // Matching `stop()` for the single `InputObserver.start(onObservation:)`
        // call in `setUpObservation()`; tears the tap down for the session.
        let observerToStop = lock.withLock { () -> InputObserver? in
            let observer = unsafe inputObserver
            unsafe inputObserver = nil
            return observer
        }
        if let observerToStop {
            await MainActor.run { observerToStop.stop() }
        }

        let table = try lock.withLock { unsafe try ledger.finish() }
        let discarded = lock.withLock { unsafe _diagnostics.discardedSegments }
        return discarded.isEmpty ? .complete(table) : .incomplete(table, discarded: discarded)
    }

    // MARK: - Segment open/close

    /// Shared by `start()`, `resume()`, and reconfiguration handling: mint a
    /// filename, build a fresh `AVAssetWriter` with three inputs, build a fresh
    /// `SCStream` sized to `geometry`, and open the ledger's next segment.
    ///
    /// `geometry` and `destination` must come from one `CaptureSource`. Derived
    /// separately they can disagree across a display reconfiguration — buffer
    /// following the new display while `destinationRect` still asks for the old
    /// one — and ScreenCaptureKit then resamples every frame of the new segment.
    private nonisolated func beginSegment(geometry: DisplayGeometry, destination: PixelRect) async throws {
        let index = lock.withLock { unsafe ledger.closedSegments.count }
        let mediaFilename = unsafe "master-\(String(format: "%02d", index)).mov"

        // AVAssetWriter fails if a file already exists at its output URL, so it
        // cannot target `media/<name>` directly. It writes to a scratch path
        // outside the package and the finished bytes are handed over whole in
        // `finalizeCurrentSegment`.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soredemo-capture-\(Minting.newIdentifier().uuidString).mov")

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
        // Passthrough (`nil` settings) for both audio tracks, not AAC: the master
        // is unprocessed evidence, QuickTime needs no format hint for
        // passthrough, and the microphone's native format cannot be predicted
        // (`SCStreamConfiguration.sampleRate`/`.channelCount` govern only the
        // system-audio stream).
        let master: any MasterWriting = try LegacyMasterWriter(
            outputURL: tempURL,
            videoSettings: videoSettings,
            refusedInput: { SessionError.writerFailed("AVAssetWriter.canAdd(_:) refused \($0) input") },
            startFailed: { SessionError.writerFailed($0 ?? "startWriting() returned false") })

        let configuration = SCStreamConfiguration()
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight
        // **The crop, at the SOURCE.** `nil` for a display capture. Set here rather than
        // applied per frame downstream: ScreenCaptureKit delivers frames already cropped
        // and already the output's size, so nothing later has to know a window moved.
        if let rect = source.sourceRect {
            configuration.sourceRect = CGGeometryBridge.rect(from: rect)
        }
        configuration.showsCursor = false                 // Step 0 / D2-8
        configuration.scalesToFit = false                  // D2-13a
        configuration.preservesAspectRatio = true           // D2-13a
        // Set explicitly: unset, where ScreenCaptureKit places content that does
        // not fill the surface is undocumented.
        configuration.destinationRect = CGGeometryBridge.rect(from: destination)
        lock.withLock {
            unsafe _diagnostics.configuredDestinationRect = destination
            unsafe _diagnostics.segmentConfigurations.append(
                Diagnostics.SegmentConfiguration(bufferWidth: geometry.pixelWidth,
                                                  bufferHeight: geometry.pixelHeight,
                                                  destination: destination, scale: geometry.scale))
        }
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        unsafe configuration.colorSpaceName = CGColorSpace.sRGB    // D2-15 — pinned, placeholder gamut choice
        // A floor, not a cadence — presentation times come from each sample
        // buffer and are never assumed from this number.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let filter = source.filter()
        let scStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try scStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)

        // One `ObservationWriter` per segment, beside the media. No package means
        // no log for this segment, exactly as it already means no media.
        let packageURL = await MainActor.run { mediaSink.packageURL }
        let (input, ax, blindness) = lock.withLock { unsafe (inputObserver, axObserver, observationBlindness) }
        var writer: ObservationWriter?
        if let packageURL {
            let header = ObservationLogHeader(anchor: Minting.epochAnchor(), segmentIndex: index,
                                              mediaFilename: mediaFilename, revision: geometry.revision,
                                              blindness: blindness)
            do {
                writer = try ObservationWriter.open(segment: header, in: packageURL)
            } catch {
                FileHandle.standardError.write(Data((
                    "CaptureSession: ObservationWriter.open failed for segment \(index): \(error)\n"
                ).utf8))
            }
            // Declared only for channels this session is actually observing: in
            // `ObservationLogTrailer.recordCounts` a zero value and an absent key
            // are different facts, so a run blind to input monitoring must not
            // claim `pointer: 0`.
            if let writer {
                let inputBlind = blindness.contains(.inputMonitoringUnavailable)
                    || blindness.contains(.eventTapRunLoopSourceUnavailable)
                if !inputBlind {
                    for kind in ["pointer", "button", "key", "secureInput", "tapDisabled"] {
                        writer.declareRecordKind(kind)
                    }
                }
                if !blindness.contains(.accessibilityUnavailable) {
                    writer.declareRecordKind("axChain")
                }
            }
        }

        lock.withLock {
            unsafe self.stream = scStream
            unsafe self.master = master
            unsafe self.writerTempURL = tempURL
            unsafe self.writerSessionStarted = false
            unsafe self.currentGeometry = geometry
            unsafe self.currentDestination = destination
            unsafe self.suspendAppendsForReconfiguration = false
            unsafe self.currentMediaFilename = mediaFilename
            unsafe self.lastFrameInstant = nil
            unsafe self.frameCounterForBlackCheck = 0
            unsafe self.blackFrameConsecutive = 0
            unsafe self.observationWriter = writer
            unsafe self.inputDiagnosticsAtSegmentStart = input?.diagnostics ?? InputObserver.Diagnostics()
            unsafe self.axDiagnosticsAtSegmentStart = ax?.diagnostics ?? AXObserver.Diagnostics()
            unsafe self.frameStatusCountsAtSegmentStart = unsafe _diagnostics.frameStatusCounts
            unsafe self.secureInputSuppressedNanosAtCurrentSegment = 0
            let openInstant = HostInstant(epoch: epoch, hostTime: Minting.hostNow())
            unsafe ledger.openSegment(at: openInstant, revision: geometry.revision, mediaFilename: mediaFilename)
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
            let master: (any MasterWriting)?
            let tempURL: URL?
            let mediaFilename: String?
            let endInstant: HostInstant
        }
        guard let snapshot = lock.withLock({ () -> Snapshot? in
            guard unsafe isRunning, unsafe ledger.isSegmentOpen else { return nil }
            let instant = unsafe lastFrameInstant ?? HostInstant(epoch: epoch, hostTime: Minting.hostNow())
            return unsafe Snapshot(scStream: stream, master: master, tempURL: writerTempURL,
                             mediaFilename: currentMediaFilename, endInstant: instant)
        }) else {
            throw SessionError.noSegmentOpen
        }

        if let scStream = snapshot.scStream {
            try? await scStream.stopCapture()
        }
        if let master = snapshot.master, master.status == .writing {
            await master.finish()
        }

        if let master = snapshot.master, master.status == .completed,
           let tempURL = snapshot.tempURL, let mediaFilename = snapshot.mediaFilename {
            // `.mappedIfSafe`: the finished file can be several GB, and an eager
            // read would double that in RAM.
            let bytes = try Data(contentsOf: tempURL, options: .mappedIfSafe)
            // Through the document, never around it: `addMedia` records the
            // reference and marks the document dirty.
            let sink = mediaSink
            try await MainActor.run { try sink.acceptMedia(bytes, named: mediaFilename) }
            try? FileManager.default.removeItem(at: tempURL)
        } else {
            // This segment's recording did not reach the package. The writer's
            // status and error are captured here because `AVAssetWriter.error` is
            // gone once the writer is released, and the scratch file is
            // deliberately NOT deleted — those bytes are the only copy.
            let statusDescription: String
            switch snapshot.master?.status {
            case .none: statusDescription = "no writer"
            case .some(.unknown): statusDescription = "unknown (startWriting never returned)"
            case .some(.writing): statusDescription = "writing (finishWriting did not complete it)"
            case .some(.completed): statusDescription = "completed"     // then tempURL/filename was nil
            case .some(.failed): statusDescription = "failed"
            case .some(.cancelled): statusDescription = "cancelled"
            case .some(.unrecognised(let raw)): statusDescription = "unrecognised status \(raw)"
            }
            let discarded = Diagnostics.DiscardedSegment(
                mediaFilename: snapshot.mediaFilename ?? "(none minted)",
                writerStatus: statusDescription,
                writerError: snapshot.master?.errorDescription ?? "nil",
                retainedScratchPath: snapshot.tempURL?.path() ?? "(none)")
            lock.withLock { unsafe _diagnostics.discardedSegments.append(discarded) }
        }

        let (segment, closingWriter) = lock.withLock { () -> (MasterSegment, ObservationWriter?) in
            let segment = unsafe ledger.closeSegment(at: snapshot.endInstant, endedBy: boundary)
            unsafe self.stream = nil
            unsafe self.master = nil
            unsafe self.writerTempURL = nil
            unsafe self.currentMediaFilename = nil
            let writer = unsafe self.observationWriter
            unsafe self.observationWriter = nil
            // `true` only when a real writer is about to be drained and closed
            // below. Set inside the SAME lock as `observationWriter = nil` so a
            // concurrent `appendObservation` can never see the writer gone with
            // this flag not yet caught up.
            unsafe self.finalizingCurrentSegment = (writer != nil)
            if stopping { unsafe isRunning = false }
            return (segment, writer)
        }

        if let closingWriter {
            // Wait for the AX queue before closing: `AXObserver.enqueue` may still
            // be walking a chain for a click just before this boundary, which
            // `routeInputObservation` already routed to THIS writer. Without the
            // wait the chain hits `WriterError.logIsClosed` and is lost.
            let ax = lock.withLock { unsafe axObserver }
            ax?.waitForQueuedClicks()
            let gapWatches = observationGapWatches(hostRange: segment.hostRange)
            do {
                try closingWriter.close(endedBy: boundary, hostRange: segment.hostRange, gapWatches: gapWatches)
            } catch {
                lock.withLock {
                    unsafe _diagnostics.observationAppendFailures += 1
                    if unsafe _diagnostics.firstObservationAppendFailure == nil {
                        unsafe _diagnostics.firstObservationAppendFailure = String(describing: error)
                    }
                }
            }
            // The close-drain window ends here whether `close(...)` succeeded or
            // threw; later `nil`-writer observations belong to
            // `observationsOutsideAnOpenSegment`.
            lock.withLock { unsafe finalizingCurrentSegment = false }
        }

        if stopping {
            unregisterReconfigurationObserver()
        }
    }

    /// The four `GapWatch` rows for the segment that just closed: diagnostics as
    /// of now minus the snapshot `beginSegment` took, because the observers are
    /// session-long while the log is per-segment.
    private nonisolated func observationGapWatches(hostRange: HostRange) -> [GapWatch] {
        let (inputNow, inputBase, axNow, axBase, secureInputSuppressed, framesBase) = lock.withLock {
            unsafe (inputObserver?.diagnostics ?? InputObserver.Diagnostics(), inputDiagnosticsAtSegmentStart,
             axObserver?.diagnostics ?? AXObserver.Diagnostics(), axDiagnosticsAtSegmentStart,
             secureInputSuppressedNanosAtCurrentSegment, frameStatusCountsAtSegmentStart)
        }
        let framesNow = lock.withLock { unsafe _diagnostics.frameStatusCounts }
        let frameCallbacksThisSegment = framesNow.values.reduce(0, +) - framesBase.values.reduce(0, +)
        let idleFramesThisSegment = (framesNow[SCFrameStatus.idle.rawValue] ?? 0)
            - (framesBase[SCFrameStatus.idle.rawValue] ?? 0)

        return [
            .tapDisabled(tapEnabledPolls: inputNow.tapEnabledPolls - inputBase.tapEnabledPolls,
                        tapPollingSpanNanos: inputNow.tapPollingSpanNanos - inputBase.tapPollingSpanNanos,
                        tapDisabledIntervals: inputNow.tapDisabledIntervals - inputBase.tapDisabledIntervals,
                        tapBlindNanos: inputNow.tapBlindNanos - inputBase.tapBlindNanos),
            .secureInput(secureInputChecks: inputNow.secureInputChecks - inputBase.secureInputChecks,
                        secureInputCheckSpanNanos: inputNow.secureInputCheckSpanNanos
                            - inputBase.secureInputCheckSpanNanos,
                        secureInputIntervals: inputNow.secureInputIntervals - inputBase.secureInputIntervals,
                        suppressedNanos: secureInputSuppressed),
            .videoFramesNotProduced(frameCallbacksObserved: frameCallbacksThisSegment,
                                    observationSpanNanos: hostRange.duration.rawValue,
                                    idleFrames: idleFramesThisSegment),
            .axAncestorWalk(chainsRecorded: axNow.chainsRecorded - axBase.chainsRecorded,
                            observationSpanNanos: hostRange.duration.rawValue,
                            truncatedWalks: (axNow.truncatedDepthCapReached - axBase.truncatedDepthCapReached)
                                + (axNow.truncatedBudgetExceeded - axBase.truncatedBudgetExceeded)),
        ]
    }

    /// Routes one `InputObserver.Observation` to the segment's
    /// `ObservationWriter` and, for a button-down, enqueues its AX chain. Called
    /// on the tap callback thread, so `nonisolated`, with everything it touches
    /// behind `lock`.
    ///
    /// The writer is captured once at the top and that single reference is what
    /// the AX completion closure uses: an AX chain belongs to the segment its
    /// click happened in, and it answers after that segment's writer may have
    /// been replaced. `finalizingCurrentSegment` must be read in the SAME
    /// `lock.withLock` as `observationWriter`, or a close running between two
    /// separate reads would misattribute a drop to the wrong counter.
    private nonisolated func routeInputObservation(_ observation: InputObserver.Observation) {
        let (writer, finalizing) = lock.withLock { unsafe (observationWriter, finalizingCurrentSegment) }
        switch observation {
        case .pointer(let sample):
            appendObservation(sample, to: writer, whileFinalizing: finalizing)
        case .button(let event):
            appendObservation(event, to: writer, whileFinalizing: finalizing)
            guard event.phase == .down, let ax = lock.withLock({ unsafe axObserver }) else { return }
            ax.enqueue(event) { [weak self] record in
                self?.appendObservation(record, to: writer, whileFinalizing: finalizing)
            }
        case .key(let sample):
            appendObservation(sample, to: writer, whileFinalizing: finalizing)
        case .secureInput(let interval):
            lock.withLock { unsafe secureInputSuppressedNanosAtCurrentSegment += interval.interval.duration.rawValue }
            appendObservation(interval, to: writer, whileFinalizing: finalizing)
        case .tapDisabled(let interval):
            appendObservation(interval, to: writer, whileFinalizing: finalizing)
        }
    }

    /// One `ObservationWriter.append`, with every way of losing the record
    /// counted rather than dropped in silence. `writer == nil` splits by
    /// `whileFinalizing`: `true` is a segment closing right now
    /// (`observationsDroppedAfterSegmentClose`, a genuine loss), `false` is no
    /// segment open at all (`observationsOutsideAnOpenSegment`). `whileFinalizing`
    /// must be `routeInputObservation`'s paired read, not a fresh one.
    private nonisolated func appendObservation(_ record: some ObservationRecord, to writer: ObservationWriter?,
                                                whileFinalizing: Bool) {
        guard let writer else {
            lock.withLock {
                if whileFinalizing {
                    unsafe _diagnostics.observationsDroppedAfterSegmentClose += 1
                } else {
                    unsafe _diagnostics.observationsOutsideAnOpenSegment += 1
                }
            }
            return
        }
        do {
            try writer.append(record)
        } catch {
            lock.withLock {
                unsafe _diagnostics.observationAppendFailures += 1
                if unsafe _diagnostics.firstObservationAppendFailure == nil {
                    unsafe _diagnostics.firstObservationAppendFailure = String(describing: error)
                }
            }
        }
    }

    // MARK: - SCStreamOutput

    /// `nonisolated` because ScreenCaptureKit delivers these on the
    /// `sampleHandlerQueue` given to `addStreamOutput` — here `sampleQueue` —
    /// never the main queue.
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

    /// A revoked Screen Recording grant does NOT reach here — it produces black
    /// frames, not a stream error (see `checkForBlackFrame`). Genuine stream
    /// failures close the segment with `.failed` from a detached `Task`, since
    /// this callback must stay synchronous to match the protocol.
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
        lock.withLock { unsafe _diagnostics.frameStatusCounts[statusRaw, default: 0] += 1 }

        // A callback is not a frame (F2-4: idle was 42–84% of callbacks
        // across four runs) — append only `.complete`.
        guard statusRaw == SCFrameStatus.complete.rawValue else { return }

        // Counted HERE, at the moment the frame is known to be complete —
        // not further down, after the timestamp checks. It used to be
        // incremented alongside the append bookkeeping, which meant a frame
        // dropped for an unreadable timestamp was never a "complete frame"
        // at all, and `everyCompleteFrameIsAccountedFor` could not be
        // stated, let alone hold. A conservation law only means something if
        // the total is fixed before the branches start.
        lock.withLock { unsafe _diagnostics.completeFrameCount += 1 }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // An invalid `CMTime` is the same loss as an unconvertible one — the
        // frame has no place on the timeline — and is counted with it rather
        // than returning uncounted, which is what this line used to do.
        guard pts.isValid else {
            lock.withLock { unsafe _diagnostics.unconvertiblePresentationTimeCount += 1 }
            return
        }
        // Integer nanoseconds, not `CMTimeGetSeconds(pts) * 1e9` — `Nanoseconds`
        // is never a `Double`. The conversion lives in `Nanoseconds` because the
        // naive inline form overflows `Int64` and is untestable from here.
        guard let ptsNanoseconds = Nanoseconds(rationalSeconds: pts.value, timescale: pts.timescale) else {
            lock.withLock { unsafe _diagnostics.unconvertiblePresentationTimeCount += 1 }
            return
        }
        let ptsNanos = ptsNanoseconds.rawValue
        let frameInstant = HostInstant(epoch: epoch, hostTime: ptsNanoseconds)
        let latencyNanos = callbackInstant.rawValue - ptsNanos

        let observedContentScale = recordContentScale(from: attachments)
        recordExtrinsicRects(from: attachments)

        let (shouldCheckBlack, masterRef, sessionAlreadyStarted) = lock.withLock {
            () -> (Bool, (any MasterWriting)?, Bool) in
            if latencyNanos >= 0 { unsafe _diagnostics.ptsToCallbackLatencyNanos.append(latencyNanos) }
            unsafe lastFrameInstant = frameInstant
            unsafe frameCounterForBlackCheck += 1
            let shouldCheck = unsafe frameCounterForBlackCheck % Self.blackFrameCheckEveryNFrames == 0
            return unsafe (shouldCheck, master, writerSessionStarted)
        }

        if shouldCheckBlack, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            checkForBlackFrame(pixelBuffer)
        }

        // Each exit counted separately: an already-failed writer and a real-time
        // input under backpressure are both legitimate but distinguishable.
        if lock.withLock({ unsafe suspendAppendsForReconfiguration }) {
            lock.withLock { unsafe _diagnostics.skippedAwaitingReconfigurationCount += 1 }
            return
        }
        guard let masterRef, masterRef.status == .writing else {
            lock.withLock { unsafe _diagnostics.skippedWriterNotWritingCount += 1 }
            return
        }
        guard masterRef.video.isReadyForMoreMediaData else {
            lock.withLock { unsafe _diagnostics.skippedInputNotReadyCount += 1 }
            return
        }
        if !sessionAlreadyStarted {
            masterRef.startSession(at: pts)
            lock.withLock { unsafe writerSessionStarted = true }
        }
        let accepted = masterRef.video.append(sampleBuffer)
        if accepted, let observedContentScale, observedContentScale != 1 {
            lock.withLock { unsafe _diagnostics.appendedResampledFrameCount += 1 }
        }
        recordAppend(accepted, of: masterRef, isVideo: true)
    }

    /// Records whether an append was accepted, and captures the writer's error at
    /// the first refusal. A named function rather than an inline `if` so the
    /// `Bool` cannot look ignorable.
    private nonisolated func recordAppend(_ accepted: Bool, of master: any MasterWriting, isVideo: Bool) {
        lock.withLock {
            if accepted {
                if isVideo { unsafe _diagnostics.appendedVideoFrameCount += 1 }
                else { unsafe _diagnostics.appendedAudioSampleCount += 1 }
                return
            }
            if isVideo { unsafe _diagnostics.failedVideoAppendCount += 1 }
            else { unsafe _diagnostics.failedAudioAppendCount += 1 }
            guard unsafe _diagnostics.firstAppendFailure == nil else { return }
            unsafe _diagnostics.firstAppendFailure =
                "\(isVideo ? "video" : "audio") append refused; writer status: \(master.status.name); "
                + "writer error: \(master.errorDescription ?? "nil")"
        }
    }

    private nonisolated func appendAudio(_ sampleBuffer: CMSampleBuffer, isSystemAudio: Bool) {
        // Counted first, before any filter, and per source rather than summed —
        // a total taken after a filter cannot show what the filter removed, and
        // a summed one cannot name which track it removed from.
        updateAudioAccounting(isSystemAudio) { $0.delivered += 1 }

        // The layout ScreenCaptureKit actually delivered, recorded before the
        // buffer is touched and only once per source.
        lock.withLock {
            if isSystemAudio, unsafe _diagnostics.systemAudioLayout == nil {
                unsafe _diagnostics.systemAudioLayout = AudioInterleave.layoutDescription(of: sampleBuffer)
            } else if !isSystemAudio, unsafe _diagnostics.microphoneLayout == nil {
                unsafe _diagnostics.microphoneLayout = AudioInterleave.layoutDescription(of: sampleBuffer)
            }
        }

        let (masterRef, trackRef, sessionAlreadyStarted) = lock.withLock {
            () -> ((any MasterWriting)?, (any MasterTrackWriting)?, Bool) in
            unsafe (master, master.map { isSystemAudio ? $0.systemAudio : $0.microphone }, unsafe writerSessionStarted)
        }
        guard let masterRef, masterRef.status == .writing else {
            updateAudioAccounting(isSystemAudio) { $0.skippedWriterNotWriting += 1 }
            return
        }
        guard let trackRef, trackRef.isReadyForMoreMediaData else {
            updateAudioAccounting(isSystemAudio) { $0.skippedInputNotReady += 1 }
            return
        }
        // Audio arriving before the first complete video frame is dropped rather
        // than starting the writer session off an audio PTS: the master's session
        // always starts at the first video frame. Counted, since at the head of a
        // recording this is the normal case.
        guard sessionAlreadyStarted else {
            updateAudioAccounting(isSystemAudio) { $0.skippedSessionNotStarted += 1 }
            return
        }

        // A `.mov` cannot store non-interleaved LPCM and a passthrough input
        // cannot re-lay-out what it is given; without this the first audio append
        // is refused and that failure kills the video track too.
        guard let writable = AudioInterleave.interleaved(sampleBuffer) else {
            updateAudioAccounting(isSystemAudio) { $0.uninterleavable += 1 }
            return
        }
        let level = AudioInterleave.rms(of: writable)
        let accepted = trackRef.append(writable)
        updateAudioAccounting(isSystemAudio) {
            if accepted { $0.appended += 1 } else { $0.refused += 1 }
            if let level { $0.peakRMS = max($0.peakRMS ?? 0, level) }
        }
        recordAppend(accepted, of: masterRef, isVideo: false)
    }

    private nonisolated func updateAudioAccounting(_ isSystemAudio: Bool,
                                                    _ change: (inout Diagnostics.AudioTrackAccounting) -> Void) {
        lock.withLock {
            if isSystemAudio { unsafe change(&_diagnostics.systemAudioAccounting) }
            else { unsafe change(&_diagnostics.microphoneAccounting) }
        }
    }

    // MARK: - `SCStreamFrameInfoContentScale` — D2-13a: recorded, not asserted

    /// Records every complete frame's `ContentScale` in `Diagnostics` rather than
    /// asserting `== 1`: resampling can legitimately occur (a window grown past
    /// the display, with `scalesToFit = false`), and a `precondition` would kill
    /// the process and discard the segment already captured. A caller can decide
    /// the master is unusable after the fact.
    ///
    /// Returns the value as well as recording it, so the caller can distinguish
    /// frames the stream delivered resampled from frames resampled *and written*.
    /// `nil` when the attachment was unreadable.
    @discardableResult
    private nonisolated func recordContentScale(from attachments: [SCStreamFrameInfo: Any]) -> Double? {
        let scaleValue: Double?
        if let d = attachments[.contentScale] as? Double {
            scaleValue = d
        } else if let n = attachments[.contentScale] as? NSNumber {
            scaleValue = n.doubleValue
        } else {
            scaleValue = nil
        }
        guard let scale = scaleValue else { return nil }
        lock.withLock {
            unsafe _diagnostics.contentScaleCheckedCount += 1
            if scale != 1 { unsafe _diagnostics.resampledFrameCount += 1 }
            unsafe _diagnostics.minContentScaleObserved = unsafe min(_diagnostics.minContentScaleObserved ?? scale, scale)
            unsafe _diagnostics.maxContentScaleObserved = unsafe max(_diagnostics.maxContentScaleObserved ?? scale, scale)
            // Also attributed to the segment open when it arrived; a session-wide
            // count cannot say which segment was resampled.
            if var current = unsafe _diagnostics.segmentConfigurations.last {
                current.framesChecked += 1
                if scale != 1 { current.framesResampled += 1 }
                current.contentScaleMin = min(current.contentScaleMin ?? scale, scale)
                current.contentScaleMax = max(current.contentScaleMax ?? scale, scale)
                unsafe _diagnostics.segmentConfigurations[_diagnostics.segmentConfigurations.count - 1] = current
            }
        }
        return scale
    }

    /// `SCStreamFrameInfoContentRect`/`.screenRect` are `CGRect`s wrapped in
    /// `NSValue`, bridged to `PointRect` immediately and never held as `CGRect`
    /// past this function (rule 5). They are the extrinsic mapping and must never
    /// feed `GeometryRevision` computation.
    private nonisolated func recordExtrinsicRects(from attachments: [SCStreamFrameInfo: Any]) {
        if let point = CGGeometryBridge.pointRect(fromFrameAttachment: attachments[.contentRect]) {
            lock.withLock { unsafe _diagnostics.lastContentRect = point }
        } else {
            lock.withLock { unsafe _diagnostics.unreadableContentRectCount += 1 }
        }
        if let point = CGGeometryBridge.pointRect(fromFrameAttachment: attachments[.screenRect]) {
            lock.withLock { unsafe _diagnostics.lastScreenRect = point }
        } else {
            lock.withLock { unsafe _diagnostics.unreadableScreenRectCount += 1 }
        }
    }

    // MARK: - Step 3: black-frame detection

    /// A revoked Screen Recording grant yields black frames, not an error, and
    /// can be revoked *during* a recording, so a status check at start does not
    /// cover it. Samples a small fixed grid's luminance on every Nth complete
    /// frame. The threshold is an uncalibrated placeholder and a genuinely black
    /// screen exists, so detection only logs and never closes a segment.
    private nonisolated func checkForBlackFrame(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = unsafe CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else { return }

        // 4x4 interior points, never the very edge (menu-bar/notch chrome sits at
        // a different luminance). BGRA 8-bit, matching the configured format.
        let buffer = unsafe base.assumingMemoryBound(to: UInt8.self)
        var allAtFloor = true
        outer: for row in 1...4 {
            for col in 1...4 {
                let x = min(width - 1, (width * col) / 5)
                let y = min(height - 1, (height * row) / 5)
                let offset = y * bytesPerRow + x * 4
                let b = unsafe Double(buffer[offset]) / 255.0
                let g = unsafe Double(buffer[offset + 1]) / 255.0
                let r = unsafe Double(buffer[offset + 2]) / 255.0
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if luminance > Self.blackFrameLuminanceFloor {
                    allAtFloor = false
                    break outer
                }
            }
        }

        let (consecutive, segmentIndex) = lock.withLock { () -> (Int, Int) in
            unsafe blackFrameConsecutive = unsafe allAtFloor ? blackFrameConsecutive + 1 : 0
            return unsafe (blackFrameConsecutive, ledger.closedSegments.count)
        }

        if consecutive == Self.blackFrameConsecutiveThreshold {
            lock.withLock {
                unsafe _diagnostics.blackFrameDetections.append((segmentIndex: segmentIndex, consecutiveChecks: consecutive))
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

    /// Must be registered before `startCapture()`; otherwise a reconfiguration is
    /// only inferred later, after the file is already wrong.
    private nonisolated func registerReconfigurationObserver() {
        let token = unsafe Unmanaged.passUnretained(self)
        lock.withLock { unsafe reconfigToken = unsafe token }
        // The `CGError` is recorded: a registration that failed and one that
        // succeeded but never fired otherwise leave identical evidence.
        let error = unsafe CGDisplayRegisterReconfigurationCallback(
            CaptureSession.reconfigurationCallback, token.toOpaque())
        lock.withLock { unsafe _diagnostics.reconfigurationObserverRegistration = error }
    }

    private nonisolated func unregisterReconfigurationObserver() {
        let token = unsafe lock.withLock { () -> Unmanaged<CaptureSession>? in
            let t = unsafe reconfigToken
            unsafe reconfigToken = nil
            return unsafe t
        }
        if let token = unsafe token {
            unsafe CGDisplayRemoveReconfigurationCallback(CaptureSession.reconfigurationCallback, token.toOpaque())
        }
    }

    /// A plain C function pointer, since `CGDisplayRegisterReconfigurationCallback`
    /// cannot capture context; `userInfo` carries `self` across that boundary.
    /// `nonisolated` because unannotated this `static let` is `@MainActor` and
    /// neither `deinit` nor a C callback context could reference it.
    private nonisolated static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo = unsafe userInfo else { return }
        let session = unsafe Unmanaged<CaptureSession>.fromOpaque(userInfo).takeUnretainedValue()

        // Appending stops synchronously here, on BOTH callbacks, before any
        // suspension point: splitting the segment needs `SCShareableContent
        // .current`, and frames arriving during that await reach the master
        // already resampled. `.beginConfigurationFlag` is deliberately not
        // filtered out, since "begin" arrives before the change and is the
        // earliest this process can know. Only the completed callback splits.
        session.lock.withLock { unsafe session.suspendAppendsForReconfiguration = true }

        guard !flags.contains(.beginConfigurationFlag) else { return }
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
    /// Pixels per point for a display's **current** mode.
    ///
    /// `CGDisplayMode` exposes both, and their ratio is the backing scale —
    /// 2 for a Retina "looks like" mode, 1 for a native one. Read fresh on
    /// every reconfiguration because it is exactly what a mode change can
    /// alter, and the session's constructor value cannot follow it.
    private nonisolated static func backingScale(of displayID: CGDirectDisplayID) -> Double? {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return nil }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    private nonisolated func handleReconfiguration(of displayID: CGDirectDisplayID) async {
        guard case .display(let capturedDisplay) = source, capturedDisplay.displayID == displayID else { return }
        guard lock.withLock({ unsafe ledger.isSegmentOpen }) else { return }

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

        // **The scale is re-derived, not reused.** `init(scale:)`'s own doc
        // comment argued that this type should not derive a display's scale
        // because the caller already has it. That reasoning holds at `start()`
        // and is false here: a reconfiguration happens *inside* the session,
        // and a display's backing scale factor changes with its mode. Measured
        // — switching a 3024x1964 Retina mode (2704 pixels per 1352 points) to
        // a native 2704x1690 one (1 pixel per point) and reusing the
        // constructor's 2.0 gave the new segment a 5408x3380 buffer for a 2704
        // wide source, and ScreenCaptureKit scaled every one of its 319 frames
        // by exactly 2.0. Six assertions passed over that recording; only the
        // seventh, added afterwards, saw it.
        let newSource = CaptureSource.display(freshDisplay)
        let newScale = Self.backingScale(of: displayID) ?? scale
        let newGeometry = newSource.geometry(scale: newScale, displayUUID: displayUUID)

        lock.withLock { unsafe _diagnostics.displayReconfigurationsHandled += 1 }

        try? await finalizeCurrentSegment(endedBy: .displayReconfigured(newRevision: newGeometry.revision))
        // `newSource`, not `self.source` — the whole point of re-deriving.
        try? await beginSegment(geometry: newGeometry,
                                 destination: newSource.destinationRect(scale: newScale))
    }
}

// MARK: - Segment lifecycle bookkeeping

/// Pure segment-lifecycle bookkeeping: mint an index, open a segment, close
/// it with a `HostRange` and a `SegmentBoundary`, and hand the accumulated
/// list to `SegmentTable.init(segments:)` — which throws — when
/// asked to `finish()`. No `ScreenCaptureKit`, no `AVFoundation`, no
/// permission, no picker: segment lifecycle against a fake frame source,
/// and it is tested that way in
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
    /// shape as `Minting.swift`'s and `CGGeometryBridge.swift`'s own fixes,
    /// applied one level down to a plain `struct` rather than
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
