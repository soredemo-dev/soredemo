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
/// Where a finished master segment's bytes go.
///
/// **A protocol so that `CaptureSession` cannot reach `ProjectPackageIO`
/// directly.** The session used to call `writeSidecar` itself, which put the
/// file in `media/` and left nothing in the manifest referencing it — see
/// `CaptureSession.init` and `ProjectDocument.addMedia(_:named:)` for why that
/// is a defect with a delete at the end of it rather than untidiness.
///
/// Declared here rather than beside its conformer because this is the file that
/// *consumes* it, and because `Soredemo/UI/ProjectDocument.swift` is not
/// compiled by `spikes/2026-08-02-capture-master` — a spike has no `NSDocument`
/// and supplies its own conformer, which is a test double and says so.
///
/// `@MainActor` on the requirement rather than on the protocol: the shipping
/// conformer is `NSDocument`-derived and its state must be touched on the main
/// actor, while `finalizeCurrentSegment` reaches this from a `nonisolated
/// async` context and therefore has to hop deliberately rather than by
/// inheriting an isolation it did not ask for.
public protocol MediaSink: Sendable {
    @MainActor func acceptMedia(_ data: Data, named name: String) throws

    /// **Added in Task 5.5**, for `CaptureSession` to open an `ObservationWriter` beside the
    /// media, following the same `media/master-NN.mov` ↔ `observations/segment-NN.jsonl` pairing
    /// `ObservationWriter.expectedLogURL(forMediaURL:)` already derives. `ProjectDocument` already
    /// had a member of this exact shape (Task 5, for `StageWindow`'s reader half); this requirement
    /// is what makes it load-bearing for the writer half too, rather than a coincidence of two
    /// unrelated properties sharing a name.
    ///
    /// `nil` when there is no package to write into yet — `ProjectDocument.packageURL`'s own doc
    /// comment gives the case (an unsaved document); a `MediaSink` with no package writes no
    /// observation log for that segment, exactly as it already writes no media.
    @MainActor var packageURL: URL? { get }
}

public final class CaptureSession: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    // MARK: - Configuration knobs held for the life of the session

    private let source: CaptureSource
    private let scale: Double
    private let displayUUID: UUID
    private let mediaSink: any MediaSink
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
        /// Frames whose `SCStreamFrameInfoContentScale` was successfully
        /// read at all — distinct from `completeFrameCount` because
        /// extraction can fail to parse the attachment (see
        /// `recordContentScale`'s two-cast fallback). **This is the count a
        /// caller must check is `> 0` before trusting `resampledFrameCount`
        /// or the min/max fields below** — "N of N checked frames had
        /// `ContentScale == 1`" is vacuously true at `N == 0`, exactly the
        /// shape `Tests/DeterminismTests` guards against for the symbol
        /// check (`#require(!objectFiles.isEmpty, "…would pass vacuously")`)
        /// and the coordinator's own correction to this task caught here: a
        /// human verification step that reports "all frames passed" without
        /// this count first is not a check, whatever the diagnostics claim.
        public internal(set) var contentScaleCheckedCount = 0
        /// Frames whose `SCStreamFrameInfoContentScale` was not 1 — D2-13a:
        /// "a frame whose content scale is not 1 *was* resampled", which is
        /// what makes "the master is unresampled" (D2-8's core claim)
        /// checkable rather than assumed. See `recordContentScale` for the
        /// assert-vs-record decision.
        public internal(set) var resampledFrameCount = 0
        /// Resampled frames that were **written to the master**, as opposed
        /// to merely delivered.
        ///
        /// This is the number D2-8 is about. `resampledFrameCount` counts
        /// what ScreenCaptureKit handed over; during a display
        /// reconfiguration the session deliberately drops frames rather than
        /// append them, and those still appear there. A verification that
        /// checked `resampledFrameCount == 0` would report a failure over a
        /// master that is, in fact, entirely unresampled — the same
        /// stream-versus-file confusion that let "310 complete frames" be
        /// reported over a zero-byte file.
        public internal(set) var appendedResampledFrameCount = 0
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
        /// Complete frames dropped because their presentation timestamp could
        /// not be expressed as `Nanoseconds` — a non-positive timescale, or a
        /// value too large for `Int64` nanoseconds.
        ///
        /// It is counted, not merely dropped, and it is counted *separately*
        /// from `completeFrameCount` rather than folded into it. A silent
        /// drop presents to a reader as "this frame never arrived", which is
        /// indistinguishable from the stream being idle — the shape
        /// `AGENTS.md` calls a measurement with no safe default. A non-zero
        /// value here means the master is missing frames the OS did deliver.
        ///
        /// This should stay at zero on every real run: `SCStream` uses host
        /// time at timescale 1e9, which is always convertible. It is a
        /// diagnostic against the assumption, not a expected-to-fire path.
        public internal(set) var unconvertiblePresentationTimeCount = 0

        /// A segment whose media never reached the package, and everything
        /// still knowable about why at the moment it happened.
        ///
        /// `SegmentTable` names a `mediaFilename` per segment. If this array
        /// is non-empty, at least one of those names has no file behind it —
        /// which the table itself cannot express, and which nothing else in
        /// the process will notice.
        public struct DiscardedSegment: Sendable {
            public let mediaFilename: String
            public let writerStatus: String
            /// `AVAssetWriter.error`, stringified at the point of failure.
            /// The writer is released immediately afterwards; this is the
            /// only moment the underlying `OSStatus` is still reachable.
            public let writerError: String
            /// The scratch file, deliberately **not** deleted. These are the
            /// captured bytes; whatever went wrong, they are recoverable
            /// from here until the OS reclaims the temporary directory.
            public let retainedScratchPath: String
        }
        public internal(set) var discardedSegments: [DiscardedSegment] = []

        /// Frames `AVAssetWriterInput.append(_:)` **accepted**, as distinct
        /// from `completeFrameCount`, which counts frames that arrived.
        ///
        /// These were one number until Task 8's step 1 reported "309
        /// complete frames, all with ContentScale == 1" over a scratch file
        /// containing **zero bytes**. Every statement in that report was
        /// true; none of them was about writing. `append(_:)` returns a
        /// `Bool` and the call site discarded it with `_ =`, so a run in
        /// which every single append failed was indistinguishable from a
        /// perfect one. Splitting the counts is what makes the subject of
        /// each number explicit — `completeFrameCount` is about the stream,
        /// this is about the file.
        public internal(set) var appendedVideoFrameCount = 0
        public internal(set) var appendedAudioSampleCount = 0
        /// Appends that returned `false`, by media type.
        public internal(set) var failedVideoAppendCount = 0
        public internal(set) var failedAudioAppendCount = 0
        /// The writer's status and error captured at the **first** append
        /// that returned `false`, not the last.
        ///
        /// `AVAssetWriter` latches the first failure and then rejects
        /// everything afterwards, so by the end of a run the error describes
        /// a consequence rather than the cause. This is the cause.
        public internal(set) var firstAppendFailure: String?

        /// **Task 5.5.** `ObservationWriter.append`/`.close` calls that threw,
        /// across every record kind and every segment — `WriterError
        /// .recordSpansTwoLines` shouldn't fire (`JSONEncoder` escapes
        /// newlines), `.foreignEpoch` shouldn't fire (one `epoch` for the
        /// whole session), but `.logIsClosed` legitimately can: an AX chain
        /// enqueued from a click near a segment boundary is appended to the
        /// writer instance open **at the click**, not the writer current when
        /// the chain finally answers, and `finalizeCurrentSegment` waits on
        /// `axObserver.waitForQueuedClicks()` before closing specifically to
        /// keep this at zero — see that function. Counted rather than
        /// silently dropped via `try?`, for the same reason every other
        /// append path in this type is: a dropped record with nothing
        /// counting it is indistinguishable from a record that was never
        /// produced.
        public internal(set) var observationAppendFailures = 0
        /// The first observation append/close failure, captured the same way
        /// `firstAppendFailure` is — the writer's error, not the last one, is
        /// the cause.
        public internal(set) var firstObservationAppendFailure: String?

        /// **Task 5.5, fix round 2 (code review).** Every observation
        /// `appendObservation` found with `writer == nil` — the record was
        /// never written anywhere, and until this counter existed nothing
        /// said so, which is exactly the silence
        /// `observationAppendFailures`'s own doc comment forbids.
        ///
        /// Two situations produce it, and this counter does not distinguish
        /// them — see the report for why one number is enough:
        ///
        ///   * **the bug this counter exists for.**
        ///     `finalizeCurrentSegment` sets `self.observationWriter = nil`
        ///     under `lock`, immediately — **before**
        ///     `axObserver.waitForQueuedClicks()`, which is a blocking
        ///     `queue.sync {}` that can take up to `AXObserver
        ///     .walkBudgetNanos` (35 ms) × `AXObserver.maximumQueuedClicks`
        ///     (8) — hundreds of milliseconds — and before
        ///     `closingWriter.close(...)`. The event tap is never torn down
        ///     during any of that: not for `pause()`, not for a display
        ///     reconfiguration (only `stream`/`master` rotate; the tap keeps
        ///     running for the whole session), and even for `stop()` the tap
        ///     is stopped only after this whole span. So every pointer,
        ///     button, key, secure-input and tap-disabled observation that
        ///     arrives during that window, **at every segment boundary**, is
        ///     silently lost before this fix — not "at most one trailing
        ///     sample" (that bound describes the narrower writer-nilled→
        ///     tap-torn-down window at `stop()` only), and not only at
        ///     `stop()`;
        ///   * a segment with no `packageURL` at all, so `beginSegment` never
        ///     opens a writer for it in the first place — not a bug, the same
        ///     choice `ProjectDocument.addMedia` already makes for an unsaved
        ///     document. Unreachable in the shipping app today:
        ///     `TemporaryFileMediaSink`, the only production `MediaSink`
        ///     constructed anywhere, never returns a `nil` `packageURL`. Named
        ///     here so the day a second `MediaSink` conformer can return `nil`
        ///     mid-session, this counter's meaning is already on record rather
        ///     than assumed.
        public internal(set) var observationsDroppedAfterSegmentClose = 0

        /// The layout of the first audio buffer each source delivered.
        public internal(set) var systemAudioLayout: String?
        public internal(set) var microphoneLayout: String?

        /// The same conservation law as the video path, **per audio track.**
        ///
        /// Per track, not summed, because the two sources are not alike: a
        /// real run measured system audio as `2ch 32-bit float @48000Hz,
        /// PLANAR` and the microphone as `1ch 32-bit float @44100Hz,
        /// INTERLEAVED`, and only the planar one was being dropped. A single
        /// total said "1045 buffers lost" and could not say by which source,
        /// while the answer — *the one that needed converting* — was the
        /// whole diagnosis.
        ///
        /// `delivered` is incremented at the top of `appendAudio`, before any
        /// filter, for the same structural reason `completeFrameCount` had to
        /// move: a total taken after a filter cannot show what the filter
        /// removed.
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
            /// Loudest RMS seen on this track, 0…1, or `nil` if no buffer
            /// was readable as interleaved Float32.
            ///
            /// **The counts below can all balance over silence.** Every
            /// buffer arriving, converting and appending is compatible with
            /// every sample being zero — and a track of digital silence is
            /// exactly what "the microphone was muted" and "the tone was
            /// never played" both look like. This is the only field here
            /// that distinguishes "nothing was lost" from "there was nothing".
            public internal(set) var peakRMS: Double?

            /// A track that was delivered buffers and wrote none of them.
            /// This is the state that produced a file with one audio track
            /// where two were expected — and it was only visible by counting
            /// tracks in the finished file, hours later.
            public var deliveredButWroteNothing: Bool { delivered > 0 && appended == 0 }
        }
        public internal(set) var systemAudioAccounting = AudioTrackAccounting()
        public internal(set) var microphoneAccounting = AudioTrackAccounting()

        /// Frames whose rect attachments could not be decoded at all.
        ///
        /// Non-zero here means `lastContentRect`/`lastScreenRect` are stale
        /// or absent for a reason inside this process, not because
        /// ScreenCaptureKit withheld them — a distinction that cost a whole
        /// verification run when an `as? NSValue` cast silently failed on
        /// every single frame.
        public internal(set) var unreadableContentRectCount = 0
        public internal(set) var unreadableScreenRectCount = 0

        /// The result of `CGDisplayRegisterReconfigurationCallback`.
        ///
        /// `.success` means the observer is installed; anything else means
        /// D2-10's segment-splitting cannot happen at all, and every
        /// downstream symptom — one segment where two were expected, one
        /// `GeometryRevision` across a resolution change — would look like a
        /// logic bug somewhere else entirely.
        public internal(set) var reconfigurationObserverRegistration: CGError?

        /// What each segment was actually configured with, one entry per
        /// `beginSegment`, in order.
        ///
        /// Added because a fix reasoned from two numbers (a buffer size and a
        /// ratio) did not work, and the next step after a wrong diagnosis is
        /// an instrument, not a second guess. These are the values handed to
        /// `SCStreamConfiguration`, recorded where they are set.
        public struct SegmentConfiguration: Sendable {
            public let bufferWidth: Int
            public let bufferHeight: Int
            public let destination: PixelRect
            public let scale: Double
            /// `ContentScale` values actually observed while this segment was
            /// the open one — the answer to "which segment was resampled",
            /// which a session-wide min/max cannot give.
            public internal(set) var contentScaleMin: Double?
            public internal(set) var contentScaleMax: Double?
            public internal(set) var framesChecked = 0
            public internal(set) var framesResampled = 0
        }
        public internal(set) var segmentConfigurations: [SegmentConfiguration] = []

        /// The `destinationRect` this session actually configured, recorded
        /// **at the moment it was set**.
        ///
        /// Recorded rather than recomputed, and that is the whole point. A
        /// caller checking "did ScreenCaptureKit put the content where we
        /// asked?" needs two independent sources: this, which is what was
        /// asked, and `lastContentRect`, which is per-frame
        /// `SCStreamFrameInfoContentRect` — what was delivered. Recomputing
        /// the request at check time from `SCWindow.frame` would read a
        /// value that may have changed since (the frame is extrinsic and the
        /// window can move), and comparing a fresh computation against its
        /// own inputs is an assertion that cannot fail — reported, worst of
        /// all, as the strongest check passing.
        public internal(set) var configuredDestinationRect: PixelRect?

        /// Complete frames the video path skipped without appending, by the
        /// reason it skipped them.
        ///
        /// These exist to make `everyCompleteFrameIsAccountedFor` provable
        /// rather than hopeful. Skipping is legitimate — an input under
        /// backpressure returns `isReadyForMoreMediaData == false` and
        /// dropping is what `expectsMediaDataInRealTime` asks for — but a
        /// skip that no counter names is indistinguishable from a frame that
        /// never arrived, which is how a run in which the writer had already
        /// failed still reported 310 complete frames.
        public internal(set) var skippedWriterNotWritingCount = 0
        public internal(set) var skippedInputNotReadyCount = 0
        /// Frames dropped between a display-reconfiguration callback and the
        /// new segment opening. Bounded by how long
        /// `SCShareableContent.current` takes; non-zero only across a
        /// reconfiguration, and the alternative to dropping them is writing
        /// resampled frames into the master.
        public internal(set) var skippedAwaitingReconfigurationCount = 0

        /// **A conservation law, and the invariant the zero-byte file broke.**
        ///
        /// Every complete video frame leaves the handler exactly one way:
        /// appended, refused, or skipped for one of three named reasons.
        /// The counts must therefore sum to `completeFrameCount` — always,
        /// on every run, with no tolerance.
        ///
        /// Stating it as a sum rather than as `completeFrameCount ==
        /// appendedVideoFrameCount` is deliberate. That simpler equality is
        /// not actually an invariant: a real-time input under backpressure
        /// legitimately refuses frames, so the equality would fire on a
        /// healthy recording and get relaxed into uselessness within a week.
        /// This one has no legitimate violation. If it fails, a frame took a
        /// path through `handleScreenSample` that nothing counts, and the
        /// next defect of this family will hide exactly there.
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
    /// The master file, behind `MasterWriting` rather than as an
    /// `AVAssetWriter` and three `AVAssetWriterInput`s.
    ///
    /// Everything this holds is deprecated at macOS 27.0 — `addInput:`,
    /// `startWriting`, `AVAssetWriterInput.append(_:)` — so the migration is
    /// scheduled and only its date is open. Behind the seam it is one file; in
    /// front of it, after Phase 2B's render and export rows also write media,
    /// it would have been a migration. See `MasterWriter.swift`.
    private nonisolated(unsafe) var master: (any MasterWriting)?
    private nonisolated(unsafe) var writerTempURL: URL?
    private nonisolated(unsafe) var writerSessionStarted = false
    private nonisolated(unsafe) var currentGeometry: DisplayGeometry?
    /// Held alongside `currentGeometry` and always set with it, so `resume()`
    /// cannot restore one and re-derive the other.
    private nonisolated(unsafe) var currentDestination: PixelRect?
    /// Set synchronously by `reconfigurationCallback`, cleared when the next
    /// segment opens. While true, complete frames are counted and dropped
    /// rather than appended — see the callback for why.
    private nonisolated(unsafe) var suspendAppendsForReconfiguration = false
    private nonisolated(unsafe) var currentMediaFilename: String?
    private nonisolated(unsafe) var lastFrameInstant: HostInstant?
    private nonisolated(unsafe) var frameCounterForBlackCheck = 0
    private nonisolated(unsafe) var blackFrameConsecutive = 0
    /// Opaque token for `CGDisplayRegisterReconfigurationCallback`'s
    /// `userInfo`, so the free-function callback can reach back into this
    /// instance without a global. `Unmanaged.passUnretained` — the callback
    /// is unregistered in `stop()`/`deinit` before the session can be freed.
    private nonisolated(unsafe) var reconfigToken: Unmanaged<CaptureSession>?

    // MARK: - Observation (Task 5.5)
    //
    // One `InputObserver` and one `AXObserver` for the life of the SESSION —
    // `start()` to `stop()` — not one per segment: the tap and the AX queue
    // are the expensive, permission-gated things to stand up, and D2-12's own
    // straddling rule already assumes an AX chain can outlive the segment
    // boundary its click happened in. `observationWriter` is the thing that
    // rotates per segment, opened in `beginSegment` and closed in
    // `finalizeCurrentSegment` — the same split `master`/`stream` already
    // have relative to `self.source`.

    private nonisolated(unsafe) var inputObserver: InputObserver?
    private nonisolated(unsafe) var axObserver: AXObserver?
    /// What `setUpObservation()` found when it tried to start the tap and
    /// asked for Accessibility — the same list every segment's
    /// `ObservationLogHeader.blindness` carries, because both permissions are
    /// read once for the whole session, not re-checked per segment.
    private nonisolated(unsafe) var observationBlindness: [ObservationBlindness] = []
    private nonisolated(unsafe) var observationWriter: ObservationWriter?
    /// `InputObserver.diagnostics`/`AXObserver.diagnostics` as they stood the
    /// moment the CURRENT segment opened — both are monotonic cumulative
    /// counters over the whole session, so a segment's own `GapWatch` rows are
    /// this snapshot subtracted from the diagnostics read at close, the same
    /// snapshot-then-diff shape `Diagnostics.SegmentConfiguration` already
    /// uses for per-segment `ContentScale`.
    private nonisolated(unsafe) var inputDiagnosticsAtSegmentStart = InputObserver.Diagnostics()
    private nonisolated(unsafe) var axDiagnosticsAtSegmentStart = AXObserver.Diagnostics()
    private nonisolated(unsafe) var frameStatusCountsAtSegmentStart: [Int: Int] = [:]
    /// The sum of every `SecureInputInterval.interval.duration` routed to the
    /// current segment's writer. Not derivable from `InputObserver.Diagnostics`
    /// by subtraction the way the tap/AX counters above are — that type counts
    /// intervals, never their total width — so this accumulates the one
    /// number `GapWatch.secureInput(suppressedNanos:)` needs directly, reset
    /// to zero at each `beginSegment`.
    private nonisolated(unsafe) var secureInputSuppressedNanosAtCurrentSegment: Int64 = 0

    // MARK: - Init

    /// `scale` and `displayUUID` are supplied by the caller, exactly
    /// mirroring `CaptureSource.geometry(scale:displayUUID:)`'s own
    /// parameters (Task 7) — this type does not derive them itself, for the
    /// same reason that function does not: deriving a display's UUID/scale
    /// is ambient CoreGraphics/AppKit state this file has no need to own,
    /// and the caller (eventually `capture-permissions`'s successor in
    /// `app-shell`) already has to compute them once to drive the picker.
    ///
    /// `mediaSink` is where each finished segment's bytes go, and it replaced
    /// a bare `packageURL` in Task 11.
    ///
    /// **The session used to call `ProjectPackageIO.writeSidecar` itself, and
    /// that was a live defect rather than a layering preference.**
    /// `writeSidecar` puts the file in `media/` and does nothing else — so
    /// every segment this session produced was a file the manifest did not
    /// reference, invisible to `ProjectSnapshot.mediaFilenames`, and correctly
    /// identified as an orphan by the next `ProjectDocument.compactMedia()`,
    /// which deletes it. The write-once refusal and the path-component check
    /// still happen, one layer further in: `ProjectDocument.addMedia(_:named:)`
    /// calls the same `writeSidecar` and then records the reference and marks
    /// the document dirty, which are the two steps that were missing.
    ///
    /// It is an `any MediaSink` and not an optional: a session with nowhere to
    /// put media is a session whose recording is discarded at the end, and
    /// having to say where at construction is what makes that unsayable by
    /// accident.
    ///
    /// `epoch` is the recording's `BootEpoch` (`Minting.bootEpoch()`), supplied
    /// once so every `HostInstant` this session mints shares one epoch — the
    /// same reasoning `SegmentTable.init(segments:)`'s `mixedEpochs` guard
    /// exists to catch if it were ever wrong, and the same reasoning
    /// `ObservationLogHeader.epoch` carries one line per log.
    public init(source: CaptureSource, scale: Double, displayUUID: UUID,
                mediaSink: any MediaSink, epoch: BootEpoch) {
        self.source = source
        self.scale = scale
        self.displayUUID = displayUUID
        self.mediaSink = mediaSink
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
        // Task 5.5, Step 5: once per SESSION, not once per segment — see the
        // "Observation" stored-property block above.
        await setUpObservation()
        try await beginSegment(geometry: source.geometry(scale: scale, displayUUID: displayUUID),
                                destination: source.destinationRect(scale: scale))
    }

    /// Constructs this session's `InputObserver`/`AXObserver`, asks for
    /// Accessibility (Step 4), starts the tap, and records what happened as
    /// `observationBlindness` — the list every segment's
    /// `ObservationLogHeader.blindness` carries.
    ///
    /// **`@MainActor`, not `nonisolated`**, unlike almost everything else in
    /// this file: `InputObserver.start(onObservation:)` is itself
    /// MainActor-isolated (its own doc comment explains why — it touches
    /// `CFRunLoopGetMain()`), and `CapturePermissions.requestAccessibilityAccess()`
    /// reads `Bundle`-adjacent process state the same way `dumpText()` does.
    /// `start()` is `nonisolated async`, so `await setUpObservation()` there
    /// is an ordinary actor hop, the same shape `finalizeCurrentSegment`
    /// already uses for `MainActor.run { try sink.acceptMedia(...) }`.
    ///
    /// **Assumes neither answer about Input Monitoring.** This is the first
    /// production call to `InputObserver.start(onObservation:)` anywhere in
    /// this app (`docs/.../task-5.5-report.md` § Step 6) — nothing here
    /// guards on `CapturePermissions.status(of: .inputMonitoring)` before
    /// calling it, and nothing pre-empts the grant. Whatever `CGEvent
    /// .tapCreate` does under this bundle's own identity is what happens;
    /// `CaptureError.inputMonitoringUnavailable` is caught below exactly like
    /// any other expected outcome, not specially avoided.
    @MainActor
    private func setUpObservation() async {
        // Step 4 — ask for Accessibility once, before the AX walk's first
        // use. The return value IS this session's accessibility reading for
        // the whole run: `CapturePermissions.status(of: .accessibility)` is
        // deliberately not also called here — `AppSourceAllowListTests
        // .theAccessibilityPredicateIsReadOnceAndOnlyInTheObserverThatInjectsIt`
        // pins that call to `AXObserver`'s own injection point, and a second
        // reader here would be a second policy about what the grant means.
        let accessibilityGranted = CapturePermissions.requestAccessibilityAccess()

        let arrangement = InputObserver.currentArrangement()
        let input = InputObserver(arrangement: arrangement, epoch: epoch)
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
            // `InputObserver.start` only ever throws `CaptureError` per its
            // own signature's callers; an unrecognised error type is not
            // silently absorbed into a blindness case that would misname it.
            FileHandle.standardError.write(Data((
                "CaptureSession: InputObserver.start threw an unexpected error: \(error)\n"
            ).utf8))
        }

        lock.withLock {
            self.inputObserver = input
            self.axObserver = ax
            self.observationBlindness = blindness
        }
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
        let (running, savedGeometry, savedDestination) =
            lock.withLock { (isRunning, currentGeometry, currentDestination) }
        guard running else { throw SessionError.notRunning }
        // Both saved values, or both re-derived — never one of each, which is
        // the mismatch `beginSegment`'s doc comment describes.
        if let savedGeometry, let savedDestination {
            try await beginSegment(geometry: savedGeometry, destination: savedDestination)
        } else {
            try await beginSegment(geometry: source.geometry(scale: scale, displayUUID: displayUUID),
                                    destination: source.destinationRect(scale: scale))
        }
    }

    /// The result of stopping a recording.
    ///
    /// **Why this is not just a `SegmentTable`.** It was, and that was the
    /// defect. A `SegmentTable` names a `mediaFilename` per segment; nothing
    /// in it can say whether a file exists behind that name. When Task 8's
    /// step 1 produced a segment whose media never reached the package,
    /// `stop()` returned a table that was structurally perfect and
    /// factually a lie — the failure value landed *inside the legal range of
    /// the success type*, which is the shape this project has been bitten by
    /// before and now refuses by construction.
    ///
    /// The fix is the same one `Evidence`'s non-empty requirement and
    /// `NormalizedPoint`'s validating initialiser use: make the bad state
    /// impossible to hold accidentally. A caller cannot reach the table
    /// without first writing down which case they are in. They may still
    /// choose to use an incomplete table — that is a legitimate thing to
    /// want, since it is the only record of what was recorded — but it is
    /// now a decision in their source, not a default.
    public enum Outcome: Sendable {
        /// Every segment's media is in the package.
        case complete(SegmentTable)
        /// At least one segment's media never reached the package. The
        /// discarded entries carry the writer's error and the retained
        /// scratch path for each.
        case incomplete(SegmentTable, discarded: [Diagnostics.DiscardedSegment])
    }

    /// Finalises the current segment with `.stopped`, unregisters the
    /// reconfiguration observer, and returns an `Outcome` carrying the
    /// `SegmentTable` — the validated, ordered record
    /// `SegmentTable.init(segments:)` (Task 4) throws out of if anything is
    /// out of order, overlapping, or spans two boot epochs.
    ///
    /// **Deliberately not `@discardableResult`**, which it used to be. That
    /// attribute belongs to the same family as the defect `Outcome` exists
    /// to close: it made "ignore the entire record of what was just
    /// recorded" the shortest thing a caller could write. Stopping a
    /// recording has exactly one interesting output and every caller has a
    /// use for it.
    public nonisolated func stop() async throws -> Outcome {
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

        // Tears the tap down for the whole session — `InputObserver.start(onObservation:)` was
        // called exactly once, in `setUpObservation()`, and this is its matching `stop()`.
        let observerToStop = lock.withLock { () -> InputObserver? in
            let observer = inputObserver
            inputObserver = nil
            return observer
        }
        if let observerToStop {
            await MainActor.run { observerToStop.stop() }
        }

        let table = try lock.withLock { try ledger.finish() }
        let discarded = lock.withLock { _diagnostics.discardedSegments }
        return discarded.isEmpty ? .complete(table) : .incomplete(table, discarded: discarded)
    }

    // MARK: - Segment open/close

    /// Shared by `start()`, `resume()`, and reconfiguration handling: mint a
    /// filename, build a fresh `AVAssetWriter` with three inputs, build a
    /// fresh `SCStream` sized to `geometry`, and open the ledger's next
    /// segment. The write-once refusal (`ProjectPackageIO.writeSidecar`)
    /// applies once the segment's bytes are finished — see
    /// `finalizeCurrentSegment` for why it cannot apply here, at open time.
    /// **`geometry` and `destination` are passed together, from one
    /// `CaptureSource`, and that is the invariant this signature exists to
    /// hold.** They used to be derived separately: `geometry` from the
    /// caller, `destination` from `self.source` — and `self.source` is a
    /// snapshot taken when the session was constructed. Across a display
    /// reconfiguration the two disagreed: the buffer followed the new
    /// display (2704x1690) while the destination rectangle still asked for
    /// the old one (3024x1964), so ScreenCaptureKit scaled every frame of
    /// the new segment by exactly 3024/2704 = 1.1183 — measured, 335 of 664
    /// frames with `ContentScale != 1`, which is D2-8's central claim broken
    /// for half a recording.
    ///
    /// It is worth naming what caused it: setting `destinationRect` at all
    /// was the fix for an uncontracted default, and the fix introduced this.
    /// A value that is now chosen has to be chosen *from the same place* as
    /// everything derived alongside it, on every path — including the one
    /// that only runs when the display changes underneath a recording.
    private nonisolated func beginSegment(geometry: DisplayGeometry, destination: PixelRect) async throws {
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
        let master: any MasterWriting = try LegacyMasterWriter(
            outputURL: tempURL,
            videoSettings: videoSettings,
            refusedInput: { SessionError.writerFailed("AVAssetWriter.canAdd(_:) refused \($0) input") },
            startFailed: { SessionError.writerFailed($0 ?? "startWriting() returned false") })

        let configuration = SCStreamConfiguration()
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight
        configuration.showsCursor = false                 // Step 0 / D2-8
        configuration.scalesToFit = false                  // D2-13a
        configuration.preservesAspectRatio = true           // D2-13a
        // D2-13a, and NOT a default. Unset, where ScreenCaptureKit places
        // content that does not fill the surface is undocumented — measured
        // as origin-anchored on this OS build and promised nowhere. See
        // `CaptureSource.destinationRect(scale:)` for why an uncontracted
        // anchor is the same failure this project already refused twice.
        configuration.destinationRect = CGGeometryBridge.rect(from: destination)
        lock.withLock {
            _diagnostics.configuredDestinationRect = destination
            _diagnostics.segmentConfigurations.append(
                Diagnostics.SegmentConfiguration(bufferWidth: geometry.pixelWidth,
                                                  bufferHeight: geometry.pixelHeight,
                                                  destination: destination, scale: geometry.scale))
        }
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

        // Task 5.5, Step 5 — one `ObservationWriter` per segment, beside the media. `packageURL`
        // is read through the sink rather than assumed, the same refusal `ProjectDocument
        // .addMedia` already makes for an unsaved document: no package, no log, for this segment —
        // exactly as it already writes no media for one.
        let packageURL = await MainActor.run { mediaSink.packageURL }
        let (input, ax, blindness) = lock.withLock { (inputObserver, axObserver, observationBlindness) }
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
            // Declared only for the channels this session is actually observing — see
            // `ObservationLogTrailer.recordCounts`'s own "a key present with a zero value and a
            // key absent are different facts": a run blind to input monitoring must not claim
            // `pointer: 0`, which would read as "the mouse never moved" rather than "nothing was
            // watching".
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
            self.stream = scStream
            self.master = master
            self.writerTempURL = tempURL
            self.writerSessionStarted = false
            self.currentGeometry = geometry
            self.currentDestination = destination
            self.suspendAppendsForReconfiguration = false
            self.currentMediaFilename = mediaFilename
            self.lastFrameInstant = nil
            self.frameCounterForBlackCheck = 0
            self.blackFrameConsecutive = 0
            self.observationWriter = writer
            self.inputDiagnosticsAtSegmentStart = input?.diagnostics ?? InputObserver.Diagnostics()
            self.axDiagnosticsAtSegmentStart = ax?.diagnostics ?? AXObserver.Diagnostics()
            self.frameStatusCountsAtSegmentStart = _diagnostics.frameStatusCounts
            self.secureInputSuppressedNanosAtCurrentSegment = 0
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
            let master: (any MasterWriting)?
            let tempURL: URL?
            let mediaFilename: String?
            let endInstant: HostInstant
        }
        guard let snapshot = lock.withLock({ () -> Snapshot? in
            guard isRunning, ledger.isSegmentOpen else { return nil }
            let instant = lastFrameInstant ?? HostInstant(epoch: epoch, hostTime: Minting.hostNow())
            return Snapshot(scStream: stream, master: master, tempURL: writerTempURL,
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
            // `.mappedIfSafe`: the finished file can be large (design doc:
            // "several GB of video"); mapping avoids doubling that in RAM
            // the way `Data(contentsOf:)`'s default eager read would.
            let bytes = try Data(contentsOf: tempURL, options: .mappedIfSafe)
            // Through the document, never around it: `addMedia` is what records
            // the reference and marks the document dirty. See `init`.
            let sink = mediaSink
            try await MainActor.run { try sink.acceptMedia(bytes, named: mediaFilename) }
            try? FileManager.default.removeItem(at: tempURL)
        } else {
            // The recording for this segment did not make it into the
            // package. This branch used to delete the scratch file and say
            // nothing — `stop()` returned a `SegmentTable` naming a
            // `mediaFilename` that did not exist, and the first thing to
            // notice was whatever tried to open the file, minutes or weeks
            // later, with no way left to say why. Task 8's step 1 hit it and
            // the only evidence was an absent directory.
            //
            // Two changes, and both are the same principle: a failure must
            // leave more behind than a success, not less.
            //   * the writer's own status and error are recorded, because
            //     `AVAssetWriter.error` is populated exactly here and
            //     nowhere else — once the writer is released it is gone;
            //   * the scratch file is NOT deleted, and its path is recorded.
            //     Those bytes are the only copy of what the user recorded.
            //     Leaking one file into `NSTemporaryDirectory` (which the OS
            //     reclaims) is the cheaper mistake by a wide margin.
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
            lock.withLock { _diagnostics.discardedSegments.append(discarded) }
        }

        let (segment, closingWriter) = lock.withLock { () -> (MasterSegment, ObservationWriter?) in
            let segment = ledger.closeSegment(at: snapshot.endInstant, endedBy: boundary)
            self.stream = nil
            self.master = nil
            self.writerTempURL = nil
            self.currentMediaFilename = nil
            let writer = self.observationWriter
            self.observationWriter = nil
            if stopping { isRunning = false }
            return (segment, writer)
        }

        if let closingWriter {
            // **Wait for the AX queue before closing, or D2-12's straddling rule is a lie this
            // writer tells.** `AXObserver.enqueue` may still be walking a chain for a click that
            // happened just before this boundary; `routeInputObservation` already captured THIS
            // writer at the moment that click was recorded (not "whichever writer is open when the
            // chain answers"), so the chain is correctly headed here rather than to the next
            // segment's log — but only if this writer is still open when it arrives. Without this,
            // a trailing click's AX chain finds `WriterError.logIsClosed` and is lost, silently, to
            // exactly the kind of two-instruments gap this project keeps re-finding.
            let ax = lock.withLock { axObserver }
            ax?.waitForQueuedClicks()
            let gapWatches = observationGapWatches(hostRange: segment.hostRange)
            do {
                try closingWriter.close(endedBy: boundary, hostRange: segment.hostRange, gapWatches: gapWatches)
            } catch {
                lock.withLock {
                    _diagnostics.observationAppendFailures += 1
                    if _diagnostics.firstObservationAppendFailure == nil {
                        _diagnostics.firstObservationAppendFailure = String(describing: error)
                    }
                }
            }
        }

        if stopping {
            unregisterReconfigurationObserver()
        }
    }

    /// The four D6a `GapWatch` rows for the segment that just closed, as the
    /// diagnostics read now minus the snapshot `beginSegment` took when it
    /// opened — see the "Observation" stored-property block for why a
    /// snapshot-then-diff is needed at all (the observers are session-long,
    /// the log is per-segment).
    private nonisolated func observationGapWatches(hostRange: HostRange) -> [GapWatch] {
        let (inputNow, inputBase, axNow, axBase, secureInputSuppressed, framesBase) = lock.withLock {
            (inputObserver?.diagnostics ?? InputObserver.Diagnostics(), inputDiagnosticsAtSegmentStart,
             axObserver?.diagnostics ?? AXObserver.Diagnostics(), axDiagnosticsAtSegmentStart,
             secureInputSuppressedNanosAtCurrentSegment, frameStatusCountsAtSegmentStart)
        }
        let framesNow = lock.withLock { _diagnostics.frameStatusCounts }
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
    /// `ObservationWriter` and, for a button-down, enqueues its AX chain.
    ///
    /// **Called on the tap callback thread — `nonisolated`, and everything it
    /// touches is behind `lock` or is itself thread-safe.** This is the first
    /// production call to `InputObserver.start(onObservation:)`'s sink
    /// anywhere in this app; see the task report for what that first call
    /// surfaced.
    ///
    /// **The writer is captured once, at the top, and that single reference —
    /// not a fresh `lock.withLock { observationWriter }` per case — is what
    /// the AX completion closure below uses too.** D2-12: an AX chain
    /// belongs to the segment its click happened in, and the chain answers
    /// asynchronously, possibly after this segment's writer has already been
    /// replaced by the next one's. Capturing the writer that was open at the
    /// moment of the click (this function runs synchronously off the tap
    /// callback, with no gap) is what keeps the chain on the right log
    /// without re-deriving "which segment was this click in" from a instant
    /// comparison.
    private nonisolated func routeInputObservation(_ observation: InputObserver.Observation) {
        let writer = lock.withLock { observationWriter }
        switch observation {
        case .pointer(let sample):
            appendObservation(sample, to: writer)
        case .button(let event):
            appendObservation(event, to: writer)
            guard event.phase == .down, let ax = lock.withLock({ axObserver }) else { return }
            ax.enqueue(event) { [weak self] record in
                self?.appendObservation(record, to: writer)
            }
        case .key(let sample):
            appendObservation(sample, to: writer)
        case .secureInput(let interval):
            lock.withLock { secureInputSuppressedNanosAtCurrentSegment += interval.interval.duration.rawValue }
            appendObservation(interval, to: writer)
        case .tapDisabled(let interval):
            appendObservation(interval, to: writer)
        }
    }

    /// One `ObservationWriter.append`, with every way of losing the record
    /// counted rather than dropped in silence.
    ///
    /// **`writer == nil` used to `return` here with nothing counting it —
    /// found in code review, fix round 2.** The doc comment this replaced
    /// called that "not a failure... a session choosing to record no log for
    /// this segment", which is true of the tap never arming (no observations
    /// are ever produced to reach here at all in that case) but was wrong
    /// about the case that actually reaches this line: `finalizeCurrentSegment`
    /// nils `observationWriter` immediately, then blocks on
    /// `axObserver.waitForQueuedClicks()` — up to several hundred
    /// milliseconds, at **every** segment boundary, with the tap still fully
    /// live throughout — before the writer is actually closed. Every
    /// observation arriving in that whole window found `writer == nil` and
    /// was silently lost. See `Diagnostics.observationsDroppedAfterSegmentClose`
    /// for the full account and the one case (unreachable today) where this
    /// really is the earlier, harmless reading.
    private nonisolated func appendObservation(_ record: some ObservationRecord, to writer: ObservationWriter?) {
        guard let writer else {
            lock.withLock { _diagnostics.observationsDroppedAfterSegmentClose += 1 }
            return
        }
        do {
            try writer.append(record)
        } catch {
            lock.withLock {
                _diagnostics.observationAppendFailures += 1
                if _diagnostics.firstObservationAppendFailure == nil {
                    _diagnostics.firstObservationAppendFailure = String(describing: error)
                }
            }
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

        // Counted HERE, at the moment the frame is known to be complete —
        // not further down, after the timestamp checks. It used to be
        // incremented alongside the append bookkeeping, which meant a frame
        // dropped for an unreadable timestamp was never a "complete frame"
        // at all, and `everyCompleteFrameIsAccountedFor` could not be
        // stated, let alone hold. A conservation law only means something if
        // the total is fixed before the branches start.
        lock.withLock { _diagnostics.completeFrameCount += 1 }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // An invalid `CMTime` is the same loss as an unconvertible one — the
        // frame has no place on the timeline — and is counted with it rather
        // than returning uncounted, which is what this line used to do.
        guard pts.isValid else {
            lock.withLock { _diagnostics.unconvertiblePresentationTimeCount += 1 }
            return
        }
        // Integer nanoseconds, not `CMTimeGetSeconds(pts) * 1e9` — `Nanoseconds`
        // is deliberately never a `Double` (its own doc comment), and this is
        // the one place a `CMTime` crosses into that type.
        //
        // The arithmetic itself lives in `Nanoseconds` rather than here, and
        // that is not tidiness. Written inline it was
        // `Int64(pts.value) * 1_000_000_000 / Int64(pts.timescale)`, which
        // trapped on `Int64` overflow for every frame after 9.2 s of uptime
        // — the whole capture path, on every run — and no test could reach
        // it, because reaching it needed a real `SCStream` sample buffer.
        // Moved into a Foundation-only leaf module, the part that was wrong
        // is covered by `Tests/TimelineTests/RationalConversionTests.swift`
        // and the part that needs ScreenCaptureKit is just these two reads.
        guard let ptsNanoseconds = Nanoseconds(rationalSeconds: pts.value, timescale: pts.timescale) else {
            lock.withLock { _diagnostics.unconvertiblePresentationTimeCount += 1 }
            return
        }
        let ptsNanos = ptsNanoseconds.rawValue
        let frameInstant = HostInstant(epoch: epoch, hostTime: ptsNanoseconds)
        let latencyNanos = callbackInstant.rawValue - ptsNanos

        let observedContentScale = recordContentScale(from: attachments)
        recordExtrinsicRects(from: attachments)

        let (shouldCheckBlack, masterRef, sessionAlreadyStarted) = lock.withLock {
            () -> (Bool, (any MasterWriting)?, Bool) in
            if latencyNanos >= 0 { _diagnostics.ptsToCallbackLatencyNanos.append(latencyNanos) }
            lastFrameInstant = frameInstant
            frameCounterForBlackCheck += 1
            let shouldCheck = frameCounterForBlackCheck % Self.blackFrameCheckEveryNFrames == 0
            return (shouldCheck, master, writerSessionStarted)
        }

        if shouldCheckBlack, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            checkForBlackFrame(pixelBuffer)
        }

        // Each exit counted separately. Both are legitimate — a writer that
        // has already failed, and a real-time input under backpressure — and
        // both used to leave through one anonymous `return`, which is how
        // 308 frames vanished between "complete" and "written" while the
        // report said nothing was wrong.
        if lock.withLock({ suspendAppendsForReconfiguration }) {
            lock.withLock { _diagnostics.skippedAwaitingReconfigurationCount += 1 }
            return
        }
        guard let masterRef, masterRef.status == .writing else {
            lock.withLock { _diagnostics.skippedWriterNotWritingCount += 1 }
            return
        }
        guard masterRef.video.isReadyForMoreMediaData else {
            lock.withLock { _diagnostics.skippedInputNotReadyCount += 1 }
            return
        }
        if !sessionAlreadyStarted {
            masterRef.startSession(at: pts)
            lock.withLock { writerSessionStarted = true }
        }
        let accepted = masterRef.video.append(sampleBuffer)
        if accepted, let observedContentScale, observedContentScale != 1 {
            lock.withLock { _diagnostics.appendedResampledFrameCount += 1 }
        }
        recordAppend(accepted, of: masterRef, isVideo: true)
    }

    /// Records whether an append was accepted, and captures the writer's
    /// error at the first refusal.
    ///
    /// The `Bool` this consumes used to be dropped with `_ =`. That is why
    /// this exists as a named function rather than an inline `if`: the whole
    /// defect was that the value looked ignorable.
    private nonisolated func recordAppend(_ accepted: Bool, of master: any MasterWriting, isVideo: Bool) {
        lock.withLock {
            if accepted {
                if isVideo { _diagnostics.appendedVideoFrameCount += 1 }
                else { _diagnostics.appendedAudioSampleCount += 1 }
                return
            }
            if isVideo { _diagnostics.failedVideoAppendCount += 1 }
            else { _diagnostics.failedAudioAppendCount += 1 }
            guard _diagnostics.firstAppendFailure == nil else { return }
            _diagnostics.firstAppendFailure =
                "\(isVideo ? "video" : "audio") append refused; writer status: \(master.status.name); "
                + "writer error: \(master.errorDescription ?? "nil")"
        }
    }

    private nonisolated func appendAudio(_ sampleBuffer: CMSampleBuffer, isSystemAudio: Bool) {
        // Counted FIRST, before any filter — the same structural requirement
        // the video path had to be rearranged for. A total taken after a
        // filter cannot show what the filter removed, and what the filter
        // removed is the entire question. This is what makes
        // `AudioTrackAccounting.balances` a statement rather than a hope.
        //
        // Per source, not summed. The first version of this counted every
        // dropped audio buffer into one number, and that number (1045) could
        // not say whether the loss was system audio or the microphone — while
        // the two sources had different layouts, different sample rates, and
        // only one of them was broken. A conservation law that cannot name
        // the track it broke on is a smoke alarm without a location.
        updateAudioAccounting(isSystemAudio) { $0.delivered += 1 }

        // Recorded before anything is done to the buffer, and only once per
        // source. This is the layout ScreenCaptureKit actually delivered —
        // the fact `AudioInterleave` was written against, stated by the OS
        // rather than inferred from an error code.
        lock.withLock {
            if isSystemAudio, _diagnostics.systemAudioLayout == nil {
                _diagnostics.systemAudioLayout = AudioInterleave.layoutDescription(of: sampleBuffer)
            } else if !isSystemAudio, _diagnostics.microphoneLayout == nil {
                _diagnostics.microphoneLayout = AudioInterleave.layoutDescription(of: sampleBuffer)
            }
        }

        let (masterRef, trackRef, sessionAlreadyStarted) = lock.withLock {
            () -> ((any MasterWriting)?, (any MasterTrackWriting)?, Bool) in
            (master, master.map { isSystemAudio ? $0.systemAudio : $0.microphone }, writerSessionStarted)
        }
        guard let masterRef, masterRef.status == .writing else {
            updateAudioAccounting(isSystemAudio) { $0.skippedWriterNotWriting += 1 }
            return
        }
        guard let trackRef, trackRef.isReadyForMoreMediaData else {
            updateAudioAccounting(isSystemAudio) { $0.skippedInputNotReady += 1 }
            return
        }
        // Audio arriving before the first complete video frame has nowhere
        // valid to land — dropped rather than starting the session off an
        // audio PTS, keeping "the master's session starts at the first video
        // frame" a single, simple rule instead of a race between three
        // streams. Counted, because at the head of a recording this is the
        // normal case and a silent version of it would look like the source
        // producing nothing.
        guard sessionAlreadyStarted else {
            updateAudioAccounting(isSystemAudio) { $0.skippedSessionNotStarted += 1 }
            return
        }

        // A `.mov` cannot store non-interleaved LPCM, and a passthrough
        // input cannot re-lay-out what it is given: without this, the first
        // audio append is refused and the refusal fails the writer for the
        // video track too. See `AudioInterleave`.
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
            if isSystemAudio { change(&_diagnostics.systemAudioAccounting) }
            else { change(&_diagnostics.microphoneAccounting) }
        }
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
    /// Returns the `ContentScale` this frame carried, or `nil` if the
    /// attachment was unreadable.
    ///
    /// **It returns the value as well as recording it** so the caller can
    /// tell `resampledFrameCount` (frames the STREAM delivered resampled)
    /// apart from frames that were resampled *and written*. Those are
    /// different claims about different things, and only the second one is
    /// what D2-8 is about. Sixteen frames arriving resampled during a
    /// reconfiguration and being dropped is fine; sixteen reaching the
    /// master is not — and a single count cannot say which happened.
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
            _diagnostics.contentScaleCheckedCount += 1
            if scale != 1 { _diagnostics.resampledFrameCount += 1 }
            _diagnostics.minContentScaleObserved = min(_diagnostics.minContentScaleObserved ?? scale, scale)
            _diagnostics.maxContentScaleObserved = max(_diagnostics.maxContentScaleObserved ?? scale, scale)
            // Also attributed to the segment that was open when it arrived.
            // A session-wide count cannot say WHICH segment was resampled,
            // and across a reconfiguration that is the only interesting
            // question.
            if var current = _diagnostics.segmentConfigurations.last {
                current.framesChecked += 1
                if scale != 1 { current.framesResampled += 1 }
                current.contentScaleMin = min(current.contentScaleMin ?? scale, scale)
                current.contentScaleMax = max(current.contentScaleMax ?? scale, scale)
                _diagnostics.segmentConfigurations[_diagnostics.segmentConfigurations.count - 1] = current
            }
        }
        return scale
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
        if let point = CGGeometryBridge.pointRect(fromFrameAttachment: attachments[.contentRect]) {
            lock.withLock { _diagnostics.lastContentRect = point }
        } else {
            lock.withLock { _diagnostics.unreadableContentRectCount += 1 }
        }
        if let point = CGGeometryBridge.pointRect(fromFrameAttachment: attachments[.screenRect]) {
            lock.withLock { _diagnostics.lastScreenRect = point }
        } else {
            lock.withLock { _diagnostics.unreadableScreenRectCount += 1 }
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
        // The `CGError` was discarded. A registration that failed and a
        // registration that succeeded but never fired produced identical
        // evidence — zero reconfigurations handled — and D2-10's whole
        // mechanism rests on this one call. Same family as the discarded
        // `append(_:)` result: the value that says whether the thing worked
        // was the value nothing looked at.
        let error = CGDisplayRegisterReconfigurationCallback(
            CaptureSession.reconfigurationCallback, token.toOpaque())
        lock.withLock { _diagnostics.reconfigurationObserverRegistration = error }
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
        guard let userInfo else { return }
        let session = Unmanaged<CaptureSession>.fromOpaque(userInfo).takeUnretainedValue()

        // **Appending stops synchronously, here, on BOTH callbacks.**
        //
        // Splitting the segment needs `SCShareableContent.current`, which is
        // an await and a cross-process round trip. Measured, that gap let 16
        // frames of a 660-frame recording reach the master already resampled
        // — the display had changed, the old segment's buffer had not, and
        // `ContentScale` on those frames was 1.1183. Six assertions passed
        // over that file. D2-8 says the master is unresampled, and "except
        // for about a second at each boundary" is a different claim.
        //
        // So the flag is set in the callback itself, before any suspension
        // point, and `.beginConfigurationFlag` is deliberately NOT filtered
        // out for this purpose: the "begin" callback arrives *before* the
        // change, which is the earliest instant this process can know about
        // it at all. Only the completed callback goes on to split.
        session.lock.withLock { session.suspendAppendsForReconfiguration = true }

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

        lock.withLock { _diagnostics.displayReconfigurationsHandled += 1 }

        try? await finalizeCurrentSegment(endedBy: .displayReconfigured(newRevision: newGeometry.revision))
        // `newSource`, not `self.source` — the whole point of re-deriving.
        try? await beginSegment(geometry: newGeometry,
                                 destination: newSource.destinationRect(scale: newScale))
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
