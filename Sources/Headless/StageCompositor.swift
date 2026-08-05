import AVFoundation
import CoreVideo
import Foundation
// `FrameRendering` and `FrameRenderingError` (Task 3) no longer need an import: this file now
// lives IN the `Headless` module that declares them, moved here by Phase 3A-1 Task 4. A module
// does not import itself — the `import Headless` this file carried while it still lived in the
// app target is gone, not merely redundant.
//
// `PointerSample`, `ObservationLog`, `JSONLReader`, `SecureInputInterval`, `TapDisabledInterval`
// for `buildPointerTrack(from:)` — reading the segment's observation log to build the
// `PointerTrack` `startRequest` reads from. Not previously imported here: nothing in this file
// touched `Project` before the drawn pointer (Phase 2B Task 5).
import Project
import Render
// `Nanoseconds` for the composition-time → host-clock conversion below. Reached until now only
// transitively through `Render` → `Project`/`Timeline`; `-enable-upcoming-feature
// MemberImportVisibility` (this app target's own flag, matched in
// `scripts/run-cross-boundary-probe.sh`) requires the direct import once this file names the type
// and reads `HostRange.start`/`.duration` off records it decodes.
import Timeline

/// The `AVVideoCompositing` conformance. **Owns no policy**: it asks the planner for a plan and
/// hands it to a renderer. Everything it decides is which frame is being drawn and when.
///
/// **`newPixelBuffer()`, not `newReadOnlyPixelBuffer()`.** The brief that specified this file
/// hedged on which name to call. Checked directly against the macOS 27.0 SDK header
/// (`AVVideoCompositing.h`): `newPixelBuffer` is declared on `AVVideoCompositionRenderContext` and
/// is `API_DEPRECATED("Use newReadOnlyPixelBuffer() instead", macos(10.9, 27.0), ...)` — the
/// successor name occurs exactly once in the entire SDK, inside that deprecation message, and is
/// declared on no type anywhere. `newReadOnlyPixelBuffer()` does not exist to call. Because the
/// deprecation floor (27.0) is above this project's deployment target (26.0, `ARCHITECTURE.md`
/// D2), `newPixelBuffer()` produces no deprecation warning here — this is not a D6b-27 row, it is
/// simply the only name that exists.
///
/// **`CVReadOnlyPixelBuffer`, found by the compiler rather than by any header or interface file —
/// not anticipated by the brief at all.** This SDK's `AVAsynchronousVideoCompositionRequest
/// .sourceReadOnlyPixelBuffer(byTrackID:)` (the successor the header names for the now-deprecated
/// `sourceFrameByTrackID:`) returns `CVReadOnlyPixelBuffer`, a type declared in no C header and no
/// `.swiftinterface` findable on this machine — its shape was established by `-typecheck`ing
/// single-member probes and reading the compiler's own type-mismatch diagnostics, not by reading
/// documentation. `.size: CVImageSize` (`.width`/`.height: Int`) supplies `sourceWidth`/
/// `sourceHeight` below. `withUnsafeBuffer<R>(_:)` hands a plain `CVPixelBuffer` into a closure for
/// its duration — the one public route back to the type `FrameRendering` (Task 3's seam) actually
/// speaks; the underlying buffer's own `unsafeBuffer` accessor is `internal` on
/// `CVBufferRepresentable` and unreachable from here. `request.finish(withComposedPixelBuffer:)` —
/// the same Swift name the brief used — turns out to want a `CVReadOnlyPixelBuffer` too, so the
/// freshly rendered `destination` (still a plain `CVPixelBuffer` from `newPixelBuffer()`) is
/// wrapped with `CVReadOnlyPixelBuffer(unsafeBuffer:)` before being handed back.
public nonisolated final class StageCompositor: NSObject, AVVideoCompositing {
    /// Set once before the composition is handed to AVFoundation. `nonisolated(unsafe)` for the
    /// same reason `CaptureSession`'s writer references are: AVFoundation calls back on its own
    /// queue and the value is published before any callback can see it.
    public nonisolated(unsafe) static var renderer: (any FrameRendering)?
    // NOT `public` — code review, fix round 1. No caller outside this file sets `style`: the
    // app (`StageWindow.load()`) never does, `StageCompositorTests.swift` never names it, and
    // the cross-boundary probe compiles this file BY PATH (`scripts/cross-boundary-digest-probe
    // .swift:4622,4827`) and so sees `internal` regardless of what this declaration says. If a
    // later task needs to set this from outside the module, it gets widened then, with that
    // caller named — not ahead of one existing.
    nonisolated(unsafe) static var style: StageStyle = .default
    /// The observation log this segment's pointer track is read from. `nil` — the default — means
    /// no pointer is ever drawn, which is not a fifth `PointerReading` case smuggled in through a
    /// side door: it is simply nothing having been configured to read from yet, the same state a
    /// caller that never sets `renderer` leaves this compositor in for the whole render.
    public nonisolated(unsafe) static var observationLogURL: URL?
    /// A reviewer's permanent decisions to suppress the pointer — `CursorOverride`'s own header —
    /// set the same way `renderer`/`style`/`observationLogURL` are: by whoever owns this
    /// composition, before playback starts. Not read from the observation log; see
    /// `buildPointerTrack(from:)`'s own header for why. Empty by default, which is not a fifth
    /// `PointerReading` case either — it means nobody has overridden anything yet, the same
    /// "nothing configured" state `observationLogURL == nil` is for the log.
    public nonisolated(unsafe) static var overrides: [CursorOverride] = []

    /// Counters a caller can read after playback or export has run — never only a console line,
    /// the same "a dropped record with nothing counting it is indistinguishable from a record that
    /// was never produced" rule `CaptureSession.Diagnostics`/`AXObserver.Diagnostics` already
    /// apply to capture. `static`, like `renderer`/`style`/`observationLogURL`/`overrides` above,
    /// for the identical reason: AVFoundation owns every `StageCompositor` instance and this app
    /// never gets a handle to one, so a per-instance counter would be unreadable by anything
    /// outside AVFoundation itself. `StageWindow.load()` resets this to a fresh `Diagnostics()` at
    /// the same point it (re)sets `renderer`/`style`/`observationLogURL` — one recording opened,
    /// one counter's worth of drops for it — so this answers "how many frames has the CURRENTLY
    /// open recording's preview session dropped", not a lifetime total across every file the app
    /// has ever opened.
    nonisolated(unsafe) private static var _diagnostics = Diagnostics()
    /// Guards `_diagnostics` only — a separate lock from the instance-level `lock` below, because
    /// `_diagnostics` is `static` (shared across every `StageCompositor` instance, exactly like
    /// `renderer`/`style`/`observationLogURL`/`overrides`) while `lock` guards one instance's own
    /// `pointerTrack`/`clickTrack`/`tracksLoaded`. Two locks, two different things each protects.
    private static let diagnosticsLock = NSLock()
    // Every access to `_diagnostics` below runs inside `diagnosticsLock.withLock` — the lock the
    // compiler cannot see through `nonisolated(unsafe)`, the same "only ever called from inside
    // the lock" shape `CoreImageFrameRenderer.cursorCanvas(size:)` documents for its own
    // `cursorCanvases`. `unsafe` at each site below is a true statement about that shape, not a
    // suppression of a real race.
    public static var diagnostics: Diagnostics { diagnosticsLock.withLock { unsafe _diagnostics } }
    /// Resets the counters below to zero — called by `StageWindow.load()` when a (possibly new)
    /// recording is opened, so a stale count from a previously opened file cannot be read as
    /// belonging to this one.
    public static func resetDiagnostics() { diagnosticsLock.withLock { unsafe _diagnostics = Diagnostics() } }
    private static func recordDroppedFrame() { diagnosticsLock.withLock { unsafe _diagnostics.framesDropped += 1 } }

    /// **A complete account, not a partial one — Task 5.5's own counters needed three fix rounds
    /// to reach this bar and this one is written against that standard from the start.**
    /// `framesDropped` increments at exactly the two places `startRequest` below can fail to
    /// produce a composed frame for a composition time AVFoundation asked for — there is no third:
    ///
    ///   1. **The leading `guard` in `startRequest`.** Any of `request.sourceTrackIDs.first`,
    ///      `request.sourceReadOnlyPixelBuffer(byTrackID:)`, `renderContext`,
    ///      `context.newPixelBuffer()`, or `Self.renderer` being absent takes this branch. In
    ///      correctly wired playback the first two are supplied by AVFoundation and the third and
    ///      fifth are configured before playback ever starts (`StageWindow.load()`), so the
    ///      realistic way this fires during a REAL run is `context.newPixelBuffer()` returning
    ///      `nil` — `AVVideoCompositionRenderContext`'s own pixel-buffer pool can be exhausted
    ///      under real memory/GPU pressure during live, real-time playback. This is the shape "the
    ///      preview path may drop" names: a busy system genuinely failing to hand back a
    ///      destination buffer for one composition time, with no error of this app's own making.
    ///   2. **The `catch` around `renderer.render(_:source:into:)`.** A thrown render error —
    ///      `CoreImageFrameRenderer.render` does not throw today (structurally required by the
    ///      `FrameRendering` protocol's `throws`, the same "compiles-required, not yet exercised"
    ///      shape `MasterWriter.swift`'s own `do`/`catch` documents), but a future renderer
    ///      (Task 3's open Metal seam) legitimately could.
    ///
    /// Both branches call `request.finish(with:)` with an error instead of
    /// `request.finish(withComposedPixelBuffer:)` — AVFoundation receives no frame for that
    /// composition time either way, and these are the ONLY two `finish` calls in this file that do
    /// not carry a composed buffer. **Shared by preview and export alike**, because both consumers
    /// drive the same `StageCompositor` (`ARCHITECTURE.md` D8) — the export path additionally
    /// throws on its own `framesRead == framesWritten` mismatch (`MP4Exporter.swift`), so a drop
    /// there is never silent even without this counter; the preview path has no such check, which
    /// is the entire reason this counter exists.
    ///
    /// **What this counter cannot see, named rather than left implicit — code review (Task 8, fix
    /// round 1), Important finding 5.** `startRequest` is the compositor's own boundary, not the
    /// preview's. Two real drop sources a viewer of a live `AVPlayer` preview would actually notice
    /// never reach this file at all, because they happen on either side of it:
    ///
    ///   - **`AVPlayer` display-time drops.** `AVPlayerItemAccessLogEvent.numberOfDroppedVideoFrames`
    ///     — a real, documented counter — is `AVPlayer`'s own account of frames it decoded or
    ///     composited but then discarded before display, under playback-rate or rendering pressure.
    ///     Nothing here reads it.
    ///   - **Seek-cancelled requests.** `AVVideoCompositing` conformances may implement
    ///     `cancelAllPendingVideoCompositionRequests()` to be told a pending `startRequest` was
    ///     abandoned because the user scrubbed past it. `StageCompositor` implements no such
    ///     method (grepped, absent) — a cancelled request is neither finished with a composed
    ///     buffer nor finished with an error, so it increments nothing here and nothing else in
    ///     this app either.
    ///
    /// So `framesDropped` answers "how many times did the COMPOSITOR itself fail to produce a
    /// frame for a request it received" — a real, narrower question than "how many frames did the
    /// preview visibly skip". A `framesDropped == 0` preview session can still have visibly
    /// stuttered or skipped ahead on a scrub, and this counter would not know.
    public struct Diagnostics: Sendable {
        public internal(set) var framesDropped = 0
    }

    public let sourcePixelBufferAttributes: [String: any Sendable]? =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    private nonisolated(unsafe) var renderContext: AVVideoCompositionRenderContext?

    /// Guards `pointerTrack`/`clickTrack`/`tracksLoaded` below — **not** `renderContext`, which
    /// stays the pre-existing unguarded `nonisolated(unsafe)` this file already had. That
    /// asymmetry is deliberate, not an inconsistency left behind: `renderContext` is
    /// write-once-then-read (`renderContextChanged` sets it before any `startRequest` can see it,
    /// and it is never mutated again), the same "published before any callback can see it" shape
    /// `Self.renderer`'s own comment already claims for the statics above. `pointerTrack`/
    /// `clickTrack`/`tracksLoaded` are different: `loadedTracks()` below is a check-then-set INSIDE
    /// the call `startRequest` makes on every frame — a read-modify-write on the hot path, not a
    /// one-time publish — and an unguarded read-modify-write racing another thread's write is a
    /// data race in the language sense, not merely a stale-value risk. Review round 2 of this task
    /// found this resting on "AVFoundation serialises `startRequest` per instance", a framework
    /// runtime guarantee no test, header or scan states — and asked for the assumption removed
    /// rather than documented, which is what this lock does.
    private nonisolated let lock = NSLock()

    /// Built lazily on the first `startRequest` and cached for the rest of this instance's life —
    /// "read once", per the brief. AVFoundation instantiates one `StageCompositor` per composition
    /// session (`CompositionBuilder` sets this type as `customVideoCompositorClass`, which
    /// AVFoundation itself instantiates — nothing in this app ever calls `StageCompositor()`), and
    /// `startRequest` is the earliest point any instance method runs, so there is no earlier hook
    /// to read the log from. `tracksLoaded` is separate from `pointerTrack`/`clickTrack` being
    /// non-`nil` because a log that fails to read (missing file, corrupt header) must still be
    /// "loaded" — tried once and given up on — rather than retried on every single frame of the
    /// render. One flag for both tracks because they come from the SAME read of the SAME file
    /// (`loadedTracks()` below) — two flags could disagree about whether the log had been tried.
    ///
    /// All three are `nonisolated(unsafe)`, like every mutable property `CaptureSession` and
    /// `InputObserver` hold behind their own `lock` — `unsafe` is honest, not a suppression:
    /// nothing here is protected by actor isolation, everything is protected by `lock`, and
    /// `withLock`'s closure is what actually keeps concurrent access safe.
    private nonisolated(unsafe) var pointerTrack: PointerTrack?
    private nonisolated(unsafe) var clickTrack: ClickTrack?
    /// The observation log header's `EpochAnchor`, cached with the tracks it came from — the origin
    /// that turns a composition time into the host clock the samples are stamped in. `nil` when the
    /// log had no header, which is the same "draw nothing" state as no log at all: without an origin
    /// there is no defensible way to place a sample on the timeline, and a guessed origin draws a
    /// pointer at a time nothing was observed. See `pointerPlacement(at:in:)`.
    private nonisolated(unsafe) var logAnchor: EpochAnchor?
    private nonisolated(unsafe) var tracksLoaded = false

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // `renderContext` is `nonisolated(unsafe)` for the reason its own declaration comment
        // gives: write-once-then-read, published before any `startRequest` callback can see it.
        // The `StrictMemorySafety` gate cannot see that shape from the property's type alone, so
        // this is the one write marked `unsafe` — a true statement about this specific call site,
        // not a suppression of one the shape doesn't actually hold.
        unsafe renderContext = newRenderContext
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // `Self.renderer` (published once, before playback starts — see its own declaration
        // comment) and `renderContext` (write-once-then-read, immediately above) are each read
        // here under that same "published before any callback can see it" guarantee, not under
        // `lock` — `lock` guards `pointerTrack`/`clickTrack`/`tracksLoaded`/`logAnchor` only, the
        // values `loadedTracks()` below actually mutates on the hot path.
        guard let trackID = request.sourceTrackIDs.first?.int32Value,
              let source = request.sourceReadOnlyPixelBuffer(byTrackID: trackID),
              let context = unsafe renderContext,
              let destination = context.newPixelBuffer(),
              let renderer = unsafe Self.renderer else {
            Self.recordDroppedFrame()
            request.finish(with: CompositorError.notConfigured)
            return
        }
        let basePlan = StagePlanner.plan(
            outputWidth: Int(context.size.width), outputHeight: Int(context.size.height),
            sourceWidth: source.size.width, sourceHeight: source.size.height,
            style: unsafe Self.style)
        let plan = RenderPlan(outputWidth: basePlan.outputWidth, outputHeight: basePlan.outputHeight,
                              card: basePlan.card, cornerRadius: basePlan.cornerRadius,
                              style: basePlan.style,
                              pointer: pointerPlacement(at: request.compositionTime, in: basePlan))
        do {
            // `source` is read-only, and `FrameRendering.render(_:source:into:)` — Task 3's seam —
            // asks for a plain `CVPixelBuffer`. `withUnsafeBuffer` is the one public bridge between
            // the two, scoped to this closure so nothing holds the unwrapped buffer past the call
            // that actually reads it.
            try source.withUnsafeBuffer { sourceBuffer in
                try renderer.render(plan, source: sourceBuffer, into: destination)
            }
            request.finish(withComposedPixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: destination))
        } catch {
            Self.recordDroppedFrame()
            request.finish(with: error)
        }
    }

    /// `Equatable`, added on the move so `theCompositorErrorIsDistinguishableFromAnotherError`
    /// (`StageCompositorTests.swift`) can write `error as? CompositorError == .notConfigured`
    /// rather than pattern-matching by hand — the single-case enum this file declared through
    /// Task 3 had no need of `==` because nothing outside AVFoundation's own `finish(with:)` call
    /// ever compared two of these.
    public enum CompositorError: Error, Equatable { case notConfigured }

    // MARK: - the pointer track

    /// `.drawn(p)` becomes a placement in `plan`'s own output-pixel space, carrying whatever ripple
    /// phase `ClickTrack` reports at the same instant; every other reading — `.blind`,
    /// `.suppressedByReviewer`, `.noObservationYet` — draws no pointer AND no ripple: there is no
    /// cursor location to radiate one from, so the ripple question does not arise independently of
    /// the pointer one.
    ///
    /// **This is a four-case `switch`, not an `if let` over two.** `PointerTrack.position(at:)`
    /// returns a four-case `PointerReading` precisely so a caller cannot collapse "a gap that was
    /// measured", "a reviewer's decision" and "before the first sample" into one absence — see
    /// that type's own header. Naming all four cases here (rather than `default: return nil`) is
    /// what makes a FIFTH case added later a compile error at this call site instead of a silent
    /// fall-through.
    /// **The one deliberate widening in this move, and the reason it is spent here rather than
    /// somewhere else.** `startRequest(_:)` above takes an `AVAsynchronousVideoCompositionRequest`,
    /// a type only AVFoundation can construct — no `swift test` test can call it, so before this
    /// change nothing `swift test` ran could reach the two lines that matter most in this file:
    /// the read of `Self.observationLogURL`/`Self.overrides` and the composition-time →
    /// host-clock conversion this function's own body comments at length.
    /// `pointerPlacement(at:in:)` is where the log, the anchor and that conversion actually meet,
    /// and unlike `startRequest` it takes only a `CMTime` and a `RenderPlan` — both constructible
    /// in a test with no AVFoundation cooperation at all. Making it `public` is what makes it the
    /// seam `swift test` reaches; `startRequest` stays the seam it cannot, and the AVFoundation
    /// glue immediately around it (the leading `guard`, the render call, `request.finish`)
    /// remains covered only by the cross-boundary probe and by a person watching a preview,
    /// exactly as before this move. Task 6 depends on this being public: it is where a wrong
    /// composition-time→host-clock conversion — the exact defect commit `1a98402` left uncaught
    /// for a full phase — would be caught by `swift test` rather than by someone recording four
    /// seconds and looking.
    ///
    /// **Reachable is not yet exercised — code review, fix round 1.** This commit makes the
    /// conversion reachable; it does not yet cover it. `StageCompositorTests.swift`'s
    /// `noConfiguredLogPlacesNoPointer` — the only `swift test` test that calls this function
    /// today — returns at the `guard let pointer, let anchor` below, before the offset-plus-
    /// anchor conversion and the four-case `switch` ever run. Zero `swift test` coverage reaches
    /// past that guard as of this commit. Closing that gap, against a real observation log, is
    /// Task 6's job, not this one's.
    ///
    /// A method on an already-`public` type is the entry rule's known free-entry gap (see this
    /// task's own design note): a type admitted for one member does not require every member to
    /// earn its own admission independently. This is that gap being used deliberately, once, for
    /// the reason above — not a precedent for widening anything else in this file without a
    /// caller (a real one, or `swift test`) that needs it.
    public func pointerPlacement(at compositionTime: CMTime,
                                 in plan: RenderPlan) -> NormalizedPointerPlacement? {
        guard compositionTime.isValid,
              let offset = Nanoseconds(rationalSeconds: compositionTime.value,
                                       timescale: compositionTime.timescale) else { return nil }
        let (pointer, click, anchor) = loadedTracks()
        guard let pointer, let anchor else { return nil }
        // THE CONVERSION THIS FILE'S OWN `import Timeline` COMMENT NAMES, AND THE ONE THAT WAS
        // MISSING. `compositionTime` is relative to the start of the composition — 0 at the first
        // frame. Every record in the observation log is stamped in the ABSOLUTE host clock
        // (`mach_absolute_time`'s domain, ~537,337 s of uptime on the machine this was first
        // measured on). Passing the composition offset straight to `position(at:)` compared a
        // number in the billions against samples in the hundreds of trillions, so
        // `sample.instant.hostTime <= time` was false for every sample of every recording:
        // `.noObservationYet` always, and NO POINTER WAS EVER DRAWN BY ANY BUILD OF THIS APP.
        //
        // The conversion goes this way — offset PLUS anchor, into the host clock — and not the
        // other way, rebasing the samples down into composition time, for two reasons. The
        // samples' domain is the one the rest of the project attributes in: `MasterSegment`'s
        // `hostRange` decides which segment a record belongs to by host time (D5a), so a track
        // rebased into composition time could no longer be checked against it. And the earliest
        // sample of the recording this was found on sits 81 ms BEFORE the anchor — rebasing makes
        // legitimate observations negative, which is representable (`Nanoseconds.rawValue` is
        // `Int64`) but means every consumer must then reason about a timeline that starts before
        // zero. Adding is the direction with no such edge.
        //
        // `anchor` is the log header's `EpochAnchor`, whose own doc calls it "rough placement": it
        // is the writer's mark for the segment's beginning, not a frame-accurate media origin. On
        // the first recording measured through this path, observations ran from anchor − 0.081 s to
        // anchor + 3.648 s inside a 4.150 s master, so the gross alignment holds and any residual
        // is bounded well under a tenth of a second. That is the accuracy this claims. A pointer
        // drawn a frame or two early is a different, much smaller defect than one never drawn.
        let time = anchor.hostTime + offset
        switch pointer.position(at: time) {
        case .drawn(let point):
            return StagePlanner.placement(for: point, in: plan, ripplePhase: click?.ripplePhase(at: time))
        case .blind, .suppressedByReviewer, .noObservationYet:
            return nil
        }
    }

    /// Reads `Self.observationLogURL` at most once per instance and caches both tracks it builds
    /// from that one read — success or failure alike, so a log this instance could not read is not
    /// retried on every frame. `Self.overrides` is read here too, at the same "once" moment, for
    /// the same reason `observationLogURL` is: both are configuration a caller sets before playback
    /// starts, not values that change frame to frame.
    ///
    /// **The check and the set are ONE critical section, not two.** `if tracksLoaded { … };
    /// tracksLoaded = true; …` — the shape this had before this lock existed — lets two threads
    /// both observe `tracksLoaded == false` and both perform the load: each would decode the log
    /// independently and each would write its own `pointerTrack`/`clickTrack`, the last writer
    /// winning. That duplicate work is idempotent here (`buildTracks` is a pure function of the
    /// file's bytes, so either result is correct), which is WHY a coarser lock — covering the
    /// check, the read, the decode and the write together — is the right trade rather than a
    /// narrower one that only protects the flag: idempotent redundancy is an acceptable cost, a
    /// half-written cache is not, and the simplest way to guarantee the latter never happens is to
    /// make the whole sequence one section. The file read itself is bounded, one-time, per-instance
    /// I/O — not a per-frame cost — so serialising concurrent callers through it while it happens
    /// is a one-time price, not a standing tax on every frame; every frame AFTER the first returns
    /// from the cache in O(1) under the same lock.
    ///
    /// **This lock is never held across `renderer.render(_:source:into:)`.** That call — which
    /// `CoreImageFrameRenderer`'s own header notes can cost milliseconds — happens in `startRequest`
    /// AFTER this function has already returned and released `lock`; nothing here reaches into it.
    private func loadedTracks() -> (pointer: PointerTrack?, click: ClickTrack?, anchor: EpochAnchor?) {
        // Every access to `tracksLoaded`/`pointerTrack`/`clickTrack`/`logAnchor` below runs inside
        // `lock.withLock` — this function's whole reason for existing, per its own header above.
        // `Self.observationLogURL`/`Self.overrides` are read once here too, under the SAME
        // guarantee `Self.renderer`/`Self.style` rest on in `startRequest` (published before
        // playback starts, never mutated afterward) rather than under `lock` — `lock` protects
        // this instance's cached tracks, not that shared configuration. `unsafe` at each site below
        // states which of those two guarantees applies to it; neither is a suppression of a race
        // this file actually has.
        lock.withLock {
            if !(unsafe tracksLoaded) {
                unsafe tracksLoaded = true
                if let url = unsafe Self.observationLogURL,
                   let built = try? Self.buildTracks(from: url, overrides: unsafe Self.overrides) {
                    unsafe pointerTrack = built.pointer
                    unsafe clickTrack = built.click
                    unsafe logAnchor = built.anchor
                }
            }
            return unsafe (pointerTrack, clickTrack, logAnchor)
        }
    }

    /// Turns one observation log into a `PointerTrack` and a `ClickTrack`, in one pass over the
    /// file: `"pointer"` records become the `PointerTrack`'s samples; `"secureInput"` and
    /// `"tapDisabled"` records — the two kinds this log carries for `GapSite.secureInput`/
    /// `.tapDisabled` (`ObservationLog`'s own "what a record may contain") — become its
    /// `BlindInterval`s, each from that record's own `HostRange`, untouched; `"button"` records
    /// become the `ClickTrack`'s events (`ClickTrack.init` itself keeps only the `.down` ones).
    ///
    /// **`overrides` is taken as a parameter, not read from the log.** `CursorOverride` is, by its
    /// own header, "a reviewer's permanent decision" — a project-level judgement call, not a fact
    /// the observation log records. This app has no reviewer UI or persisted-override storage yet,
    /// so `Self.overrides` (above) is the only source for now and defaults to `[]`; when a
    /// reviewer UI exists, it sets that static the same way `StageWindow.load()` already sets
    /// `renderer` and `style`, and nothing about this function's own shape needs to change.
    private static func buildTracks(from url: URL, overrides: [CursorOverride]) throws
        -> (pointer: PointerTrack, click: ClickTrack, anchor: EpochAnchor?) {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var samples: [PointerSample] = []
        var blindIntervals: [BlindInterval] = []
        var buttonEvents: [ButtonEvent] = []
        var anchor: EpochAnchor?
        for line in lines {
            switch try ObservationLog.kind(of: line) {
            case "logHeader":
                anchor = (try ObservationLog.decode(line) as ObservationLogHeader).anchor
            case "pointer":
                samples.append(try ObservationLog.decode(line) as PointerSample)
            case "button":
                buttonEvents.append(try ObservationLog.decode(line) as ButtonEvent)
            case "secureInput":
                let interval = (try ObservationLog.decode(line) as SecureInputInterval).interval
                blindIntervals.append(BlindInterval(start: interval.start, duration: interval.duration,
                                                    cause: .secureInput))
            case "tapDisabled":
                let interval = (try ObservationLog.decode(line) as TapDisabledInterval).interval
                blindIntervals.append(BlindInterval(start: interval.start, duration: interval.duration,
                                                    cause: .tapDisabled))
            default:
                break
            }
        }
        let pointer = PointerTrack(samples: samples, blindIntervals: blindIntervals, overrides: overrides)
        let click = ClickTrack(events: buttonEvents)
        return (pointer: pointer, click: click, anchor: anchor)
    }
}
