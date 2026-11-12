import Compositing
import Foundation
import Observation
import AVFoundation
import Framing
import Overlays
import Timeline

/// The editing surface: what survives, what was cut, and where the playhead is.
///
/// **Replaced two sliders.** Trim start and trim end could express one kept span and nothing
/// else — no cut in the middle, no seeing where a cut was made, no way to undo one. The model
/// underneath is `EditTimeline`, which expresses all three; this is where a person reaches it.
///
/// Everything here is in SOURCE time, because that is what the strip draws: the recording,
/// with the removed parts shown as gaps. Output time is what the player and the exporter
/// count in, and the two are equal only until the first cut — `EditTimeline` owns the
/// conversion and this view never does it by hand.
@Observable
final class TimelineEditorModel {
    /// The recording's full length. `nil` until the asset loads, which is why the strip is
    /// absent rather than drawn against a length of zero.
    private(set) var duration: Nanoseconds?
    /// Every edit goes through here, so ⌘Z is not a separate code path that has to be kept in
    /// step with the one that makes changes. `EditHistory` stores VALUES rather than inverse
    /// operations — see its header for why that is the right trade for an immutable model.
    ///
    /// **The clips and the zooms are one value in one history**, so ⌘Z steps back across both
    /// in the order they happened. Until 2026-10-23 the zooms were outside it, and ⌘Z after
    /// moving a zoom undid the clip edit before it — see `docs/design/2026-10-23-undoing-a-zoom.md`.
    private var history = EditHistory<TimelineEdits>(TimelineEdits(timeline: EditTimeline(clips: []), zooms: []))
    /// What a drag in progress is showing. **Held outside the history on purpose**: a trim is
    /// one edit a person makes, not one per pixel their cursor travelled, and recording every
    /// intermediate value would make ⌘Z undo a pixel. Committed once on release.
    private var liveEdit: EditTimeline?
    var edit: EditTimeline { liveEdit ?? history.current.timeline }
    /// The edit as last recorded, without a drag in progress — what the preview's asset is cut
    /// by, so it is rebuilt when a step lands and not on every frame of a trim.
    var committedEdit: EditTimeline { history.current.timeline }
    /// Where the playhead sits, in SOURCE time — a `SourceTime`, so a site that treats it as
    /// output time does not compile (`docs/design/2026-11-09-two-clocks-two-types.md`).
    private(set) var playhead = SourceTime.zero

    // MARK: - the export range

    /// Where an export of part of the video begins and ends, in OUTPUT time — see `ExportMarks`.
    private(set) var marks = ExportMarks()
    var inPoint: Nanoseconds? { marks.inPoint }
    var outPoint: Nanoseconds? { marks.outPoint }

    /// The range an export should cover, in OUTPUT time, or `nil` for the whole video.
    var exportRange: Range<Int64>? { marks.range(outputDuration: edit.outputDuration) }

    /// The timeline an export should render — the edit, restricted to the range if there is one.
    ///
    /// **The preview keeps playing the whole video.** A range is a choice about one export, not
    /// an edit to the project: hiding the rest of the recording the moment somebody marks a
    /// section would make it impossible to check the section against what surrounds it.
    var editForExport: EditTimeline {
        guard let range = exportRange else { return edit }
        return edit.restricted(toOutput: range) ?? edit
    }

    /// What the export will write, in SOURCE time, for drawing on the strip — or `nil` for the
    /// whole video.
    ///
    /// **Read off `editForExport`, the timeline the exporter renders**, rather than converted a
    /// second way that could disagree with it. The range itself is output time, and drawn as
    /// though it were source time it lands late by everything cut before it.
    var exportRangeInSource: Range<Int64>? {
        guard exportRange != nil, let first = editForExport.clips.first,
              let last = editForExport.clips.last else { return nil }
        return first.sourceStart.rawValue..<last.sourceEnd.rawValue
    }

    /// Marks the in point at the playhead, or clears it if it is already there.
    ///
    /// **The playhead is SOURCE time and a mark is OUTPUT time**, so it converts. Until
    /// 2026-10-23 it did not: with three seconds cut earlier, I exported from three seconds after
    /// the playhead. A playhead inside a cut marks nothing — there is no frame of the video there
    /// to point at, and the nearest kept frame either side is a side nobody chose.
    func markIn() {
        guard let output = edit.outputTime(atSource: playhead) else { return }
        marks.markIn(at: output.nanoseconds)
    }

    func markOut() {
        guard let output = edit.outputTime(atSource: playhead) else { return }
        marks.markOut(at: output.nanoseconds)
    }

    func clearExportRange() {
        marks.clear()
    }

    /// Bumped only when a PERSON moved the playhead, and what the preview seeks on.
    ///
    /// **Playback has to be able to move the playhead without moving the player.** The seek used
    /// to key on `playhead` itself, which was fine while the only thing that wrote it was a
    /// drag — and the moment playback started writing it too, every tick would have seeked the
    /// player to where the player already was, several times a second, for the whole recording.
    /// A counter separates "somebody asked to go there" from "that is where we are".
    private(set) var seekRequest = 0

    /// Plays the recording under the playhead while it is being dragged. Silent until a
    /// recording is opened, and silent for a recording with no audio.
    let scrubAudio = ScrubAudio()
    /// What a deliberate move is heard through: `scrubAudio`, unless a test is listening.
    private let scrub: (Nanoseconds) -> Void

    init(scrubbingThrough scrub: ((Nanoseconds) -> Void)? = nil) {
        if let scrub {
            self.scrub = scrub
        } else {
            let audio = scrubAudio
            self.scrub = { audio.scrub(to: $0) }
        }
    }

    /// A person put the playhead here. Seeks the preview.
    ///
    /// **The sound is played from here rather than from the drag gesture**, because this is the
    /// one function every deliberate move goes through — a drag, a tap on the ruler, a keyboard
    /// nudge. `followPlayer` is the other writer and is deliberately not here: it is playback
    /// moving the line, and playing a grain over the audio already playing would be an echo.
    func movePlayhead(to time: SourceTime) {
        playhead = time
        seekRequest += 1
        // The playhead is already the recording's clock, which is what `ScrubAudio` reads.
        // Until 2026-10-23 it was converted as though it were output time, and after a cut the
        // scrub played whatever lay that far further on.
        scrub(time.nanoseconds)
    }

    /// The preview is here. Moves the line and nothing else.
    ///
    /// **Without this the playhead did not move during playback at all** — the line sat where it
    /// was last dragged while the picture ran on, so the one surface that says WHEN things
    /// happen could not say when NOW was.
    func followPlayer(outputTime: OutputTime) {
        guard let source = edit.sourceTime(atOutput: outputTime) else { return }
        playhead = source
    }

    /// The span a person has dragged out, in SOURCE time, or `nil` for no selection.
    var selection: Range<Int64>?
    /// The clip a person clicked, or `nil`. **Kept as an identity, never an index**: deleting
    /// an earlier clip would silently move an index onto a different clip, which is the fault
    /// `ClipID` exists to prevent.
    private(set) var selectedClip: ClipID?
    /// Kept so "Undo all edits" restores the recording rather than guessing at it. Still a
    /// separate value from the history's floor: reverting is one step a person can undo, not
    /// an unwinding of every step they made.
    private var original = EditTimeline(clips: [])
    /// Carried across the events of one drag so a snap holds instead of flickering.
    private var snapState = SnapEngine.State()
    /// One envelope per recorded audio track, in the master's order — system audio, then the
    /// microphone. Empty until read, and empty for a recording with no audio.
    private(set) var trackWaveforms: [WaveformEnvelope] = []

    /// **Where a snap has taken hold, or `nil`.** A snap nobody can see is a snap nobody
    /// trusts: an edge that jumps a few pixels reads as the drag being imprecise rather than as
    /// the editor helping. Drawing the line it snapped to is the difference between a feature
    /// and an unexplained twitch.
    private(set) var snapIndicator: Nanoseconds?
    /// The recording's audio, for drawing. `nil` until it has been read, and empty when the
    /// recording has no audio — two different things, and the strip shows nothing for both.
    private(set) var waveform: WaveformEnvelope?
    /// What part of the recording the strip is showing. **Every position on the strip goes
    /// through this**, so a zoomed view cannot have one conversion for clips and another for
    /// the playhead — see `TimelineWindow` for why that is worth a type.
    /// `private(set)` and not private: the toolbar reads `visible` to say how much of the
    /// recording is on screen, which is the readout that makes a zoom control legible.
    private(set) var window = TimelineWindow.whole(Nanoseconds(0))
    /// The zooms the gate derived, before anyone touched them.
    private(set) var derivedZooms: [ZoomBlock] = []
    /// What a person changed about them. Published to the compositor, like every other
    /// authored value here. A drag shows `liveZooms` until it is let go, as a trim shows
    /// `liveEdit`.
    var zoomAdjustments: [ZoomAdjustment] { liveZooms ?? history.current.zooms }
    private var liveZooms: [ZoomAdjustment]?
    /// The zoom a person is holding, so the lane can show it differently while it moves.
    private(set) var draggingZoom: HostInstant?
    /// Derived, then adjusted — the order IS the producer-value rule.
    var zooms: [ZoomBlock] { zoomAdjustments.applied(to: derivedZooms) }

    /// The recording's epoch anchor — what turns a zoom block's ABSOLUTE host instant into an
    /// offset from the start of the video.
    ///
    /// **Without it the zoom lane drew every block off the right-hand edge.** A `ZoomBlock`'s
    /// `start` is a `HostInstant`: nanoseconds since the machine booted, which for a Mac that
    /// has been awake a week is a number around 6×10¹⁴. The strip's window runs 0…duration. The
    /// lane fed one to the other and got a fraction in the hundreds of thousands, so the blocks
    /// existed, were correct, and were drawn several kilometres to the right of the screen.
    ///
    /// The blocks themselves stay absolute: `ZoomAdjustment` is keyed on `ZoomBlock.origin` so
    /// that a person's correction survives the plan being re-derived, and rewriting the instants
    /// to offsets here would break that key. The conversion belongs at the point of drawing.
    private(set) var zoomAnchor: EpochAnchor?

    /// How far into the recording `instant` falls, or `nil` when it belongs to another boot
    /// session — the epoch check every consumer of an absolute instant makes.
    func offset(of instant: HostInstant) -> Nanoseconds? {
        zoomAnchor.flatMap { FramingPlanReader.offset(of: instant, from: $0) }
    }

    /// How fast the camera moves — the editor's choice, handed in so the lane's curve is baked at
    /// the pace the render uses. `StageWindow` keeps it in step with `EditorViewModel.cameraPace`.
    var cameraPace = CameraPace.standard

    /// The camera's depth across the visible window, one value per column, 0 at rest and 1 at
    /// the deepest zoom in view — what `ZoomCurve` draws. Empty without an anchor, without a
    /// zoom, or without columns. See `CameraMotion.zoomProfile` and
    /// `docs/design/2026-10-25-the-zoom-lane-draws-the-camera.md`.
    func zoomCurve(columns: Int) -> [Double] {
        guard let zoomAnchor, columns > 0, !zooms.isEmpty else { return [] }
        let depths = camera.zoomProfile(from: zoomAnchor.instant(atOffset: window.start),
                                        to: zoomAnchor.instant(atOffset: window.start + window.visible),
                                        columns: columns)
        guard let deepest = depths.max(), deepest > CameraMotion.identityZoomBound else {
            return depths.map { _ in 0 }
        }
        return depths.map { ($0 - 1) / (deepest - 1) }
    }

    /// The camera baked from the zooms as they stand, kept until the zooms or the pace change —
    /// a bake integrates the whole recording, and the lane asks on every redraw of a drag.
    private var camera: CameraMotion {
        let key = CameraKey(zooms: zooms, pace: cameraPace)
        if let cachedCamera, cachedCamera.key == key { return cachedCamera.motion }
        let motion = CameraMotion(blocks: zooms, pace: cameraPace)
        cachedCamera = (key, motion)
        cameraBakes += 1
        return motion
    }

    private struct CameraKey: Equatable {
        let zooms: [ZoomBlock]
        let pace: CameraPace
    }
    @ObservationIgnored private var cachedCamera: (key: CameraKey, motion: CameraMotion)?
    /// How many times the camera has been baked — so a test can tell a cache hit from a re-bake.
    @ObservationIgnored private(set) var cameraBakes = 0

    func setZoomAnchor(_ anchor: EpochAnchor?) {
        zoomAnchor = anchor
    }

    /// Hands the lane the zooms the gate derived. Called when the plan is read; the
    /// adjustments survive, because they are keyed on the click rather than on the block.
    func setDerivedZooms(_ blocks: [ZoomBlock]) {
        derivedZooms = blocks
        publish()
    }

    // MARK: - zoom lane

    /// Shows a zoom being moved, without committing it. Either end lines up with what is near
    /// it within `snapThreshold` — zero to place it freely.
    func previewZoomMove(_ origin: HostInstant, byNanoseconds delta: Int64,
                         snapThreshold: Nanoseconds = Nanoseconds(0)) {
        // From what was committed, not from the last frame — a drag cannot accumulate rounding.
        let base = history.current.zooms
        draggingZoom = origin
        let edges = zoomEdges(of: origin, in: base)
        let snapped = snappedDelta(moving: edges, by: delta, threshold: snapThreshold,
                                   zoomsFrom: base, excludingZoom: origin)
        let held = clamped(snapped, of: origin, in: base, start: true, end: true)
        liveZooms = base.replacing(base.adjustment(for: origin).movedBy(held))
    }

    /// Shows a zoom's end being dragged, its end lining up as a trim's does.
    func previewZoomResize(_ origin: HostInstant, byNanoseconds delta: Int64,
                           snapThreshold: Nanoseconds = Nanoseconds(0)) {
        let base = history.current.zooms
        draggingZoom = origin
        let edges = zoomEdges(of: origin, in: base).suffix(1)
        let snapped = snappedDelta(moving: Array(edges), by: delta, threshold: snapThreshold,
                                   zoomsFrom: base, excludingZoom: origin)
        let held = clamped(snapped, of: origin, in: base, start: false, end: true)
        liveZooms = base.replacing(base.adjustment(for: origin).resizedBy(held))
    }

    /// Shows a zoom's START being dragged while its end stays where it is.
    ///
    /// `ZoomAdjustment` moves the whole block with `startDelta` and the end alone with
    /// `endDelta`, so a start that moves by `d` is a move by `d` and an end pulled back by the
    /// same `d`. **A start dragged past the end is "no zoom here"**, for the reason
    /// `ZoomAdjustment.applied(to:)` gives for an end dragged past the start.
    func previewZoomResizeStart(_ origin: HostInstant, byNanoseconds delta: Int64,
                                snapThreshold: Nanoseconds = Nanoseconds(0)) {
        let base = history.current.zooms
        draggingZoom = origin
        let edges = zoomEdges(of: origin, in: base).prefix(1)
        let snapped = snappedDelta(moving: Array(edges), by: delta, threshold: snapThreshold,
                                   zoomsFrom: base, excludingZoom: origin)
        let held = clamped(snapped, of: origin, in: base, start: true, end: false)
        liveZooms = base.replacing(base.adjustment(for: origin).movedBy(held).resizedBy(-held))
    }

    /// `delta`, stopped where the zoom would run into its neighbour.
    ///
    /// **Stopped rather than refused**, the trim's rule: the part of a drag that was legal stays
    /// on screen. Two adjusted zooms that overlapped would aim the camera at whichever it
    /// reached first, a state derivation never produces — `ZoomBlock.blocks` merges overlaps.
    /// A switched-off zoom is not in the way: it is not drawn into the picture.
    private func clamped(_ delta: Int64, of origin: HostInstant, in adjustments: [ZoomAdjustment],
                         start movesStart: Bool, end movesEnd: Bool) -> Int64 {
        let edges = zoomEdges(of: origin, in: adjustments)
        guard edges.count == 2 else { return delta }
        let (start, end) = (edges[0].rawValue, edges[1].rawValue)
        let others = adjustments.applied(to: derivedZooms)
            .filter { $0.origin != origin }
            .compactMap { block -> (Int64, Int64)? in
                guard let s = offset(of: block.start), let e = offset(of: block.end) else { return nil }
                return (s.rawValue, e.rawValue)
            }
        var held = delta
        if movesStart, let previous = others.filter({ $0.1 <= start }).map(\.1).max() {
            held = max(held, previous - start)
        }
        if movesEnd, let next = others.filter({ $0.0 >= end }).map(\.0).min() {
            held = min(held, next - end)
        }
        return held
    }

    /// A zoom's start and end in source time under `adjustments`, or none when it cannot be
    /// placed on this recording's clock.
    private func zoomEdges(of origin: HostInstant, in adjustments: [ZoomAdjustment]) -> [Nanoseconds] {
        guard let block = adjustments.applied(to: derivedZooms).first(where: { $0.origin == origin }),
              let start = offset(of: block.start), let end = offset(of: block.end) else { return [] }
        return [start, end]
    }

    /// **`delta`, corrected so one of `edges` lands on a clip edge, a zoom edge or the playhead**
    /// within `threshold` — through `SnapEngine`, the one snapping rule the range selection
    /// already uses, so a trim, a zoom and a selection line up by the same rule and hold the
    /// same way. The dragged thing's own edges are not targets; see `SnapEngine.targets`.
    private func snappedDelta(moving edges: [Nanoseconds], by delta: Int64, threshold: Nanoseconds,
                              in timeline: EditTimeline? = nil, zoomsFrom adjustments: [ZoomAdjustment]? = nil,
                              excludingZoom: HostInstant? = nil) -> Int64 {
        guard let first = edges.first, threshold.rawValue > 0 else {
            snapIndicator = nil
            return delta
        }
        let zoomEdges = (adjustments ?? zoomAdjustments).applied(to: derivedZooms)
            .filter { $0.origin != excludingZoom }
            .flatMap { block in [offset(of: block.start), offset(of: block.end)].compactMap { $0 } }
        let targets = SnapEngine.targets(in: timeline ?? edit, playhead: playhead.nanoseconds,
                                         zoomEdges: zoomEdges, excluding: Set(edges))
        let probes = edges.map { Nanoseconds($0.rawValue - first.rawValue) }
        guard let result = SnapEngine.snap(position: Nanoseconds(first.rawValue + delta),
                                           probeOffsets: probes, targets: targets,
                                           state: &snapState, threshold: threshold) else {
            snapIndicator = nil
            return delta
        }
        snapIndicator = result.time
        return result.time.rawValue - result.probeOffset.rawValue - first.rawValue
    }

    /// What a zoom drag did, which is what its undo step is called.
    enum ZoomDrag: Sendable { case move, resizeStart, resizeEnd }

    /// Commits the drag as ONE history step, for the same reason a trim does, or nothing if
    /// nothing moved. **The name is chosen here, from the kind of drag,** so it is a localised
    /// key like every other step's rather than a string the lane made up.
    func commitZoomDrag(_ drag: ZoomDrag) {
        defer {
            liveZooms = nil
            draggingZoom = nil
            endDrag()
        }
        guard let live = liveZooms else { return }
        switch drag {
        case .move:                   recordZooms("Move Zoom", live)
        case .resizeStart, .resizeEnd: recordZooms("Resize Zoom", live)
        }
    }

    func toggleZoomSuppressed(_ origin: HostInstant) {
        let current = zoomAdjustments.adjustment(for: origin)
        let toggled = zoomAdjustments.replacing(current.settingSuppressed(!current.suppressed))
        if current.suppressed {
            recordZooms("Turn Zoom On", toggled)
        } else {
            recordZooms("Turn Zoom Off", toggled)
        }
    }

    /// Whether a person has moved or resized this zoom, as distinct from the gate having derived
    /// it and nobody having touched it.
    ///
    /// **Suppression is not an adjustment for this purpose**, even though it is stored as one:
    /// a switched-off zoom is already drawn hollow, and marking it a second way would say the
    /// same thing twice while leaving the case that has no mark at all — a block somebody
    /// dragged, which looks exactly like a derived one the moment they let go.
    func isZoomAdjusted(_ origin: HostInstant) -> Bool {
        let adjustment = zoomAdjustments.adjustment(for: origin)
        return adjustment.startDelta.rawValue != 0 || adjustment.endDelta.rawValue != 0
    }

    func isZoomSuppressed(_ origin: HostInstant) -> Bool {
        zoomAdjustments.adjustment(for: origin).suppressed
    }

    var hasZoomEdits: Bool { !zoomAdjustments.isEmpty }

    /// Applies a saved edit. **`reset`, not `record`** — opening a project is not an edit to
    /// whatever was open before it, and a person must not be able to ⌘Z their way from one
    /// project into another.
    func restoreSavedEdit(_ saved: EditTimeline) {
        history.reset(to: history.current.with(timeline: saved))
        original = saved
        selection = nil
        selectedClip = nil
        publish()
    }

    /// The saved zoom corrections. **`reset`, not `record`**, for `restoreSavedEdit`'s reason —
    /// and it forgets the steps before it, which belonged to whatever was open.
    func restoreZoomAdjustments(_ adjustments: [ZoomAdjustment]) {
        history.reset(to: history.current.with(zooms: adjustments))
        publish()
    }

    func resetZooms() {
        recordZooms("Reset Zooms", [])
    }

    /// Reads the audio envelope off the main thread. Called once per recording; a failure
    /// leaves `waveform` nil, because a strip without a waveform is a smaller loss than an
    /// editor that refuses to open a recording whose audio it could not read.
    func loadWaveform(from asset: AVAsset) async {
        waveform = try? await WaveformEnvelope.read(from: asset)
        // **Per track as well as mixed**, because system audio and a microphone are two things
        // a person mixes separately — see `WaveformEnvelope.readPerTrack`. The mixed envelope
        // stays for the transport's level readout, which is about the output.
        trackWaveforms = (try? await WaveformEnvelope.readPerTrack(from: asset)) ?? []
    }

    func load(duration seconds: Double) {
        let total = Nanoseconds(Int64(seconds * 1_000_000_000))
        duration = total
        // `reset`, not `record`: opening a recording is not an edit to the one before it, and
        // a person must not be able to ⌘Z their way back into a different video. The zooms
        // stay: they arrive separately, and the host's order of calls depends on this keeping
        // them.
        history.reset(to: history.current.with(timeline: EditTimeline.whole(duration: total)))
        window = .whole(total)
        original = edit
        movePlayhead(to: .zero)
        selection = nil
        selectedClip = nil
        publish()
    }

    var hasEdits: Bool { edit != original }

    /// **What a project file stores: the edit, unless it is the whole recording.**
    ///
    /// Not `hasEdits`, and the difference lost cuts. `hasEdits` means "changed since this was
    /// OPENED" — right for the Edited label and for Revert, which go back to what was opened —
    /// and saving used it. A project opened with cuts has an `original` equal to those cuts, so
    /// `hasEdits` was false, the save wrote no timeline, and opening that file again showed the
    /// whole recording. Found by `EditorViewModelTests.aSavedProjectOpensExactlyAsItWasSaved`,
    /// 2026-09-27, the first time a save-then-open round trip was tested at all.
    var editToSave: EditTimeline? {
        guard let duration else { return hasEdits ? edit : nil }
        return edit == EditTimeline.whole(duration: duration) ? nil : edit
    }

    /// **Snapped to clip edges and the playhead.** A cut a person aims at an existing edge
    /// should land ON it: a cut that misses by a nanosecond leaves a sliver of a clip that is
    /// invisible on the strip and real in the export.
    func snapped(_ time: Nanoseconds, threshold: Nanoseconds) -> Nanoseconds {
        let targets = SnapEngine.targets(in: edit, playhead: playhead.nanoseconds)
        guard let result = SnapEngine.snap(position: time, targets: targets,
                                           state: &snapState, threshold: threshold) else {
            snapIndicator = nil
            return time
        }
        // The line is drawn at the TARGET, which is where the probe landed — not at `result.time`
        // plus the probe's offset, which is where the dragged thing's origin ended up. A clip
        // snapped by its trailing edge shows the line at that edge.
        snapIndicator = Nanoseconds(result.time.rawValue + result.probeOffset.rawValue)
        return result.time
    }

    // MARK: - silence

    /// The silent stretches the recording has, or empty until they are looked for.
    private(set) var silences: [SilenceFinder.Span] = []
    var silenceSettings = SilenceFinder.Settings.default

    /// **Found from the mixed envelope, not from one track.** A pause is a pause when NOTHING is
    /// making a sound; a stretch where the system is playing music and nobody is talking is not
    /// dead air, and cutting it would take the music with it.
    func findSilences() {
        guard let waveform, !waveform.isEmpty else {
            silences = []
            return
        }
        silences = SilenceFinder.spans(peaks: waveform.peaks,
                                       sliceSeconds: waveform.sliceDuration,
                                       settings: silenceSettings)
    }

    /// The still stretches, and how they were measured. Empty until somebody asks.
    private(set) var stillness: [StillnessFinder.Span] = []
    var stillnessSettings = StillnessFinder.Settings.default
    /// How far the measurement has got, 0…1, or `nil` when it is not running.
    private(set) var stillnessProgress: Double?

    /// Finds the stretches where the picture does not change, preferring what the recorder
    /// already wrote down (`PackageStillness`) to decoding the recording.
    ///
    /// **Asked for rather than run on open.** The decode reads the whole recording once — a few
    /// seconds for a few minutes of video — which is cheap enough to ask for and far too
    /// expensive to do to somebody who only wanted to trim the end.
    func findStillness(in url: URL) {
        guard stillnessProgress == nil else { return }
        let settings = stillnessSettings

        switch PackageStillness.answer(forMediaAt: url) {
        case .recorded(let intervals, let segments):
            // Instant, so no progress is shown — a bar that appears and vanishes
            // in one frame reads as a glitch, not as speed.
            stillness = RecordedStillness.spans(recorded: intervals, in: segments,
                                                settings: settings).spans
            return
        case .nothingWasEverStill:
            // A measurement, not an absence of one. Decoding would spend minutes
            // confirming what the recording already says.
            stillness = []
            return
        case .theRecordingDoesNotCarryIt:
            break
        }

        stillnessProgress = 0
        Task { @MainActor in
            let outcome = await StillnessReader.changes(contentsOf: url, sliceSeconds: 0.25) {
                fraction in Task { @MainActor in self.stillnessProgress = fraction }
            }
            stillnessProgress = nil
            guard case .changes(let changes) = outcome else {
                stillness = []
                return
            }
            stillness = StillnessFinder.spans(changes: changes, sliceSeconds: 0.25,
                                              settings: settings)
        }
    }

    /// Cuts every still stretch found. One undo step, because it is one decision.
    func removeStillness() {
        guard !stillness.isEmpty else { return }
        apply("Remove \(stillness.count) Still Span(s)",
              StillnessFinder.removing(stillness, from: edit))
        selection = nil
        selectedClip = nil
        // Already cut: offering them again would remove whatever moved into their place.
        stillness = []
    }

    /// Cuts every span found. One undo step, because it is one decision.
    func removeSilences() {
        guard !silences.isEmpty else { return }
        apply("Remove \(silences.count) Silent Span(s)",
              SilenceFinder.removing(silences, from: edit))
        selection = nil
        selectedClip = nil
        // The spans were positions in the SOURCE and the source has not changed, so they stay
        // valid — but they have already been cut, and offering to cut them again would remove
        // whatever moved into their place.
        silences = []
    }

    /// Ends a drag, so the next one starts unsnapped rather than inheriting a stale hold.
    func endDrag() {
        snapState = SnapEngine.State()
        snapIndicator = nil
    }

    /// Selects the clip at a SOURCE position, or clears the selection when the tap missed
    /// every clip — a tap on a cut span selects nothing rather than the nearest thing.
    func selectClip(atSource sourceTime: Nanoseconds) {
        selectedClip = edit.clip(atSource: sourceTime)?.id
    }

    /// The selected clip's speed, or `nil` when nothing is selected.
    var selectedSpeed: Double? {
        selectedClip.flatMap { id in edit.clips.first { $0.id == id }?.speed }
    }

    /// Plays the selected clip at `speed`.
    func setSelectedSpeed(_ speed: Double) {
        guard let id = selectedClip,
              let clip = edit.clips.first(where: { $0.id == id }), clip.speed != speed else {
            return
        }
        apply("Play at \(ClipChoices.speedLabel(speed))",
              EditTimeline(clips: edit.clips.map { $0.id == id ? $0.playing(at: speed) : $0 },
                           nextID: edit.nextID))
    }

    /// The selected clip's fades, or `nil` when nothing is selected.
    var selectedFades: (in: Double, out: Double)? {
        selectedClip.flatMap { id in
            edit.clips.first { $0.id == id }.map { ($0.fadeInSeconds, $0.fadeOutSeconds) }
        }
    }

    /// Fades the selected clip in, out, or both. `nil` leaves that end alone.
    func setSelectedFade(in fadeIn: Double? = nil, out fadeOut: Double? = nil) {
        guard let id = selectedClip,
              let clip = edit.clips.first(where: { $0.id == id }) else { return }
        let changed = clip.fading(in: fadeIn, out: fadeOut)
        guard changed != clip else { return }
        // Named for what a person will look for in the undo menu: they faded something, and
        // which end is the part they will be unsure about.
        apply(fadeIn != nil ? "Fade In" : "Fade Out",
              EditTimeline(clips: edit.clips.map { $0.id == id ? changed : $0 },
                           nextID: edit.nextID))
    }

    /// Cuts the selected clip in two at the playhead.
    ///
    /// **The playhead is in SOURCE time and `split` takes OUTPUT time**, so it converts —
    /// the two are equal only until the first cut, and a split that skipped the conversion
    /// would land somewhere else on every timeline that had already been edited.
    func splitAtPlayhead() {
        guard let output = edit.outputTime(atSource: playhead),
              let split = edit.split(atOutput: output.nanoseconds) else { return }
        apply("Split at Playhead", split)
    }

    var canSplitAtPlayhead: Bool {
        edit.outputTime(atSource: playhead).map { edit.split(atOutput: $0.nanoseconds) != nil } ?? false
    }

    /// Deletes the selected clip. The clips after it move earlier on their own — a clip's
    /// output position is the sum of the durations before it, so there is no gap to close.
    func deleteSelectedClip() {
        guard let selectedClip else { return }
        apply("Delete Clip", edit.removing(id: selectedClip))
        self.selectedClip = nil
    }

    func removeSelection() {
        guard let selection else { return }
        apply("Remove Selection", edit.removing(sourceRange: selection))
        self.selection = nil
    }

    /// **Removes a span of the recording named by something other than the timeline.**
    ///
    /// The transcript panel's one way in. `name` is the caller's because it becomes the undo
    /// title a person reads — "Delete \"So the first thing…\"" says what was deleted; a generic
    /// "Remove Selection" would leave them guessing which of five deletions they are undoing.
    ///
    /// **Undo is the restore.** A deleted sentence is not tracked as deleted anywhere: it goes
    /// through the same history every other edit does, so there is one way back and it is the
    /// one already in the menu.
    func removeSourceRange(_ range: Range<Int64>, named name: String) {
        guard range.upperBound > range.lowerBound else { return }
        record(name, edit.removing(sourceRange: range))
    }

    // MARK: - cut proposals

    /// The proposals a person said no to. Read by `CutReview.listing`, written only below.
    var dismissedCuts: Set<CutProposal.Key> { history.current.dismissedCuts }

    /// **A proposal becomes a cut here and nowhere else**, as an ordinary undoable edit named by
    /// the caller — "Cut 9.2 s After Step 4" says which of several acceptances ⌘Z will undo.
    func acceptCut(_ row: CutReview.Row, named name: String) {
        record(name, CutReview.accepting(row, in: edit))
    }

    /// Every listed proposal at once: one decision, so one undo step.
    func acceptCuts(_ rows: [CutReview.Row], named name: String) {
        guard !rows.isEmpty else { return }
        record(name, CutReview.acceptingAll(rows, in: edit))
    }

    /// A "no", recorded in the same history as the cuts, so ⌘Z brings the proposal back.
    func dismissCut(_ key: CutProposal.Key, named name: String) {
        guard !dismissedCuts.contains(key) else { return }
        history.record(name, history.current.with(dismissedCuts: dismissedCuts.union([key])))
        publish()
    }

    /// The saved dismissals. **`reset`, not `record`**, for `restoreSavedEdit`'s reason.
    func restoreDismissedCuts(_ keys: Set<CutProposal.Key>) {
        history.reset(to: history.current.with(dismissedCuts: keys))
        publish()
    }

    func keepOnlySelection() {
        guard let selection else { return }
        apply("Keep Only Selection", edit.trimmed(toSource: selection))
        self.selection = nil
    }

    func restore() {
        apply("Revert All Edits", original)
        selection = nil
        selectedClip = nil
    }

    // MARK: - zooming the strip

    func zoomStrip(by factor: Double, anchoredAtFraction anchor: Double) {
        window = window.zoomed(by: factor, anchoredAtFraction: anchor)
    }

    func scrollStrip(byFraction fraction: Double) {
        window = window.scrolled(byFraction: fraction)
    }

    func showWholeRecording() {
        window = .whole(window.total)
    }

    /// Brings the playhead back on screen after a keyboard nudge walked it off the edge.
    /// Nothing happens while it is already visible, so playback does not drag the view.
    func revealPlayhead() {
        window = window.revealing(playhead.nanoseconds)
    }

    // MARK: - trim handles

    /// Which edge of the selected clip a drag is holding.
    enum TrimEdge: Hashable, Sendable { case start, end }

    /// Shows what the trim would do, without committing it. Called continuously while the
    /// handle is held.
    ///
    /// **A trim the model refuses leaves the last legal state on screen** rather than
    /// snapping back or passing through: `EditTimeline.trimming` returns `nil` when a gesture
    /// has gone past the clip's own length, and the handle stopping is what that looks like.
    func previewTrim(of id: ClipID, edge: TrimEdge, byNanoseconds delta: Int64,
                     snapThreshold: Nanoseconds = Nanoseconds(0)) {
        let base = trimBaseline ?? history.current.timeline
        trimBaseline = base
        // The edge lines up with what is near it, against the timeline as the drag began.
        let moving = base.clips.first { $0.id == id }.map { edge == .start ? $0.sourceStart : $0.sourceEnd }
        let delta = snappedDelta(moving: moving.map { [$0] } ?? [], by: delta,
                                 threshold: snapThreshold, in: base)
        let updated = switch edge {
        case .start: base.trimming(id: id, startDelta: delta, endDelta: 0)
        case .end:   base.trimming(id: id, startDelta: 0, endDelta: delta)
        }
        if let updated { liveEdit = updated }
    }

    /// Commits the drag as ONE history step, or discards it if nothing moved.
    func commitTrim(edge: TrimEdge) {
        defer {
            liveEdit = nil
            trimBaseline = nil
            endDrag()
        }
        guard let live = liveEdit else { return }
        apply(edge == .start ? "Trim Clip Start" : "Trim Clip End", live)
    }

    /// The timeline a drag started from. Every intermediate value is computed from THIS rather
    /// than from the previous frame, so a drag cannot accumulate rounding — the handle ends up
    /// where the cursor is, not where a hundred small additions put it.
    private var trimBaseline: EditTimeline?

    // MARK: - undo

    /// How many steps can be undone — the mark an agent turn's checkpoint is taken at.
    var historyDepth: Int { history.depth }
    /// The name of the step ⌘Z would undo, as recorded rather than as the menu shows it.
    var undoStepName: String? { history.undoName }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    /// What a menu item should say. `nil` when there is nothing to undo, so the caller can
    /// disable rather than offer a verb with no object.
    var undoTitle: String? { history.undoName.map { String(localized: "Undo \($0)") } }
    var redoTitle: String? { history.redoName.map { String(localized: "Redo \($0)") } }

    func undo() {
        guard history.undo() != nil else { return }
        clearSelectionsThatNoLongerExist()
        publish()
    }

    func redo() {
        guard history.redo() != nil else { return }
        clearSelectionsThatNoLongerExist()
        publish()
    }

    /// One place every edit passes through, so the history cannot be bypassed by a new
    /// operation that forgets to record.
    ///
    /// **A `LocalizedStringResource`, so each call site's literal is a key** and its count an
    /// argument. The name ends up in the toolbar's "Undo …" tooltip as finished text, and while
    /// this took a `String` it was English there in every language.
    private func apply(_ name: LocalizedStringResource, _ updated: EditTimeline) {
        record(String(localized: name), updated)
    }

    /// For a name that arrives already localised — a caller outside this file built it.
    private func record(_ name: String, _ updated: EditTimeline) {
        history.record(name, history.current.with(timeline: updated))
        clearSelectionsThatNoLongerExist()
        publish()
    }

    /// The zoom twin of `apply`: one step, the clips unchanged.
    private func recordZooms(_ name: LocalizedStringResource, _ zooms: [ZoomAdjustment]) {
        history.record(String(localized: name), history.current.with(zooms: zooms))
        publish()
    }

    /// **A selection can outlive the clip it pointed at.** Undo past a split and the right
    /// half is gone; leaving the id selected would leave "Delete Clip" enabled with nothing to
    /// delete. The span selection is left alone — it is a range of the recording, which still
    /// exists whatever the edit did.
    private func clearSelectionsThatNoLongerExist() {
        if let selectedClip, !edit.clips.contains(where: { $0.id == selectedClip }) {
            self.selectedClip = nil
        }
    }

    /// Hands the edit to the compositor. It reads the observation log in SOURCE time and is
    /// given OUTPUT times, so without this every cursor and every zoom after a cut is placed
    /// by however much was removed before it. `MP4Exporter` refuses to export against an edit
    /// this static disagrees with, which is what keeps the two from drifting.
    private func publish() {
        StageCompositor.editTimeline = edit
        StageCompositor.zoomAdjustments = zoomAdjustments
    }
}

/// What one undo step holds: the clips and the person's zoom corrections, together, so one
/// history orders both. See `docs/design/2026-10-23-undoing-a-zoom.md`. `nonisolated` because
/// `EditHistory` needs its `Equatable` from any isolation, and the app's default is the main actor.
nonisolated struct TimelineEdits: Equatable, Sendable {
    var timeline: EditTimeline
    var zooms: [ZoomAdjustment]
    /// The cut proposals a person said no to. **In the same history as the cuts**, so ⌘Z after
    /// a dismissal brings the proposal back, and ⌘Z after an acceptance brings it back too — by
    /// restoring the span, which is what puts it back on the list (`CutReview`).
    var dismissedCuts: Set<CutProposal.Key> = []

    /// This value with one part replaced, so an edit to one part cannot drop another: every
    /// constructor call that named the parts one by one was a place a new part could be lost.
    func with(timeline: EditTimeline? = nil, zooms: [ZoomAdjustment]? = nil,
              dismissedCuts: Set<CutProposal.Key>? = nil) -> TimelineEdits {
        var next = self
        if let timeline { next.timeline = timeline }
        if let zooms { next.zooms = zooms }
        if let dismissedCuts { next.dismissedCuts = dismissedCuts }
        return next
    }
}
