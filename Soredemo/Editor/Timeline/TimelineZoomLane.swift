import Capture
import Framing
import SwiftUI
import Timeline

/// The derived zooms as draggable blocks.
///
/// **Zooms get their own lane.** A review panel can reject a zoom but cannot move one that is a
/// quarter of a second late, which is the thing a person actually wants to do — and moving it
/// needs somewhere to drag it.
///
/// Drag the body to move a zoom, either edge to change when it starts or ends, and click to turn
/// it off. **Under the blocks, the camera's own move** — how far in it is at each moment, from
/// the path the renderer reads (`ZoomCurve`) — so arriving, holding, going back out and panning
/// between two close blocks are on the lane rather than inferred from rectangles. A suppressed zoom is drawn hollow rather than removed: a person needs to see that
/// there WAS a zoom here in order to bring it back, and a lane that erased it would make "no
/// zoom" and "never had one" look the same.
struct TimelineZoomLane: View {
    let model: TimelineEditorModel
    /// Called after a zoom is moved, resized or switched, so the preview follows.
    let onChange: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.block).fill(Theme.Fill.track)
                ZoomCurve(model: model, width: width, height: geometry.size.height)

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
                        block(origin: derived.origin, suppressed: suppressed,
                              adjusted: model.isZoomAdjusted(derived.origin),
                              width: max(w, 3), height: geometry.size.height,
                              laneWidth: width, zoom: shown.zoom)
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
    @ViewBuilder private func block(origin: HostInstant, suppressed: Bool, adjusted: Bool,
                                    width: Double, height: Double, laneWidth: Double,
                                    zoom: Double) -> some View {
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
                        guard let scale = TimelineScale(window: model.window, width: laneWidth)
                        else { return }
                        let signed = scale.offset(forPoints: value.translation.width)
                        let snap = scale.snapThreshold(exact: TimelineLayout.isExact)
                        switch Self.drag(startingAt: value.startLocation.x, width: width) {
                        case .move:
                            model.previewZoomMove(origin, byNanoseconds: signed, snapThreshold: snap)
                        case .resizeStart:
                            model.previewZoomResizeStart(origin, byNanoseconds: signed, snapThreshold: snap)
                        case .resizeEnd:
                            model.previewZoomResize(origin, byNanoseconds: signed, snapThreshold: snap)
                        }
                    }
                    .onEnded { value in
                        model.commitZoomDrag(Self.drag(startingAt: value.startLocation.x, width: width))
                        onChange()
                    }
            )
            .help(suppressed ? Text("This zoom is off. Click to turn it back on.")
                  : adjusted
                      ? Text("You moved this zoom. Drag to move it again, drag an edge to change when it starts or ends, click to turn it off.")
                      : Text("Derived from a click. Drag to move, drag an edge to change when it starts or ends, click to turn it off."))
            .accessibilityLabel(suppressed ? Text("Zoom, off")
                                : adjusted ? Text("Zoom, adjusted") : Text("Zoom, derived from a click"))
    }

    /// Which drag a press starts, from where on the block it lands.
    ///
    /// **One gesture, three meanings, decided by where it began** — the convention every
    /// timeline uses, and cheaper than separate handles on a block that can be three points
    /// wide. The outer quarters are the edges; a block too narrow to hold three zones a person
    /// can aim at only moves.
    static func drag(startingAt x: Double, width: Double) -> TimelineEditorModel.ZoomDrag {
        guard width >= minimumWidthForEdges else { return .move }
        if x < width * 0.25 { return .resizeStart }
        if x > width * 0.75 { return .resizeEnd }
        return .move
    }

    static let minimumWidthForEdges: Double = 18
}

/// The camera's depth along the lane: one bar per point of width, as tall as the zoom is deep.
///
/// **Read from `CameraMotion.zoomProfile`**, the same baked path the renderer answers from, so
/// the curve's timing is the picture's. Its height is relative — the deepest zoom in view fills
/// the lane — and it is built without the output's zoom ceiling, which the compositor learns
/// only from the export's card: under a ceiling the picture goes less far in than the curve
/// shows, never at a different time. `docs/design/2026-10-25-the-zoom-lane-draws-the-camera.md`.
///
/// Bars rather than a path, because architecture rule 5 keeps CoreGraphics geometry out of this
/// tier — the arrangement `WaveformBars` uses for audio.
private struct ZoomCurve: View {
    let model: TimelineEditorModel
    let width: Double
    let height: Double

    var body: some View {
        let heights = model.zoomCurve(columns: Int(width.rounded(.down)))
        ZStack(alignment: .bottomLeading) {
            ForEach(heights.indices, id: \.self) { column in
                let bar = heights[column] * height
                if bar > 0.5 {
                    Rectangle()
                        .fill(Theme.Lane.zoom.opacity(0.28))
                        .frame(width: 1, height: bar)
                        .offset(x: Double(column))
                }
            }
        }
        .frame(width: width, height: height, alignment: .bottomLeading)
        .drawingGroup()
        .allowsHitTesting(false)
    }
}
