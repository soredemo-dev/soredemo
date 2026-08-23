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
    var playhead = Nanoseconds(0)
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
    }

    func load(duration seconds: Double) {
        let total = Nanoseconds(Int64(seconds * 1_000_000_000))
        duration = total
        // `reset`, not `record`: opening a recording is not an edit to the one before it, and
        // a person must not be able to ⌘Z their way back into a different video.
        history.reset(to: EditTimeline.whole(duration: total))
        window = .whole(total)
        original = edit
        playhead = Nanoseconds(0)
        selection = nil
        selectedClip = nil
        publish()
    }

    var hasEdits: Bool { edit != original }

    /// **Snapped to clip edges and the playhead.** A cut a person aims at an existing edge
    /// should land ON it: a cut that misses by a nanosecond leaves a sliver of a clip that is
    /// invisible on the strip and real in the export.
    func snapped(_ time: Nanoseconds, threshold: Nanoseconds) -> Nanoseconds {
        let targets = SnapEngine.targets(in: edit, playhead: playhead)
        return SnapEngine.snap(position: time, targets: targets,
                               state: &snapState, threshold: threshold)?.time ?? time
    }

    /// Ends a drag, so the next one starts unsnapped rather than inheriting a stale hold.
    func endDrag() { snapState = SnapEngine.State() }

    /// Selects the clip at a SOURCE position, or clears the selection when the tap missed
    /// every clip — a tap on a cut span selects nothing rather than the nearest thing.
    func selectClip(atSource sourceTime: Nanoseconds) {
        selectedClip = edit.clip(atSource: sourceTime)?.id
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
    var texts = TextTrack()
    var captions = CaptionTrack()
    var redactions = RedactionTrack()

    /// How close a drag must come to an edge to snap, in POINTS. Converted to nanoseconds
    /// against the strip's own width, so the tolerance is the same distance on screen at any
    /// recording length rather than the same number of nanoseconds.
    private let snapPoints: Double = 8

    /// The header column's width. One number, because every lane's header and every lane's
    /// content have to start at the same x or the tracks do not line up — which is the single
    /// thing that makes a stack of strips read as a timeline.
    private static let headerWidth: Double = 84

    var body: some View {
        if let duration = model.duration, duration.rawValue > 0 {
            VStack(alignment: .leading, spacing: 2) {
                lane(nil, nil, height: 16) { ruler(duration: duration) }
                lane("Video", "film", height: 44) { strip(duration: duration) }
                // **Zooms get their own lane.** Screen Studio shows each click as a keyframe
                // with an adjustable duration; ScreenKite gives zooms a lane beside speed and
                // annotations. A review panel can reject a zoom but cannot fix one that is a
                // quarter of a second late, which is the thing a person actually wants to do.
                lane("Zooms", "plus.magnifyingglass", height: 18) { zoomLane(duration: duration) }
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
                controls
                playheadKeys(duration: duration)
            }
        } else {
            Text("Loading the recording…").foregroundStyle(.secondary).font(Type.detail)
        }
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

                waveformLayer(duration: duration, width: width, height: geometry.size.height)

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
                        .fill(Theme.Lane.video.opacity(isSelected ? 0.95 : 0.75))
                        .overlay {
                            // The selected clip is outlined rather than recoloured: the fill
                            // already carries "this is kept footage", and a second colour
                            // there would make selection and keptness the same channel.
                            RoundedRectangle(cornerRadius: Radius.strip)
                                .strokeBorder(Theme.Ink.primary, lineWidth: isSelected ? 2 : 0)
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

                // Handles before the playhead so the playhead draws over them, and after the
                // clips so they are not covered by the next clip's fill.
                if let selected = model.selectedClip,
                   let clip = model.edit.clips.first(where: { $0.id == selected }) {
                    trimHandle(for: clip, edge: .start, duration: duration, width: width)
                    trimHandle(for: clip, edge: .end, duration: duration, width: width)
                }

                Rectangle()
                    .fill(Theme.Ink.primary)
                    .frame(width: 2)
                    .offset(x: fraction(model.playhead, of: duration) * width - 1)
                    .allowsHitTesting(false)
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
                            model.playhead = now
                            model.selectClip(atSource: now)
                        } else {
                            model.selection = min(start.rawValue, now.rawValue)
                                ..< max(start.rawValue, now.rawValue)
                            model.playhead = now
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
    @ViewBuilder private func waveformLayer(duration: Nanoseconds, width: Double,
                                            height: Double) -> some View {
        if let waveform = model.waveform, !waveform.isEmpty, width > 0 {
            // The window's span, not the recording's — a zoomed strip must show the audio it
            // is showing, and the offset comes from where the window starts.
            WaveformBars(
                heights: waveform.columnHeights(
                    columns: Int(width.rounded(.down)),
                    from: Double(model.window.start.rawValue) / 1_000_000_000,
                    spanningSeconds: Double(model.window.visible.rawValue) / 1_000_000_000),
                height: height)
                .equatable()
            .frame(height: height)
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
                    let x = model.window.fraction(of: shown.start.hostTime) * width
                    let w = (model.window.fraction(of: shown.end.hostTime)
                             - model.window.fraction(of: shown.start.hostTime)) * width
                    zoomBlockView(origin: derived.origin, suppressed: suppressed,
                                  width: max(w, 3), height: geometry.size.height,
                                  laneWidth: width, duration: duration)
                        .offset(x: x)
                }
            }
        }
    }

    @ViewBuilder private func zoomBlockView(origin: HostInstant, suppressed: Bool,
                                            width: Double, height: Double,
                                            laneWidth: Double, duration: Nanoseconds) -> some View {
        let held = model.draggingZoom == origin
        RoundedRectangle(cornerRadius: Radius.block)
            .fill(suppressed ? AnyShapeStyle(.clear)
                  : AnyShapeStyle(Theme.Lane.zoom.opacity(held ? 0.95 : 0.7)))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.block)
                    .strokeBorder(Theme.Lane.zoom, style: StrokeStyle(lineWidth: 1,
                                                            dash: suppressed ? [3, 2] : []))
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
        model.playhead = Nanoseconds(moved)
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
        .font(Type.readout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: Space.snug) {
            Button("Split at playhead") {
                model.splitAtPlayhead()
                onChange()
            }
            .disabled(!model.canSplitAtPlayhead)
            // `S` unmodified, the spelling every editor in the reference set uses for a cut
            // at the playhead. No modifier: it is the most-used key in an editing session.
            .keyboardShortcut("s", modifiers: [])

            Button("Delete clip") {
                model.deleteSelectedClip()
                onChange()
            }
            .disabled(model.selectedClip == nil)
            .keyboardShortcut(.delete, modifiers: [])

            Button("Remove selection") {
                model.removeSelection()
                onChange()
            }
            .disabled(model.selection == nil)

            Button("Keep only selection") {
                model.keepOnlySelection()
                onChange()
            }
            .disabled(model.selection == nil)

            if model.hasZoomEdits {
                Button("Reset zooms") {
                    model.resetZooms()
                    onChange()
                }
            }
            if model.hasEdits {
                Button("Revert all") {
                    model.restore()
                    onChange()
                }
            }
        }
        .buttonStyle(.link)
        .font(Type.detail)

        HStack(spacing: Space.snug) {
            // Titled with the action — "Undo Split at Playhead" — because a bare "Undo" makes
            // a person press it to find out what it does. Every editor in the reference set
            // names the action; `EditHistory` carries the name for exactly this.
            Button(model.undoTitle ?? "Undo") {
                model.undo()
                onChange()
            }
            .disabled(!model.canUndo)
            .keyboardShortcut("z", modifiers: .command)

            Button(model.redoTitle ?? "Redo") {
                model.redo()
                onChange()
            }
            .disabled(!model.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Spacer()

            // Zoom anchored on the PLAYHEAD for a keyboard zoom, on the fingers for a pinch:
            // both keep what a person is looking at where they are looking.
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
        .buttonStyle(.link)
        .font(Type.detail)
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(heights.indices, id: \.self) { column in
                let bar = heights[column] * height
                // A silent column draws nothing rather than a hairline across the silence.
                if bar > 0 {
                    Rectangle()
                        .fill(.primary.opacity(0.28))
                        .frame(width: 1, height: bar)
                        .offset(x: Double(column), y: (height - bar) / 2)
                }
            }
        }
        .frame(height: height)
        .drawingGroup()
        .allowsHitTesting(false)
    }
}
