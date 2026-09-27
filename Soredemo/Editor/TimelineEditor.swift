import Compositing
import Foundation
import Observation
import AppKit
import AVFoundation
import Framing
import SwiftUI
import Capture
import Overlays
import Project
import Timeline

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
    var chapters = ChapterTrack()

    /// How close a drag must come to an edge to snap, in POINTS. Converted to nanoseconds
    /// against the strip's own width, so the tolerance is the same distance on screen at any
    /// recording length rather than the same number of nanoseconds.
    private let snapPoints: Double = 8

    /// Below this, a clip's label would be truncated to nothing. A duration stamp is narrow, so
    /// this sits under the ~56 points a name would need.
    static let clipLabelMinimumWidth: Double = 44

    /// The header column's width. One number, because every lane's header and every lane's
    /// content have to start at the same x or the tracks do not line up — which is the single
    /// thing that makes a stack of strips read as a timeline.
    private static let headerWidth: Double = 84

    var body: some View {
        if let duration = model.duration, duration.rawValue > 0 {
            VStack(alignment: .leading, spacing: 2) {
                lane(nil, nil, height: 16) { ruler(duration: duration) }
                // Directly under the ruler, because a chapter is a point in time like a tick is,
                // and only while there are any — `Silence`'s reason.
                if !chapters.isEmpty {
                    lane("Chapters", "list.bullet.rectangle", height: 14) { chapterMarks }
                }
                lane("Video", "film", height: 44) {
                    ZStack(alignment: .topLeading) {
                        strip(duration: duration)
                        snapLine(height: 44)
                    }
                }
                // **Zooms get their own lane.** A review panel can reject a zoom but cannot
                // move one that is a quarter of a second late, which is the thing a person
                // actually wants to do — and moving it needs somewhere to drag it.
                // **Audio has its own lane now, and until it did the waveform was invisible.**
                // It was drawn inside the video strip, underneath the clip rectangles — which
                // are opaque, so it was covered on every frame it existed. A waveform behind
                // the picture track is a waveform nobody sees.
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
                // Same glyph as the Zooms tab and the review sheet, and deliberately NOT
                // the toolbar's magnifier, which zooms the timeline rather than the camera.
                lane("Zooms", "dot.viewfinder", height: 18) { zoomLane(duration: duration) }
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
                        // **Clicking a block moves the playhead to that cue**, which is the one
                        // connection the two surfaces were missing: the caption panel already
                        // lights and scrolls to the cue the playhead is in, so selecting follows
                        // from seeking rather than being a second kind of selection to keep in
                        // step with the first.
                        blocks(captions.cues.map { ($0.start, $0.end) },
                               tint: Theme.Lane.caption,
                               onTap: { index in
                                   guard captions.cues.indices.contains(index) else { return }
                                   model.movePlayhead(to: captions.cues[index].start)
                               })
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
            }
            // **One line down the whole stack, not a mark inside the picture track.** The strip
            // drew its own and no other lane did, so a zoom block, a caption and the waveform
            // could not be read against the position the preview was at — which is the entire
            // reason those lanes are stacked and aligned in the first place, and why the line
            // runs from the ruler to the bottom rather than sitting inside one lane.
            //
            // An overlay rather than a row in the stack: it has to cross the lane gaps, and it
            // must not take a hit test away from the strip underneath it.
            // Under the playhead, which must stay readable over it.
            .overlay(alignment: .topLeading) { exportRangeShade(duration: duration) }
            .overlay(alignment: .topLeading) { playheadLine(duration: duration) }
            // The editor's unmodified keys. Asked at the moment the key arrives, so a caption
            // field that has the caret keeps every one of them — see `BareKeys`.
            .bareKeys([.nudgeLeft, .nudgeRight, .coarseLeft, .coarseRight,
                       .split, .deleteClip, .markIn, .markOut]) {
                perform($0, duration: duration)
            }
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
        // **`AtPlayhead` OUTSIDE the `GeometryReader`, and the order was measured.** The first
        // version of this fix left the read where it is below, on the assumption that a
        // `GeometryReader`'s closure runs in its own update and so registers the dependency
        // there. `Self._printChanges()` said otherwise: `\TimelineEditorModel.playhead changed`
        // against `TimelineEditor`, 68 times in eight seconds of playback, with every other read
        // in this file already moved out. The closure is built during THIS body, and that is
        // where `@Observable` attributes what it touches.
        AtPlayhead(model: model) { playhead in
            playheadLine(duration: duration, at: playhead)
        }
    }

    @ViewBuilder private func playheadLine(duration: Nanoseconds,
                                           at playhead: Nanoseconds) -> some View {
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
                .offset(x: contentOrigin + fraction(playhead, of: duration) * track)
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
        _ title: LocalizedStringKey?, _ icon: String?, height: Double,
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
    /// least 64 points between labels. A fixed
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
                            Text(verbatim: Self.tickLabel(seconds, step: step))
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
    static func audioTrackName(_ index: Int) -> LocalizedStringKey {
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
    /// - Parameter onTap: what to do when a block is clicked, given its index. **Given the
    ///   BLOCK's index rather than the time under the pointer**: a lane of blocks is a list seen
    ///   sideways, and clicking one means "that one" — landing the playhead a few milliseconds
    ///   inside a caption would put it on the same cue but not at its start, which is where
    ///   somebody clicking it wants to hear from.
    @ViewBuilder private func blocks(_ spans: [(Nanoseconds, Nanoseconds)],
                                     tint: Color,
                                     onTap: ((Int) -> Void)? = nil) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.block).fill(Theme.Fill.track)
                ForEach(Array(spans.enumerated()), id: \.offset) { index, span in
                    let x = model.window.fraction(of: span.0) * width
                    let w = (model.window.fraction(of: span.1)
                             - model.window.fraction(of: span.0)) * width
                    RoundedRectangle(cornerRadius: Radius.block)
                        .fill(tint.opacity(0.75))
                        // **A hit target wider than the block when the block is a hairline.** At
                        // a whole-recording zoom a one-second caption is two points across, and
                        // a two-point target is one nobody can hit; the drawn width stays honest
                        // about the span while the tappable one does not go below a finger.
                        .frame(width: max(w, 2))
                        .contentShape(Rectangle().inset(by: -max(0, (8 - max(w, 2)) / 2)))
                        .offset(x: x)
                        .onTapGesture { onTap?(index) }
                }
            }
        }
    }

    /// A flag per chapter with its name beside it; tapping one puts the playhead there. Names
    /// are clipped rather than wrapped — the full name is in the Chapters tab.
    @ViewBuilder private var chapterMarks: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.block).fill(Theme.Fill.track)
                ForEach(chapters.chapters) { chapter in
                    let fraction = model.window.fraction(of: chapter.start)
                    if fraction >= 0, fraction <= 1 {
                        HStack(spacing: 2) {
                            Rectangle().fill(Theme.Lane.chapter).frame(width: 2)
                            Text(verbatim: chapter.title)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.Lane.chapter)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: max(24, (1 - fraction) * width), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .offset(x: fraction * width)
                        .onTapGesture { model.movePlayhead(to: chapter.start) }
                        .help(Text(verbatim: chapter.title))
                    }
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
                        // **A label inside the clip, when it fits.** A strip of unlabelled
                        // rectangles says how many clips there are and nothing else. Hidden
                        // below the width where it would be truncated to nothing, rather than
                        // squeezed — a clipped label is worse than none.
                        .overlay(alignment: .topLeading) {
                            if w > Self.clipLabelMinimumWidth {
                                Text(verbatim: clip.speed == 1 ? Self.stamp(clip.duration)
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
                        let threshold = snapThreshold(width: width, duration: duration)
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
                                      adjusted: model.isZoomAdjusted(derived.origin),
                                      width: max(w, 3), height: geometry.size.height,
                                      laneWidth: width, duration: duration, zoom: shown.zoom)
                            .offset(x: x)
                    }
                }
            }
        }
    }

    /// - Parameter adjusted: whether a person moved or resized this one.
    ///
    /// **A derived value should be visibly derived**, which this project argues everywhere else
    /// and this lane did not do: a block somebody dragged looked exactly like one the gate
    /// authored the moment they let go. Reviewing an automatic zoom means knowing which of them
    /// are still the machine's opinion.
    ///
    /// Marked with a bar along the bottom edge rather than a dot or a corner, because a block
    /// here can be three points wide — an edge survives that and a glyph does not.
    @ViewBuilder private func zoomBlockView(origin: HostInstant, suppressed: Bool,
                                            adjusted: Bool,
                                            width: Double, height: Double,
                                            laneWidth: Double, duration: Nanoseconds,
                                            zoom: Double = 1) -> some View {
        let held = model.draggingZoom == origin
        RoundedRectangle(cornerRadius: Radius.block)
            .fill(suppressed ? AnyShapeStyle(.clear)
                  : AnyShapeStyle(held ? Theme.Lane.zoom.opacity(0.95) : Theme.Lane.zoomBlock))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.block)
                    .strokeBorder(Theme.Lane.zoom, style: StrokeStyle(lineWidth: 1,
                                                            dash: suppressed ? [3, 2] : []))
            }
            // **How far it zooms, written on it.** Without a number a lane of identical
            // rectangles cannot say which zoom is gentle and which is close. Hidden when the
            // block is too narrow to hold it.
            .overlay {
                if width > 30, !suppressed {
                    Text(verbatim: FramingDepth.label(for: zoom))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Ink.onLane)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if adjusted, !suppressed {
                    Rectangle().fill(Theme.accent).frame(height: 2).allowsHitTesting(false)
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
                        let snap = snapThreshold(width: laneWidth, duration: duration)
                        if value.startLocation.x > width * 0.75 {
                            model.previewZoomResize(origin, byNanoseconds: signed, snapThreshold: snap)
                        } else {
                            model.previewZoomMove(origin, byNanoseconds: signed, snapThreshold: snap)
                        }
                    }
                    .onEnded { value in
                        model.commitZoomDrag(value.startLocation.x > width * 0.75
                                             ? "Resize Zoom" : "Move Zoom")
                        onChange()
                    }
            )
            .help(suppressed ? Text("This zoom is off. Click to turn it back on.")
                  : adjusted
                      ? Text("You moved this zoom. Drag to move it again, drag the right edge to change how long it lasts, click to turn it off.")
                      : Text("Derived from a click. Drag to move, drag the right edge to change how long it lasts, click to turn it off."))
            .accessibilityLabel(suppressed ? Text("Zoom, off")
                                : adjusted ? Text("Zoom, adjusted") : Text("Zoom, derived from a click"))
    }

    /// One edge of the selected clip, draggable.
    ///
    /// **Wider than it looks.** The visible line is 2 points; the hit area is 12, roughly the
    /// smallest target a person hits reliably with a trackpad. A handle you can see but cannot
    /// grab is worse than no handle.
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
                        model.previewTrim(of: clip.id, edge: edge, byNanoseconds: delta.rawValue,
                                          snapThreshold: snapThreshold(width: width, duration: duration))
                    }
                    .onEnded { _ in
                        model.commitTrim(edge: edge)
                        onChange()
                    }
            )
            .onHover { inside in
                // The cursor is the only thing that says a 2-point line is draggable before a
                // person tries it.
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    /// Roughly the smallest target a trackpad hits reliably; see `trimHandle`.
    private let handleHitWidth: Double = 12

    /// The last cumulative magnification a pinch reported, so each change advances the window
    /// by the DELTA. `MagnifyGesture` reports the total since the pinch began; feeding that in
    /// directly compounds it and the strip zooms exponentially under the fingers.
    @State private var lastMagnification: Double = 1

    /// Runs one of the editor's unmodified keys.
    ///
    /// **These were zero-opacity `Button`s with `.keyboardShortcut`, and that was measured
    /// wrong.** The comment on them said a `Button`'s shortcut is the only thing that respects
    /// the responder chain. Driven with synthesised events against a caption field that had the
    /// caret, all six were taken and none reached the field: a caption could not take the
    /// letter `s`, its caret could not be moved, and backspace deleted nothing. `unlessTyping`
    /// only stopped the action, so the key did nothing at all rather than the wrong thing —
    /// which is what "the arrow keys sometimes stop working" was. See `BareKeys`.
    private func perform(_ action: BareKeys.Action, duration: Nanoseconds) {
        switch action {
        case .nudgeLeft: nudge(by: -Self.frameStep, duration: duration)
        case .nudgeRight: nudge(by: Self.frameStep, duration: duration)
        case .coarseLeft: nudge(by: -Self.secondStep, duration: duration)
        case .coarseRight: nudge(by: Self.secondStep, duration: duration)
        case .split:
            guard model.canSplitAtPlayhead else { return }
            model.splitAtPlayhead()
            onChange()
        case .deleteClip:
            guard model.selectedClip != nil else { return }
            model.deleteSelectedClip()
            onChange()
        case .markIn: model.markIn()
        case .markOut: model.markOut()
        // Not this view's: the player is the transport bar's. Listed so a case added to
        // `BareKeys.Action` cannot be forgotten here — the handler above declines it anyway.
        case .togglePlay: break
        }
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
            // **The timecode is the whole reason this timeline used to rebuild during playback.**
            // Reading `model.playhead` in a `@ViewBuilder` method of this struct is a read by
            // THIS body, so one `Text` dragged every lane, every clip, every caption block and
            // the waveform through a fresh layout ten times a second. See `AtPlayhead`.
            AtPlayhead(model: model) { Text(verbatim: Self.stamp($0)) }
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
            // **`canSplitAtPlayhead` reads the playhead**, so `.disabled` on it is a read by
            // this body — the last one in this file, and the one that kept the whole timeline
            // rebuilding after the other four were moved. Found with `Self._printChanges()`,
            // not by reading: four rounds of "surely that is the last one" had already been
            // wrong. See `AtPlayhead`.
            // **`S`, `Delete`, `I` and `O` are not here any more, and could not be.** They are
            // unmodified — the spelling every editor uses for split, delete, mark in and mark
            // out — and a `.keyboardShortcut` on an unmodified key is taken from a caption
            // field that has the caret. They live in `BareKeys` now, which is asked at the
            // moment the key arrives and declines while somebody is typing. What stays here is
            // everything carrying ⌘ or ⌥, which SwiftUI does exempt.
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
    /// How near counts as lining up: `snapPoints` of screen at the strip's current zoom, or
    /// nothing while ⌘ is held — the key editors use for "put it exactly where my hand is".
    private func snapThreshold(width: Double, duration: Nanoseconds) -> Nanoseconds {
        NSEvent.modifierFlags.contains(.command) ? Nanoseconds(0)
            : nanoseconds(forPoints: snapPoints, width: width, duration: duration)
    }

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
/// **Internal, not private: two lanes draw a waveform and there is one way to do it.**
/// The timeline draws the recording's audio under its clips; `CaptionWaveform` draws the same
/// audio under a block per cue. A second copy would be a second set of bar widths, a second
/// silence rule, and eventually two waveforms of the same recording that did not agree.
struct WaveformBars: View, Equatable {
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
