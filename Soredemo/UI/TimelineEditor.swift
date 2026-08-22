import Compositing
import Foundation
import Observation
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
    private(set) var edit = EditTimeline(clips: [])
    /// Where the playhead sits, in SOURCE time.
    var playhead = Nanoseconds(0)
    /// The span a person has dragged out, in SOURCE time, or `nil` for no selection.
    var selection: Range<Int64>?
    /// The clip a person clicked, or `nil`. **Kept as an identity, never an index**: deleting
    /// an earlier clip would silently move an index onto a different clip, which is the fault
    /// `ClipID` exists to prevent.
    private(set) var selectedClip: ClipID?
    /// Kept so "Undo all edits" restores the recording rather than guessing at it.
    private var original = EditTimeline(clips: [])
    /// Carried across the events of one drag so a snap holds instead of flickering.
    private var snapState = SnapEngine.State()

    func load(duration seconds: Double) {
        let total = Nanoseconds(Int64(seconds * 1_000_000_000))
        duration = total
        edit = EditTimeline.whole(duration: total)
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
        edit = split
        publish()
    }

    var canSplitAtPlayhead: Bool {
        edit.outputTime(atSource: playhead).map { edit.split(atOutput: $0) != nil } ?? false
    }

    /// Deletes the selected clip. The clips after it move earlier on their own — a clip's
    /// output position is the sum of the durations before it, so there is no gap to close.
    func deleteSelectedClip() {
        guard let selectedClip else { return }
        edit = edit.removing(id: selectedClip)
        self.selectedClip = nil
        publish()
    }

    func removeSelection() {
        guard let selection else { return }
        edit = edit.removing(sourceRange: selection)
        self.selection = nil
        publish()
    }

    func keepOnlySelection() {
        guard let selection else { return }
        edit = edit.trimmed(toSource: selection)
        self.selection = nil
        publish()
    }

    func restore() {
        edit = original
        selection = nil
        selectedClip = nil
        publish()
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

            Button("Delete clip") {
                model.deleteSelectedClip()
                onChange()
            }
            .disabled(model.selectedClip == nil)

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
                Button("Undo all edits") {
                    model.restore()
                    onChange()
                }
            }
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
