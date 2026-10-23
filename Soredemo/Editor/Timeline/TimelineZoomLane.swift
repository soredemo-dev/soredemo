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
/// Drag the body to move a zoom, the right edge to change how long it lasts, and click to turn
/// it off. A suppressed zoom is drawn hollow rather than removed: a person needs to see that
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
                        // A drag that started in the right quarter resizes; anywhere else moves.
                        // One gesture, two meanings, decided by where it began — the same
                        // convention every timeline uses, and cheaper than a separate handle on
                        // a block that can be three points wide.
                        let snap = scale.snapThreshold(exact: TimelineLayout.isExact)
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
}
