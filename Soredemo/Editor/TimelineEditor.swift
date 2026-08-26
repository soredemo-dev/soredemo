import Compositing
import Foundation
import Observation
import AppKit
import AVFoundation
import Framing
import SwiftUI
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
    private var history = EditHistory<EditTimeline>(EditTimeline(clips: []))
    /// What a drag in progress is showing. **Held outside the history on purpose**: a trim is
    /// one edit a person makes, not one per pixel their cursor travelled, and recording every
    /// intermediate value would make ⌘Z undo a pixel. Committed once on release.
    private var liveEdit: EditTimeline?
    var edit: EditTimeline { liveEdit ?? history.current }
    /// Where the playhead sits, in SOURCE time.
    private(set) var playhead = Nanoseconds(0)

    // MARK: - the export range

    /// Where an export of part of the video begins and ends, in OUTPUT time. **Both `nil` is the
    /// ordinary case** — most exports are the whole video, and a range that defaulted to
    /// something would make every export a decision.
    ///
    /// ScreenKite's article about Screen Studio lacking this describes the workaround: duplicate
    /// the project, trim the copy, export, repeat. Once per section, with a fresh chance to trim
    /// the wrong edge each time.
    private(set) var inPoint: Nanoseconds?
    private(set) var outPoint: Nanoseconds?

    /// The range an export should cover, or `nil` for the whole video.
    ///
    /// **One end is enough.** An in point alone means "from here to the end" and an out point
    /// alone means "from the start to here", which is what those gestures mean in every editor
    /// that has them — requiring both would make the first keystroke do nothing.
    var exportRange: Range<Int64>? {
        let total = edit.outputDuration.rawValue
        guard total > 0, inPoint != nil || outPoint != nil else { return nil }
        let lower = max(inPoint?.rawValue ?? 0, 0)
        let upper = min(outPoint?.rawValue ?? total, total)
        guard lower < upper else { return nil }
        // The whole video is not a range: an in point dragged back to zero has been cancelled,
        // and reporting a range there would put "1 of 1 sections" in the export sheet forever.
        guard lower > 0 || upper < total else { return nil }
        return lower..<upper
    }

    /// The timeline an export should render — the edit, restricted to the range if there is one.
    ///
    /// **The preview keeps playing the whole video.** A range is a choice about one export, not
    /// an edit to the project: hiding the rest of the recording the moment somebody marks a
    /// section would make it impossible to check the section against what surrounds it.
    var editForExport: EditTimeline {
        guard let range = exportRange else { return edit }
        return edit.restricted(toOutput: range) ?? edit
    }

    /// Sets the in point to the playhead, or clears it if it is already there.
    ///
    /// **Pressing the key again cancels**, which is how a person undoes a mark without reaching
    /// for a menu. Clearing an out point that now sits before the in point too: leaving a pair
    /// that selects nothing would make the export silently fall back to the whole video.
    func markIn() {
        if inPoint == playhead { inPoint = nil; return }
        inPoint = playhead
        if let out = outPoint, out.rawValue <= playhead.rawValue { outPoint = nil }
    }

    func markOut() {
        if outPoint == playhead { outPoint = nil; return }
        outPoint = playhead
        if let into = inPoint, into.rawValue >= playhead.rawValue { inPoint = nil }
    }

    func clearExportRange() {
        inPoint = nil
        outPoint = nil
    }

    /// Bumped only when a PERSON moved the playhead, and what the preview seeks on.
    ///
    /// **Playback has to be able to move the playhead without moving the player.** The seek used
    /// to key on `playhead` itself, which was fine while the only thing that wrote it was a
    /// drag — and the moment playback started writing it too, every tick would have seeked the
    /// player to where the player already was, several times a second, for the whole recording.
    /// A counter separates "somebody asked to go there" from "that is where we are".
    private(set) var seekRequest = 0

    /// A person put the playhead here. Seeks the preview.
    func movePlayhead(to time: Nanoseconds) {
        playhead = time
        seekRequest += 1
    }

    /// The preview is here. Moves the line and nothing else.
    ///
    /// **Without this the playhead did not move during playback at all** — the line sat where it
    /// was last dragged while the picture ran on, so the one surface that says WHEN things
    /// happen could not say when NOW was.
    func followPlayer(outputTime: Nanoseconds) {
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
    /// the editor helping. a native editor draws a `SnapIndicatorOverlay` for this, and it is the
    /// difference between a feature and an unexplained twitch.
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
    /// authored value here.
    private(set) var zoomAdjustments: [ZoomAdjustment] = []
    /// The zoom a person is holding, so the lane can show it differently while it moves.
    private(set) var draggingZoom: HostInstant?
    /// Derived, then adjusted — the order IS the producer-value rule.
    var zooms: [ZoomBlock] { zoomAdjustments.applied(to: derivedZooms) }

    /// Hands the lane the zooms the gate derived. Called when the plan is read; the
    /// adjustments survive, because they are keyed on the click rather than on the block.
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

    func setZoomAnchor(_ anchor: EpochAnchor?) {
        zoomAnchor = anchor
    }

    func setDerivedZooms(_ blocks: [ZoomBlock]) {
        derivedZooms = blocks
        publish()
    }

    // MARK: - zoom lane

    /// Shows a zoom being moved, without committing it.
    func previewZoomMove(_ origin: HostInstant, byNanoseconds delta: Int64) {
        let base = zoomDragBaseline ?? zoomAdjustments
        zoomDragBaseline = base
        draggingZoom = origin
        zoomAdjustments = base.replacing(base.adjustment(for: origin).movedBy(delta))
    }

    /// Shows a zoom's end being dragged.
    func previewZoomResize(_ origin: HostInstant, byNanoseconds delta: Int64) {
        let base = zoomDragBaseline ?? zoomAdjustments
        zoomDragBaseline = base
        draggingZoom = origin
        zoomAdjustments = base.replacing(base.adjustment(for: origin).resizedBy(delta))
    }

    /// Commits the drag as ONE step, for the same reason a trim does.
    func commitZoomDrag(_ name: String) {
        defer {
            zoomDragBaseline = nil
            draggingZoom = nil
        }
        publish()
    }

    func toggleZoomSuppressed(_ origin: HostInstant) {
        let current = zoomAdjustments.adjustment(for: origin)
        zoomAdjustments = zoomAdjustments
            .replacing(current.settingSuppressed(!current.suppressed))
        publish()
    }

    func isZoomSuppressed(_ origin: HostInstant) -> Bool {
        zoomAdjustments.adjustment(for: origin).suppressed
    }

    var hasZoomEdits: Bool { !zoomAdjustments.isEmpty }

    /// Applies a saved edit. **`reset`, not `record`** — opening a project is not an edit to
    /// whatever was open before it, and a person must not be able to ⌘Z their way from one
    /// project into another.
    func restoreSavedEdit(_ saved: EditTimeline) {
        history.reset(to: saved)
        original = saved
        selection = nil
        selectedClip = nil
        publish()
    }

    func restoreZoomAdjustments(_ adjustments: [ZoomAdjustment]) {
        zoomAdjustments = adjustments
        publish()
    }

    func resetZooms() {
        zoomAdjustments = []
        publish()
    }

    /// The adjustments a drag started from, so every intermediate value is computed from there
    /// rather than from the previous frame — the same reason a trim keeps a baseline.
    private var zoomDragBaseline: [ZoomAdjustment]?

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
        // a person must not be able to ⌘Z their way back into a different video.
        history.reset(to: EditTimeline.whole(duration: total))
        window = .whole(total)
        original = edit
        movePlayhead(to: Nanoseconds(0))
        selection = nil
        selectedClip = nil
        publish()
    }

    var hasEdits: Bool { edit != original }

    /// **Snapped to clip edges and the playhead.** A cut a person aims at an existing edge
    /// should land ON it: a cut that misses by a nanosecond leaves a sliver of a clip that is
    /// invisible on the strip and real in the export.
    @discardableResult
    func snapped(_ time: Nanoseconds, threshold: Nanoseconds) -> Nanoseconds {
        let targets = SnapEngine.targets(in: edit, playhead: playhead)
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

    /// The speeds the toolbar offers. Not a slider: a demo is sped up to a ROUND number a
    /// viewer can feel — half, twice — and a slider invites 1.37×, which is a number nobody
    /// chose on purpose.
    static let speedChoices: [Double] = [0.5, 1, 1.5, 2, 4]

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
        apply("Play at \(EditorToolbar.speedLabel(speed))",
              EditTimeline(clips: edit.clips.map { $0.id == id ? $0.playing(at: speed) : $0 },
                           nextID: edit.nextID))
    }

    /// Cuts the selected clip in two at the playhead.
    ///
    /// **The playhead is in SOURCE time and `split` takes OUTPUT time**, so it converts —
    /// the two are equal only until the first cut, and a split that skipped the conversion
    /// would land somewhere else on every timeline that had already been edited.
    func splitAtPlayhead() {
        guard let output = edit.outputTime(atSource: playhead),
              let split = edit.split(atOutput: output) else { return }
        apply("Split at Playhead", split)
    }

    var canSplitAtPlayhead: Bool {
        edit.outputTime(atSource: playhead).map { edit.split(atOutput: $0) != nil } ?? false
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
        apply(name, edit.removing(sourceRange: range))
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
        window = window.revealing(playhead)
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
    func previewTrim(of id: ClipID, edge: TrimEdge, byNanoseconds delta: Int64) {
        let base = trimBaseline ?? history.current
        trimBaseline = base
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
        }
        guard let live = liveEdit else { return }
        apply(edge == .start ? "Trim Clip Start" : "Trim Clip End", live)
    }

    /// The timeline a drag started from. Every intermediate value is computed from THIS rather
    /// than from the previous frame, so a drag cannot accumulate rounding — the handle ends up
    /// where the cursor is, not where a hundred small additions put it.
    private var trimBaseline: EditTimeline?

    // MARK: - undo

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    /// What a menu item should say. `nil` when there is nothing to undo, so the caller can
    /// disable rather than offer a verb with no object.
    var undoTitle: String? { history.undoName.map { "Undo \($0)" } }
    var redoTitle: String? { history.redoName.map { "Redo \($0)" } }

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
    private func apply(_ name: String, _ updated: EditTimeline) {
        history.record(name, updated)
        clearSelectionsThatNoLongerExist()
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

// MARK: - The strip

/// A horizontal strip of the recording: kept spans filled, cut spans hollow, the playhead on
/// top, and a drag-out selection.
struct TimelineEditor: View {
    let model: TimelineEditorModel
    /// Called after any edit, so the host rebuilds the composition and the preview follows.
    let onChange: () -> Void
    /// **The other three tracks, drawn but not edited here.** Text, captions and redactions were
    /// invisible on the timeline: a person could add a title and see nothing on the one surface
    /// that says WHEN things happen. Their own panels still own the editing — this shows where
    /// they are, which is what a timeline is for.
    /// The frames drawn along the video track. Owned by the host so it survives a rebuild of
    /// this view — a cache discarded on every edit would re-decode the whole strip per keystroke.
    var filmstrip: Filmstrip?
    var texts = TextTrack()
    var captions = CaptionTrack()
    var redactions = RedactionTrack()

    /// How close a drag must come to an edge to snap, in POINTS. Converted to nanoseconds
    /// against the strip's own width, so the tolerance is the same distance on screen at any
    /// recording length rather than the same number of nanoseconds.
    private let snapPoints: Double = 8

    /// Below this, a clip's label would be truncated to nothing. a native editor's
    /// `timelineClipLabelMinWidth` is 56 for the same purpose; a duration stamp is narrower.
    static let clipLabelMinimumWidth: Double = 44

    /// The header column's width. One number, because every lane's header and every lane's
    /// content have to start at the same x or the tracks do not line up — which is the single
    /// thing that makes a stack of strips read as a timeline.
    private static let headerWidth: Double = 84

    var body: some View {
        if let duration = model.duration, duration.rawValue > 0 {
            VStack(alignment: .leading, spacing: 2) {
                lane(nil, nil, height: 16) { ruler(duration: duration) }
                lane("Video", "film", height: 44) {
                    ZStack(alignment: .topLeading) {
                        strip(duration: duration)
                        snapLine(height: 44)
                    }
                }
                // **Zooms get their own lane.** Screen Studio shows each click as a keyframe
                // with an adjustable duration; ScreenKite gives zooms a lane beside speed and
                // annotations. A review panel can reject a zoom but cannot fix one that is a
                // quarter of a second late, which is the thing a person actually wants to do.
                // **Audio has its own lane now, and until it did the waveform was invisible.**
                // It was drawn inside the video strip, underneath the clip rectangles — which
                // are opaque, so it was covered on every frame it existed. a native editor and
                // a Swift recorder both give audio a track of its own; a waveform behind the picture
                // track is a waveform nobody sees.
                // One lane per recorded track, named for the source it came from. A single
                // "Audio" lane over both answered "is there sound here" and could not answer
                // "is that me or the machine" — which is the question someone deciding whether
                // to keep their narration is asking.
                if model.trackWaveforms.isEmpty {
                    lane("Audio", "waveform", height: 30) { audioLane(nil, duration: duration) }
                } else {
                    ForEach(Array(model.trackWaveforms.enumerated()), id: \.offset) { index, envelope in
                        lane(Self.audioTrackName(index), Self.audioTrackIcon(index), height: 26) {
                            audioLane(envelope, duration: duration, tint: Self.audioTint(index))
                        }
                    }
                }
                lane("Zooms", "plus.magnifyingglass", height: 18) { zoomLane(duration: duration) }
                // Only while there is something to show. A permanently empty lane is a lane a
                // person learns to ignore, and this one is empty until they ask.
                if !model.silences.isEmpty {
                    lane("Silence", "waveform.slash", height: 12) {
                        blocks(model.silences.map { ($0.start, $0.end) },
                               tint: Theme.Ink.secondary)
                    }
                }
                if !texts.isEmpty {
                    lane("Text", "textformat", height: 14) {
                        blocks(texts.items.map { ($0.start, $0.end) }, tint: Theme.Lane.text)
                    }
                }
                if !captions.isEmpty {
                    lane("Captions", "captions.bubble", height: 14) {
                        blocks(captions.cues.map { ($0.start, $0.end) }, tint: Theme.Lane.caption)
                    }
                }
                if !redactions.isEmpty {
                    lane("Hide", "eye.slash", height: 14) {
                        blocks(redactions.items.map { item in
                            // A region covering the whole recording is drawn as one block
                            // spanning it, rather than as nothing — which is what an
                            // unset start and end would otherwise render as.
                            item.coversEverything ? (Nanoseconds(0), duration)
                                                  : (item.start, item.end)
                        }, tint: Theme.Lane.hide)
                    }
                }
                readout(duration: duration)
                shortcutLayer
                playheadKeys(duration: duration)
            }
            // **One line down the whole stack, not a mark inside the picture track.** The strip
            // drew its own and no other lane did, so a zoom block, a caption and the waveform
            // could not be read against the position the preview was at — which is the entire
            // reason those lanes are stacked and aligned in the first place. Every editor in
            // `../opensource/Screen Record Opensource/` runs it from the ruler to the bottom.
            //
            // An overlay rather than a row in the stack: it has to cross the lane gaps, and it
            // must not take a hit test away from the strip underneath it.
            // Under the playhead, which must stay readable over it.
            .overlay(alignment: .topLeading) { exportRangeShade(duration: duration) }
            .overlay(alignment: .topLeading) { playheadLine(duration: duration) }
        } else {
            Text("Loading the recording…").foregroundStyle(.secondary).font(Type.detail)
        }
    }

    /// The line, drawn over every lane at once.
    ///
    /// Offset by the header column, because the lanes' content starts there — the same one
    /// number every lane uses, so this cannot drift away from the strips it is measuring.
    /// The marked export range: the parts that will NOT be written, dimmed.
    ///
    /// **Dimming what is excluded rather than tinting what is included.** A tint over the
    /// selection competes with the clips, the zoom blocks and the waveform, all of which are
    /// already colour; taking light away from the rest says the same thing and reads instantly
    /// even on a dense timeline. Screen recorders and NLEs alike settle on this.
    @ViewBuilder private func exportRangeShade(duration: Nanoseconds) -> some View {
        if let range = model.exportRange {
            GeometryReader { proxy in
                // The same origin arithmetic the playhead uses, and for the same reason — the
                // header AND the gap after it, not the header alone.
                let contentOrigin = Self.headerWidth + Space.snug
                let track = max(proxy.size.width - contentOrigin, 1)
                let start = fraction(Nanoseconds(range.lowerBound), of: duration) * track
                let end = fraction(Nanoseconds(range.upperBound), of: duration) * track
                ZStack(alignment: .topLeading) {
                    // **Every offset starts at `contentOrigin`.** The lead-in shade had none in
                    // its first version and covered the lane headers, which are outside the
                    // strip and are not part of any range.
                    Rectangle().fill(Theme.Ink.primary.opacity(0.45))
                        .frame(width: max(start, 0))
                        .offset(x: contentOrigin)
                    Rectangle().fill(Theme.Ink.primary.opacity(0.45))
                        .frame(width: max(track - end, 0))
                        .offset(x: contentOrigin + end)
                    // The edges themselves, so a range whose ends are near the strip's own is
                    // still findable.
                    Rectangle().fill(Theme.accent).frame(width: 2)
                        .offset(x: contentOrigin + start)
                    Rectangle().fill(Theme.accent).frame(width: 2)
                        .offset(x: contentOrigin + end - 2)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func playheadLine(duration: Nanoseconds) -> some View {
        GeometryReader { proxy in
            // **The header AND the gap after it.** `lane` is `HStack(spacing: Space.snug)` with
            // an 84-point header, so its content starts at 92 and is 92 narrower than the
            // stack — not 84. Counting the header alone put this line 8 points left of the
            // strip's own and stretched it across 8 points more, which is precisely how far
            // apart the two playheads in the editor were.
            let contentOrigin = Self.headerWidth + Space.snug
            let track = max(proxy.size.width - contentOrigin, 1)
            Rectangle()
                .fill(Theme.Ink.primary)
                .frame(width: 1)
                .offset(x: contentOrigin + fraction(model.playhead, of: duration) * track)
        }
        .allowsHitTesting(false)
    }

    /// One track: a labelled header cell and its content, both at the same height.
    ///
    /// **Each lane carries its own header rather than there being two parallel columns.** Two
    /// columns built from one list is the obvious shape and the one that drifts: a lane added to
    /// the content side and not the header side misaligns every track below it, and nothing
    /// catches that. This cannot misalign because there is one row.
    @ViewBuilder private func lane<Content: View>(
        _ title: String?, _ icon: String?, height: Double,
        @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Space.snug) {
            HStack(spacing: Space.tight) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .frame(width: 11)
                }
                if let title {
                    Text(title).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Ink.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: Self.headerWidth, height: height, alignment: .leading)
            content()
                .frame(height: height)
        }
    }

    /// The time ruler.
    ///
    /// **The tick interval is chosen from the visible span, not fixed.** A ruler with a tick
    /// every second is unreadable at a twenty-minute zoom and useless at a half-second one; the
    /// interval is the smallest step from a human list — 0.1s up to 10 minutes — that leaves at
    /// least 64 points between labels. Every editor in the reference set does this; a fixed
    /// interval is what makes a timeline look like a progress bar.
    @ViewBuilder private func ruler(duration: Nanoseconds) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let visible = Double(model.window.visible.rawValue) / 1_000_000_000
            let step = Self.tickStep(visibleSeconds: visible, width: width)
            let start = Double(model.window.start.rawValue) / 1_000_000_000
            let first = (start / step).rounded(.down) * step
            ZStack(alignment: .topLeading) {
                ForEach(0..<Self.maximumTicks, id: \.self) { index in
                    let seconds = first + Double(index) * step
                    let fraction = (seconds - start) / max(visible, 0.000_001)
                    if fraction >= 0, fraction <= 1, seconds >= 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.tickLabel(seconds, step: step))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(Theme.Ink.tertiary)
                                .fixedSize()
                            Rectangle().fill(Theme.Line.divider).frame(width: 1, height: 4)
                        }
                        .offset(x: fraction * width)
                    }
                }
            }
        }
    }

    /// A bounded loop rather than a computed count: `ForEach` over a range SwiftUI cannot see the
    /// bounds of re-evaluates on every zoom frame, and a ruler is redrawn while dragging.
    private static let maximumTicks = 40

    static func tickStep(visibleSeconds: Double, width: Double) -> Double {
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let minimumSpacing: Double = 64
        for step in candidates where width * step / max(visibleSeconds, 0.000_001) >= minimumSpacing {
            return step
        }
        return candidates[candidates.count - 1]
    }

    /// `m:ss` above a second, `m:ss.t` below it — a ruler stepping in tenths that prints whole
    /// seconds prints the same label several times in a row.
    static func tickLabel(_ seconds: Double, step: Double) -> String {
        let whole = Int(seconds)
        if step < 1 {
            return String(format: "%d:%02d.%d", whole / 60, whole % 60,
                          Int((seconds - Double(whole)) * 10))
        }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The line a snap took hold at. Drawn over the video track rather than across every lane:
    /// the thing being snapped is on that track, and a full-height line would be a second
    /// playhead.
    @ViewBuilder private func snapLine(height: Double) -> some View {
        if let snap = model.snapIndicator {
            GeometryReader { geometry in
                let x = model.window.fraction(of: snap) * geometry.size.width
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 1)
                    .offset(x: x)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 3)
            }
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }

    /// The frames covering one clip's span, at the current zoom.
    ///
    /// **Positioned by their own time, not tiled.** A filmstrip laid out by index would slide
    /// out of step with the picture as soon as a cut moved a clip; each frame is drawn where its
    /// timestamp lands, so it stays over the moment it came from.
    @ViewBuilder private func filmstripLayer(from start: Nanoseconds, to end: Nanoseconds,
                                             width: Double, height: Double) -> some View {
        if let filmstrip, width > 2 {
            let visible = Double(model.window.visible.rawValue) / 1_000_000_000
            let step = Filmstrip.step(visibleSeconds: visible, width: width + 1)
            let stripWidth = height * 16 / 9
            let first = Double(start.rawValue) / 1_000_000_000
            let last = Double(end.rawValue) / 1_000_000_000
            // **Each frame fills its own slot, so the strip has no gaps.** `Filmstrip.step`
            // snaps UP to a ladder value (0.25, 0.5, 1, 2, …) so one decode serves several
            // zoom levels; when it snaps, the spacing between frames grows past a thumbnail's
            // natural width and the lane's own fill shows through as regular vertical bands —
            // which is what the purple stripes down the video track were. A filmstrip is a
            // continuous strip, so a frame is drawn at least as wide as the gap to the next
            // one, `.fill` cropping it rather than stretching it.
            GeometryReader { _ in
                ZStack(alignment: .topLeading) {
                    ForEach(filmstrip.framesIn(step: step, from: first, to: last), id: \.0) { key, image in
                        let span = max(last - first, 0.000_001)
                        let x = (key.seconds - first) / span * width
                        let slot = max(stripWidth, step / span * width)
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: slot, height: height)
                            .clipped()
                            .offset(x: x)
                    }
                }
            }
            .allowsHitTesting(false)
            .task(id: "\(filmstrip.generation)-\(step)-\(first)-\(visible)") {
                filmstrip.request(step: step, from: first,
                                  visibleSeconds: max(last - first, step))
            }
        }
    }

    /// **The master writes system audio first and the microphone second.** That order is
    /// `AudioMixBuilder.trackOrder`, which the export mixes by and which has a test on it; an
    /// `AVAssetTrack` carries no name to match on, so the index IS the identity.
    static func audioTrackName(_ index: Int) -> String {
        switch index {
        case 0: "System"
        case 1: "Mic"
        default: "Audio \(index + 1)"
        }
    }

    static func audioTrackIcon(_ index: Int) -> String {
        switch index {
        case 0: "speaker.wave.2"
        case 1: "mic"
        default: "waveform"
        }
    }

    /// The two sources are two hues from the same family — the system's audio nearer the video
    /// track it belongs to, the microphone nearer the caption track it produces.
    static func audioTint(_ index: Int) -> Color {
        switch index {
        case 0: Theme.Lane.audio
        case 1: Theme.Lane.caption
        default: Theme.Ink.secondary
        }
    }

    /// One audio track's waveform, on its own ground.
    @ViewBuilder private func audioLane(_ envelope: WaveformEnvelope?, duration: Nanoseconds,
                                        tint: Color = Theme.Lane.audio) -> some View {
        GeometryReader { geometry in
            // `.topLeading`, matching the bars' own alignment: centred, the strip would sit
            // wherever its measured width put it rather than at time zero.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.block).fill(Theme.Fill.track)
                if let envelope, !envelope.isEmpty {
                    waveformLayer(envelope, width: geometry.size.width,
                                  height: geometry.size.height, tint: tint)
                } else if envelope == nil && model.waveform == nil {
                    // Said rather than left blank: an empty lane and a lane still reading the
                    // audio look the same, and one of them is worth waiting for.
                    Text("Reading the audio\u{2026}")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A track that exists and is silent says so, rather than looking like one
                    // still loading — a muted microphone and a microphone that failed produce
                    // the same empty lane otherwise.
                    Text("Silent")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// A lane of plain blocks. Read-only: the panel that owns each kind is where it is edited,
    /// and a block here that could be dragged would be a second place to change the same value.
    @ViewBuilder private func blocks(_ spans: [(Nanoseconds, Nanoseconds)],
                                     tint: Color) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.block).fill(Theme.Fill.track)
                ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                    let x = model.window.fraction(of: span.0) * width
                    let w = (model.window.fraction(of: span.1)
                             - model.window.fraction(of: span.0)) * width
                    RoundedRectangle(cornerRadius: Radius.block)
                        .fill(tint.opacity(0.75))
                        .frame(width: max(w, 2))
                        .offset(x: x)
                }
            }
        }
    }

    @ViewBuilder private func strip(duration: Nanoseconds) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                // The recording as a whole — the ground the cuts show as gaps in.
                RoundedRectangle(cornerRadius: Radius.strip)
                    .fill(Theme.Fill.track)

                // Keyed on the clip's own id, not its index: SwiftUI reuses views by
                // identity, and an index key would animate a deleted clip into its
                // neighbour's place rather than removing it.
                ForEach(model.edit.clips) { clip in
                    let x = model.window.fraction(of: clip.sourceStart) * width
                    // The DURATION's width, which is a span rather than a position — the
                    // window's `fraction` measures from its start, so a length has to be
                    // measured as the difference between two positions.
                    let w = (model.window.fraction(of: clip.sourceEnd)
                             - model.window.fraction(of: clip.sourceStart)) * width
                    let isSelected = clip.id == model.selectedClip
                    RoundedRectangle(cornerRadius: Radius.strip)
                        .fill(Theme.Lane.video.opacity(isSelected ? 0.55 : 0.35))
                        // **The frames go INSIDE the clip, clipped to it.** Drawn behind, they
                        // would show through the gaps a cut leaves and a removed span would
                        // still have a picture in it — which is the opposite of what a cut
                        // means. `clipShape` is what makes the strip say what survives.
                        .overlay {
                            filmstripLayer(from: clip.sourceStart, to: clip.sourceEnd,
                                           width: w, height: geometry.size.height)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.strip))
                        }
                        .overlay {
                            // The selected clip is outlined rather than recoloured: the fill
                            // already carries "this is kept footage", and a second colour
                            // there would make selection and keptness the same channel.
                            RoundedRectangle(cornerRadius: Radius.strip)
                                .strokeBorder(Theme.Ink.primary, lineWidth: isSelected ? 2 : 0)
                        }
                        // **A label inside the clip, when it fits.** ScreenKite writes a name
                        // and a duration into every clip and a native editor has a
                        // `timelineClipLabelMinWidth` for the same reason: a strip of unlabelled
                        // rectangles says how many clips there are and nothing else. Hidden
                        // below the width where it would be truncated to nothing, rather than
                        // squeezed — a clipped label is worse than none.
                        .overlay(alignment: .topLeading) {
                            if w > Self.clipLabelMinimumWidth {
                                Text(clip.speed == 1 ? Self.stamp(clip.duration)
                                     : "\(Self.stamp(clip.duration)) \u{00B7} "
                                     + EditorToolbar.speedLabel(clip.speed))
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Theme.Ink.primary.opacity(0.85))
                                    .padding(.horizontal, Space.tight)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.black.opacity(0.35)))
                                    .padding(Space.tight)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: max(w, 1))
                        .offset(x: x)
                }

                if let selection = model.selection {
                    let x = model.window.fraction(of: Nanoseconds(selection.lowerBound)) * width
                    let w = (model.window.fraction(of: Nanoseconds(selection.upperBound))
                             - model.window.fraction(of: Nanoseconds(selection.lowerBound))) * width
                    Rectangle()
                        .fill(Theme.Ink.primary.opacity(0.22))
                        .frame(width: max(w, 1))
                        .offset(x: x)
                        .allowsHitTesting(false)
                }

                // After the clips so they are not covered by the next clip's fill. The
                // playhead is an overlay over the whole stack and draws above either.
                if let selected = model.selectedClip,
                   let clip = model.edit.clips.first(where: { $0.id == selected }) {
                    trimHandle(for: clip, edge: .start, duration: duration, width: width)
                    trimHandle(for: clip, edge: .end, duration: duration, width: width)
                }

                // **The strip's own playhead is gone, and its absence is the point.** The
                // full-height line above was added because "the strip drew its own and no
                // other lane did" — and then this was left in place, so the editor drew two,
                // eight points apart, from two different origins. One line, over every lane.
            }
            .contentShape(Rectangle())
            // Pinch to zoom, anchored where the fingers are. `MagnifyGesture` reports a
            // cumulative magnification, so the delta against the last one is what advances the
            // window — feeding the cumulative value would zoom exponentially during a pinch.
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let anchor = min(max(value.startAnchor.x, 0), 1)
                        model.zoomStrip(by: value.magnification / lastMagnification,
                                        anchoredAtFraction: anchor)
                        lastMagnification = value.magnification
                    }
                    .onEnded { _ in lastMagnification = 1 }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let threshold = nanoseconds(forPoints: snapPoints,
                                                    width: width, duration: duration)
                        let start = model.snapped(sourcePosition(at: value.startLocation.x,
                                                                     width: width, duration: duration),
                                                  threshold: threshold)
                        let now = model.snapped(sourcePosition(at: value.location.x,
                                                                   width: width, duration: duration),
                                                threshold: threshold)
                        if abs(now.rawValue - start.rawValue) < threshold.rawValue {
                            // A tap, not a drag: move the playhead, clear the span selection,
                            // and select the CLIP under it. Without the first part every click
                            // would leave a zero-width span that the buttons would act on.
                            model.selection = nil
                            model.movePlayhead(to: now)
                            model.selectClip(atSource: now)
                        } else {
                            model.selection = min(start.rawValue, now.rawValue)
                                ..< max(start.rawValue, now.rawValue)
                            model.movePlayhead(to: now)
                        }
                    }
                    .onEnded { _ in model.endDrag() }
            )
        }
    }

    /// The audio envelope, drawn behind the clips.
    ///
    /// **One bar per pixel, taking the MAXIMUM of the slices that fall in it.** The envelope is
    /// 200 slices a second and the strip is a few hundred points wide, so most pixels cover
    /// several slices. Averaging them would flatten a transient — a click, the start of a word
    /// — into the quiet around it, and those are exactly what a person is looking for when they
    /// scan a waveform for where to cut.
    ///
    /// A `Canvas`, not a stack of `Rectangle`s: several hundred views that redraw on every
    /// playhead move is the difference between a strip that scrubs and one that stutters.
    @ViewBuilder private func waveformLayer(_ waveform: WaveformEnvelope, width: Double,
                                            height: Double, tint: Color) -> some View {
        if !waveform.isEmpty, width > 0 {
            // The window's span, not the recording's — a zoomed strip must show the audio it
            // is showing, and the offset comes from where the window starts.
            WaveformBars(
                heights: waveform.columnHeights(
                    columns: Int(width.rounded(.down)),
                    from: Double(model.window.start.rawValue) / 1_000_000_000,
                    spanningSeconds: Double(model.window.visible.rawValue) / 1_000_000_000),
                height: height, width: width, tint: tint)
                .equatable()
            .frame(width: width, height: height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// The derived zooms as draggable blocks.
    ///
    /// Drag the body to move a zoom, the right edge to change how long it lasts, and click to
    /// turn it off. A suppressed zoom is drawn hollow rather than removed: a person needs to
    /// see that there WAS a zoom here in order to bring it back, and a lane that erased it
    /// would make "no zoom" and "never had one" look the same.
    @ViewBuilder private func zoomLane(duration: Nanoseconds) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.block).fill(Theme.Fill.track)

                ForEach(model.derivedZooms, id: \.origin) { derived in
                    // Drawn from the ADJUSTED block where one survives, so a drag is visible
                    // while it happens; a suppressed zoom has no adjusted block, so it falls
                    // back to where it was derived and is drawn hollow.
                    let shown = model.zooms.first { $0.origin == derived.origin } ?? derived
                    let suppressed = model.isZoomSuppressed(derived.origin)
                    // Converted through the anchor, never used raw — see `zoomAnchor`.
                    if let start = model.offset(of: shown.start),
                       let end = model.offset(of: shown.end) {
                        let x = model.window.fraction(of: start) * width
                        let w = (model.window.fraction(of: end)
                                 - model.window.fraction(of: start)) * width
                        zoomBlockView(origin: derived.origin, suppressed: suppressed,
                                      width: max(w, 3), height: geometry.size.height,
                                      laneWidth: width, duration: duration, zoom: shown.zoom)
                            .offset(x: x)
                    }
                }
            }
        }
    }

    @ViewBuilder private func zoomBlockView(origin: HostInstant, suppressed: Bool,
                                            width: Double, height: Double,
                                            laneWidth: Double, duration: Nanoseconds,
                                            zoom: Double = 1) -> some View {
        let held = model.draggingZoom == origin
        RoundedRectangle(cornerRadius: Radius.block)
            .fill(suppressed ? AnyShapeStyle(.clear)
                  : AnyShapeStyle(Theme.Lane.zoom.opacity(held ? 0.95 : 0.7)))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.block)
                    .strokeBorder(Theme.Lane.zoom, style: StrokeStyle(lineWidth: 1,
                                                            dash: suppressed ? [3, 2] : []))
            }
            // **How far it zooms, written on it.** ScreenKite labels its zoom blocks "1.5×",
            // and without a number a lane of identical rectangles cannot say which zoom is
            // gentle and which is close. Hidden when the block is too narrow to hold it.
            .overlay {
                if width > 30, !suppressed {
                    Text(FramingDepth.label(for: zoom))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.black.opacity(0.75))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleZoomSuppressed(origin); onChange() }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let delta = nanoseconds(forPoints: value.translation.width,
                                                width: laneWidth, duration: duration)
                        // A drag that started in the right eighth resizes; anywhere else moves.
                        // One gesture, two meanings, decided by where it began — the same
                        // convention every timeline uses, and cheaper than a separate handle on
                        // a block that can be three points wide.
                        let signed = value.translation.width < 0 ? -delta.rawValue : delta.rawValue
                        if value.startLocation.x > width * 0.75 {
                            model.previewZoomResize(origin, byNanoseconds: signed)
                        } else {
                            model.previewZoomMove(origin, byNanoseconds: signed)
                        }
                    }
                    .onEnded { value in
                        model.commitZoomDrag(value.startLocation.x > width * 0.75
                                             ? "Resize Zoom" : "Move Zoom")
                        onChange()
                    }
            )
            .help(suppressed ? "This zoom is off. Click to turn it back on."
                  : "Drag to move, drag the right edge to change how long it lasts, click to turn it off.")
    }

    /// One edge of the selected clip, draggable.
    ///
    /// **Wider than it looks.** The visible line is 2 points; the hit area is 12, which is
    /// a Swift recorder's `handleWidth` and roughly the smallest target a person hits reliably with a
    /// trackpad. A handle you can see but not grab is worse than no handle.
    @ViewBuilder private func trimHandle(for clip: EditClip, edge: TimelineEditorModel.TrimEdge,
                                         duration: Nanoseconds, width: Double) -> some View {
        let at = edge == .start ? clip.sourceStart : clip.sourceEnd
        let x = fraction(at, of: duration) * width
        Rectangle()
            .fill(.primary)
            .frame(width: 2)
            .frame(width: handleHitWidth)          // the grab area, not the drawn line
            .contentShape(Rectangle())
            .offset(x: x - handleHitWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = nanoseconds(forPoints: value.translation.width,
                                                width: width, duration: duration)
                        model.previewTrim(of: clip.id, edge: edge, byNanoseconds: delta.rawValue)
                    }
                    .onEnded { _ in
                        model.commitTrim(edge: edge)
                        onChange()
                    }
            )
            .onHover { inside in
                // The cursor is the only thing that says a 2-point line is draggable before a
                // person tries it. a Swift recorder pushes the same one.
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    /// a Swift recorder's `handleWidth`. Carried over rather than re-guessed.
    private let handleHitWidth: Double = 12

    /// The last cumulative magnification a pinch reported, so each change advances the window
    /// by the DELTA. `MagnifyGesture` reports the total since the pinch began; feeding that in
    /// directly compounds it and the strip zooms exponentially under the fingers.
    @State private var lastMagnification: Double = 1

    /// Keys with no visible control of their own.
    ///
    /// **Zero-opacity buttons rather than a key handler**, because a `Button`'s shortcut is
    /// the only thing that respects the responder chain: a raw key monitor fires while a
    /// person is typing in a text field somewhere else in the window, which is how an arrow
    /// key ends up nudging a playhead the person is not looking at.
    @ViewBuilder private func playheadKeys(duration: Nanoseconds) -> some View {
        Group {
            Button("") { nudge(by: -Self.frameStep, duration: duration) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { nudge(by: Self.frameStep, duration: duration) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            // Shift is the coarse step, matching how a person expects a modifier to scale a
            // nudge everywhere else on the system.
            Button("") { nudge(by: -Self.secondStep, duration: duration) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { nudge(by: Self.secondStep, duration: duration) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// One frame at 60 fps — the rate the export is resampled to, so a nudge moves the
    /// playhead by exactly one frame of the video a person will get.
    static let frameStep: Int64 = 16_666_667
    static let secondStep: Int64 = 1_000_000_000

    /// Where the playhead sits across the strip, clamped — a keyboard zoom anchors here, and
    /// a playhead scrolled off the edge would otherwise anchor outside the view.
    private var playheadAnchor: Double {
        min(max(model.window.fraction(of: model.playhead), 0), 1)
    }

    private func nudge(by delta: Int64, duration: Nanoseconds) {
        let moved = min(max(model.playhead.rawValue + delta, 0), duration.rawValue)
        model.movePlayhead(to: Nanoseconds(moved))
        // The clip under the playhead follows it, so ← / → walk the clips as well as the time.
        model.selectClip(atSource: model.playhead)
        // …and the view follows the playhead off the edge, but only when it has gone off.
        model.revealPlayhead()
    }

    @ViewBuilder private func readout(duration: Nanoseconds) -> some View {
        HStack {
            Text(Self.stamp(model.playhead))
            Spacer()
            if let selection = model.selection {
                Text("selected \(Self.stamp(Nanoseconds(Int64(selection.count))))")
            } else if let selected = model.selectedClip,
                      let clip = model.edit.clips.first(where: { $0.id == selected }) {
                Text("clip \(Self.stamp(clip.duration)) of \(model.edit.clips.count)")
            } else {
                Text("\(Self.stamp(model.edit.outputDuration)) of \(Self.stamp(duration))")
            }
        }
        .font(Type.readout).foregroundStyle(Theme.Ink.secondary)
    }

    /// **The keyboard shortcuts, with no buttons on them.**
    ///
    /// This used to be two rows of `.link`-styled buttons under the strip — which is where the
    /// last of the system's blue in this window was living, and which duplicated every control
    /// `EditorToolbar` now shows. What could not be deleted with them is the shortcuts: a
    /// `.keyboardShortcut` has to be attached to a live view, and these are the keys an editing
    /// session is actually driven by. Zero-sized and hidden from accessibility, because the
    /// toolbar's buttons are the ones a reader should find.
    @ViewBuilder private var shortcutLayer: some View {
        Group {
            Button("Split at playhead") { model.splitAtPlayhead(); onChange() }
                .disabled(!model.canSplitAtPlayhead)
                // `S` unmodified, the spelling every editor in the reference set uses for a cut
                // at the playhead. No modifier: it is the most-used key in an editing session.
                .keyboardShortcut("s", modifiers: [])
            Button("Delete clip") { model.deleteSelectedClip(); onChange() }
                .disabled(model.selectedClip == nil)
                .keyboardShortcut(.delete, modifiers: [])
            // `I` and `O` unmodified — the spelling every editor that has in and out points
            // uses, and the one ScreenKite's own guide documents. No modifier for the same
            // reason `S` has none: these are session keys, not commands.
            Button("Mark in") { model.markIn() }
                .keyboardShortcut("i", modifiers: [])
            Button("Mark out") { model.markOut() }
                .keyboardShortcut("o", modifiers: [])
            Button("Clear range") { model.clearExportRange() }
                .disabled(model.inPoint == nil && model.outPoint == nil)
                .keyboardShortcut("i", modifiers: [.option])
            Button("Undo") { model.undo(); onChange() }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { model.redo(); onChange() }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            // Zoom anchored on the PLAYHEAD for a keyboard zoom: it keeps what a person is
            // looking at where they are looking. The toolbar's buttons anchor at the middle,
            // because a click has no position — see `EditorToolbar.zoom`.
            Button("Zoom in") { model.zoomStrip(by: 2, anchoredAtFraction: playheadAnchor) }
                .disabled(!model.window.canZoomIn)
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom out") { model.zoomStrip(by: 0.5, anchoredAtFraction: playheadAnchor) }
                .disabled(!model.window.canZoomOut)
                .keyboardShortcut("-", modifiers: .command)
            Button("Fit") { model.showWholeRecording() }
                .disabled(!model.window.canZoomOut)
                .keyboardShortcut("0", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - strip geometry

    /// **Through the window, never by dividing here.** A second copy of this conversion is
    /// how a zoomed strip ends up drawing clips in one space and the playhead in another.
    private func fraction(_ time: Nanoseconds, of duration: Nanoseconds) -> Double {
        model.window.fraction(of: time)
    }

    /// **Named `sourcePosition`, not `time`.** `noAppSourceReadsAnAmbientValueAtAll` bans the
    /// spelling `time(` anywhere in the app, because that is how C's `time()` reads an ambient
    /// clock — the one thing `Minting` exists to be the sole owner of. The scan cannot tell a
    /// clock read from a coordinate conversion, and a ban that a reader has to except by hand
    /// is a ban that stops being read.
    private func sourcePosition(at x: Double, width: Double, duration: Nanoseconds) -> Nanoseconds {
        guard width > 0 else { return Nanoseconds(0) }
        return model.window.position(atFraction: x / width)
    }

    /// A screen distance as a span of the recording. The snap tolerance is defined in points
    /// so it feels the same on a 10-second recording and a 10-minute one.
    private func nanoseconds(forPoints points: Double, width: Double,
                             duration: Nanoseconds) -> Nanoseconds {
        guard width > 0 else { return Nanoseconds(0) }
        // **Scaled by the WINDOW, not the recording**, so a snap tolerance of eight points is
        // eight points of screen at every zoom rather than eight points of the whole file.
        return model.window.duration(forFraction: points / width)
    }

    static func stamp(_ time: Nanoseconds) -> String {
        let seconds = Double(time.rawValue) / 1_000_000_000
        return String(format: "%d:%05.2f", Int(seconds) / 60,
                      seconds.truncatingRemainder(dividingBy: 60))
    }
}


/// The audio envelope as bars, mirrored about the middle — which is how a waveform is read.
///
/// **`Equatable`, and that is the performance decision.** A strip is a few hundred columns, so
/// this is a few hundred `Rectangle`s; SwiftUI would re-evaluate every one of them on each
/// playhead move without a way to know nothing changed. Conforming lets it skip the subtree
/// when the heights and the height are the same, which they are for every frame of a scrub.
///
/// `.drawingGroup()` rasterises the result once through Metal rather than compositing hundreds
/// of layers per frame.
///
/// **No CoreGraphics geometry is named here**, which rule 5 requires of this tier: the heights
/// arrive as plain numbers from `WaveformEnvelope` and become bars through `frame`/`offset`.
private struct WaveformBars: View, Equatable {
    let heights: [Double]
    let height: Double
    /// **The frame's width, and without it nothing is drawn.** `.offset` moves a view without
    /// changing the layout, so a `ZStack` of offset bars is as wide as ONE bar — and
    /// `.drawingGroup()` rasterises to the view's bounds, which clipped every bar past the first
    /// away. The waveform had been invisible since it was written, for this and for being drawn
    /// under opaque clips; the reader was fine all along, measured at 3,816 peaks on the
    /// recording that prompted the search.
    let width: Double
    let tint: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(heights.indices, id: \.self) { column in
                let bar = heights[column] * height
                // A silent column draws nothing rather than a hairline across the silence.
                if bar > 0 {
                    Rectangle()
                        // Its own lane colour rather than ink at a low opacity: a waveform is a
                        // track, and the four tracks around it all carry a hue.
                        .fill(tint)
                        .frame(width: 1, height: bar)
                        .offset(x: Double(column), y: (height - bar) / 2)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .drawingGroup()
        .allowsHitTesting(false)
    }
}
