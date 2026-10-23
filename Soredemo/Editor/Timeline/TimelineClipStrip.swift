import AppKit
import SwiftUI
import Timeline

/// The video lane: kept spans filled, cut spans hollow, the frames inside each clip, a drag-out
/// selection, and the selected clip's trim handles.
struct TimelineClipStrip: View {
    let model: TimelineEditorModel
    /// The frames drawn along the track. Owned by the host so it survives a rebuild of this view
    /// — a cache discarded on every edit would re-decode the whole strip per keystroke.
    let filmstrip: Filmstrip?
    /// Called after a trim, so the host rebuilds the composition and the preview follows.
    let onChange: () -> Void

    /// Below this, a clip's label would be truncated to nothing. A duration stamp is narrow, so
    /// this sits under the ~56 points a name would need.
    static let clipLabelMinimumWidth: Double = 44

    /// Roughly the smallest target a trackpad hits reliably; see `trimHandle`.
    private static let handleHitWidth: Double = 12

    /// The last cumulative magnification a pinch reported, so each change advances the window
    /// by the DELTA. `MagnifyGesture` reports the total since the pinch began; feeding that in
    /// directly compounds it and the strip zooms exponentially under the fingers.
    @State private var lastMagnification: Double = 1

    var body: some View {
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
                    clipView(clip, width: width, height: geometry.size.height)
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
                    trimHandle(for: clip, edge: .start, width: width)
                    trimHandle(for: clip, edge: .end, width: width)
                }

                // **The strip's own playhead is gone, and its absence is the point.** The
                // full-height line over every lane was added because "the strip drew its own
                // and no other lane did" — and then this was left in place, so the editor drew
                // two, eight points apart, from two different origins. One line, over every lane.
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
                        guard let scale = TimelineScale(window: model.window, width: width)
                        else { return }
                        let threshold = scale.snapThreshold(exact: TimelineLayout.isExact)
                        let start = model.snapped(scale.position(atX: value.startLocation.x),
                                                  threshold: threshold)
                        let now = model.snapped(scale.position(atX: value.location.x),
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
        .overlay(alignment: .topLeading) { snapLine }
    }

    @ViewBuilder private func clipView(_ clip: EditClip, width: Double, height: Double) -> some View {
        let x = model.window.fraction(of: clip.sourceStart) * width
        // The DURATION's width, which is a span rather than a position — the window's
        // `fraction` measures from its start, so a length has to be measured as the difference
        // between two positions.
        let w = (model.window.fraction(of: clip.sourceEnd)
                 - model.window.fraction(of: clip.sourceStart)) * width
        let isSelected = clip.id == model.selectedClip
        RoundedRectangle(cornerRadius: Radius.strip)
            .fill(Theme.Lane.video.opacity(isSelected ? 0.55 : 0.35))
            // **The frames go INSIDE the clip, clipped to it.** Drawn behind, they would show
            // through the gaps a cut leaves and a removed span would still have a picture in
            // it — which is the opposite of what a cut means. `clipShape` is what makes the
            // strip say what survives.
            .overlay {
                filmstripLayer(from: clip.sourceStart, to: clip.sourceEnd,
                               width: w, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.strip))
            }
            .overlay {
                // The selected clip is outlined rather than recoloured: the fill already
                // carries "this is kept footage", and a second colour there would make
                // selection and keptness the same channel.
                RoundedRectangle(cornerRadius: Radius.strip)
                    .strokeBorder(Theme.Ink.primary, lineWidth: isSelected ? 2 : 0)
            }
            // **A label inside the clip, when it fits.** A strip of unlabelled rectangles says
            // how many clips there are and nothing else. Hidden below the width where it would
            // be truncated to nothing, rather than squeezed — a clipped label is worse than none.
            .overlay(alignment: .topLeading) {
                if w > Self.clipLabelMinimumWidth {
                    Text(verbatim: clip.speed == 1 ? TimelineEditor.stamp(clip.duration)
                         : "\(TimelineEditor.stamp(clip.duration)) \u{00B7} "
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

    /// One edge of the selected clip, draggable.
    ///
    /// **Wider than it looks.** The visible line is 2 points; the hit area is 12, roughly the
    /// smallest target a person hits reliably with a trackpad. A handle you can see but cannot
    /// grab is worse than no handle.
    @ViewBuilder private func trimHandle(for clip: EditClip, edge: TimelineEditorModel.TrimEdge,
                                         width: Double) -> some View {
        let at = edge == .start ? clip.sourceStart : clip.sourceEnd
        let x = model.window.fraction(of: at) * width
        Rectangle()
            .fill(.primary)
            .frame(width: 2)
            .frame(width: Self.handleHitWidth)          // the grab area, not the drawn line
            .contentShape(Rectangle())
            .offset(x: x - Self.handleHitWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard let scale = TimelineScale(window: model.window, width: width)
                        else { return }
                        model.previewTrim(of: clip.id, edge: edge,
                                          byNanoseconds: scale.offset(forPoints: value.translation.width),
                                          snapThreshold: scale.snapThreshold(exact: TimelineLayout.isExact))
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

    /// The line a snap took hold at. Drawn over the video track rather than across every lane:
    /// the thing being snapped is on that track, and a full-height line would be a second
    /// playhead.
    @ViewBuilder private var snapLine: some View {
        if let snap = model.snapIndicator {
            GeometryReader { geometry in
                let x = model.window.fraction(of: snap) * geometry.size.width
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 1)
                    .offset(x: x)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 3)
            }
            .allowsHitTesting(false)
        }
    }
}
