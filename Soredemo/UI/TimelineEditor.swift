import Compositing
import Foundation
import Observation
import AppKit
import AVFoundation
import SwiftUI
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
    }
}

// MARK: - The strip

/// A horizontal strip of the recording: kept spans filled, cut spans hollow, the playhead on
/// top, and a drag-out selection.
struct TimelineEditor: View {
    let model: TimelineEditorModel
    /// Called after any edit, so the host rebuilds the composition and the preview follows.
    let onChange: () -> Void

    /// How close a drag must come to an edge to snap, in POINTS. Converted to nanoseconds
    /// against the strip's own width, so the tolerance is the same distance on screen at any
    /// recording length rather than the same number of nanoseconds.
    private let snapPoints: Double = 8

    var body: some View {
        if let duration = model.duration, duration.rawValue > 0 {
            VStack(alignment: .leading, spacing: 6) {
                strip(duration: duration)
                    .frame(height: 44)
                readout(duration: duration)
                controls
                playheadKeys(duration: duration)
            }
        } else {
            Text("Loading the recording…").foregroundStyle(.secondary).font(.caption)
        }
    }

    @ViewBuilder private func strip(duration: Nanoseconds) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                // The recording as a whole — the ground the cuts show as gaps in.
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)

                waveformLayer(duration: duration, width: width, height: geometry.size.height)

                // Keyed on the clip's own id, not its index: SwiftUI reuses views by
                // identity, and an index key would animate a deleted clip into its
                // neighbour's place rather than removing it.
                ForEach(model.edit.clips) { clip in
                    let x = fraction(clip.sourceStart, of: duration) * width
                    let w = fraction(clip.duration, of: duration) * width
                    let isSelected = clip.id == model.selectedClip
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.tint)
                        .overlay {
                            // The selected clip is outlined rather than recoloured: the fill
                            // already carries "this is kept footage", and a second colour
                            // there would make selection and keptness the same channel.
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.primary, lineWidth: isSelected ? 2 : 0)
                        }
                        .frame(width: max(w, 1))
                        .offset(x: x)
                }

                if let selection = model.selection {
                    let x = Double(selection.lowerBound) / Double(duration.rawValue) * width
                    let w = Double(selection.count) / Double(duration.rawValue) * width
                    Rectangle()
                        .fill(.primary.opacity(0.25))
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
                    .fill(.primary)
                    .frame(width: 2)
                    .offset(x: fraction(model.playhead, of: duration) * width - 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
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
            WaveformBars(
                heights: waveform.columnHeights(
                    columns: Int(width.rounded(.down)),
                    spanningSeconds: Double(duration.rawValue) / 1_000_000_000),
                height: height)
                .equatable()
            .frame(height: height)
            .allowsHitTesting(false)
        }
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

    private func nudge(by delta: Int64, duration: Nanoseconds) {
        let moved = min(max(model.playhead.rawValue + delta, 0), duration.rawValue)
        model.playhead = Nanoseconds(moved)
        // The clip under the playhead follows it, so ← / → walk the clips as well as the time.
        model.selectClip(atSource: model.playhead)
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
        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
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

            if model.hasEdits {
                Button("Revert all") {
                    model.restore()
                    onChange()
                }
            }
        }
        .buttonStyle(.link)
        .font(.caption)

        HStack(spacing: 8) {
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
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    // MARK: - strip geometry

    private func fraction(_ time: Nanoseconds, of duration: Nanoseconds) -> Double {
        guard duration.rawValue > 0 else { return 0 }
        return min(max(Double(time.rawValue) / Double(duration.rawValue), 0), 1)
    }

    /// **Named `sourcePosition`, not `time`.** `noAppSourceReadsAnAmbientValueAtAll` bans the
    /// spelling `time(` anywhere in the app, because that is how C's `time()` reads an ambient
    /// clock — the one thing `Minting` exists to be the sole owner of. The scan cannot tell a
    /// clock read from a coordinate conversion, and a ban that a reader has to except by hand
    /// is a ban that stops being read.
    private func sourcePosition(at x: Double, width: Double, duration: Nanoseconds) -> Nanoseconds {
        guard width > 0 else { return Nanoseconds(0) }
        let clamped = min(max(x / width, 0), 1)
        return Nanoseconds(Int64(clamped * Double(duration.rawValue)))
    }

    /// A screen distance as a span of the recording. The snap tolerance is defined in points
    /// so it feels the same on a 10-second recording and a 10-minute one.
    private func nanoseconds(forPoints points: Double, width: Double,
                             duration: Nanoseconds) -> Nanoseconds {
        guard width > 0 else { return Nanoseconds(0) }
        return Nanoseconds(Int64(points / width * Double(duration.rawValue)))
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
