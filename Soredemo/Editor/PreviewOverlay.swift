import Overlays
import Render
import SwiftUI
import Timeline

/// Handles drawn over the preview, for the things that have a position.
///
/// **Two sliders is not how anyone places a title.** Positioning a caption or a redaction by
/// dragging numbers means looking away from the thing being positioned, moving a value, looking
/// back, and repeating. A transform overlay and a crop overlay exist for
/// exactly this; every editor worth copying lets you grab the thing itself.
///
/// **The video's rectangle is computed, not asked for.** `AVPlayerView` letterboxes with
/// `.resizeAspect`, so the picture is the output's aspect fitted and centred inside the view —
/// which is a formula, not a secret. Reading `videoBounds` off the player view would need the
/// representable to publish it and would be the same number arrived at less directly.
struct PreviewOverlay: View {
    /// Where the camera was when its drag began, as the style's own fractions. **`nil` between
    /// drags, which is what makes the next one take its own origin** — see the drag itself for
    /// what reading the origin back out of the moving thing cost.
    @State private var cameraDragOrigin: CameraPlacement?
    let outputWidth: Int
    let outputHeight: Int
    let texts: TextOverlaysModel
    let redactions: RedactionsModel
    /// Which inspector tab is showing, so the overlay only offers handles for what is being
    /// edited — a redaction handle on screen while a person is writing a caption is a handle
    /// they will grab by accident.
    let tab: StageWindow.InspectorTab
    let onChange: () -> Void
    /// Where the camera sits, so it can be dragged on the picture rather than aimed with two
    /// sliders. `nil` when the recording has no camera, which is when there is nothing to drag.
    var cameraStyle: Binding<CameraOverlayStyle>?
    var hasCamera = false

    var body: some View {
        GeometryReader { geometry in
            let video = Self.videoRect(in: geometry.size.width, geometry.size.height,
                                       outputWidth: outputWidth, outputHeight: outputHeight)
            ZStack(alignment: .topLeading) {
                // **Not hit-testable, so the empty area passes clicks to the picture.** It is
                // here to give the `ZStack` a size, not to catch anything — and `Color.clear`
                // does catch clicks, unlike `EmptyView`.
                //
                // This replaces a gate on the whole overlay that switched it off unless a TEXT
                // or a REDACTION was selected. The camera handle is not either of those, so it
                // was drawn and could not be grabbed: visibly there, inert. Handling it here
                // fixes the problem where it is rather than by naming every handle in a list
                // that the next one would have to be added to.
                Color.clear.allowsHitTesting(false)
                switch tab {
                case .text:
                    if let item = texts.selected { textHandle(item, in: video) }
                case .hide:
                    if let item = redactions.selected { redactionHandle(item, in: video) }
                default:
                    EmptyView()
                }
                // **The camera is dragged on the picture, in every tab.** Nine presets is nine
                // answers to a question with infinitely many, and the two sliders beside them
                // are aimed by watching a number rather than the face. Not gated on the tab like
                // the handles above, because the camera is not being "edited" in a panel — it is
                // an object on the stage, and grabbing it is the obvious thing to try.
                if hasCamera, let cameraStyle { cameraHandle(cameraStyle, in: video) }
            }
        }
    }

    /// The picture's rectangle inside a view of `width` × `height`, fitted and centred.
    static func videoRect(in width: Double, _ height: Double,
                          outputWidth: Int, outputHeight: Int)
    -> (x: Double, y: Double, width: Double, height: Double) {
        guard width > 0, height > 0, outputWidth > 0, outputHeight > 0 else {
            return (0, 0, max(width, 1), max(height, 1))
        }
        let outputAspect = Double(outputWidth) / Double(outputHeight)
        let viewAspect = width / height
        if viewAspect > outputAspect {
            let fitted = height * outputAspect
            return ((width - fitted) / 2, 0, fitted, height)
        }
        let fitted = width / outputAspect
        return (0, (height - fitted) / 2, width, fitted)
    }

    // MARK: - text

    /// A draggable puck at the text's anchor.
    ///
    /// **`y` runs from the BOTTOM in `TextOverlayStyle` and downward on screen**, so the drag
    /// subtracts where the position adds. Getting that backwards moves a title the wrong way
    /// when dragged, which is the kind of thing that reads as the app being broken.
    @ViewBuilder private func textHandle(_ item: TextItem,
                                         in video: (x: Double, y: Double, width: Double, height: Double))
    -> some View {
        let x = video.x + item.style.x * video.width
        let y = video.y + (1 - item.style.y) * video.height
        HandlePuck(label: item.text.components(separatedBy: "\n").first ?? "Text",
                   tint: Theme.Lane.text)
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        var updated = item
                        updated.style = item.style.changing(
                            x: (Double(value.location.x) - video.x) / video.width,
                            y: 1 - (Double(value.location.y) - video.y) / video.height)
                        texts.update(updated)
                        onChange()
                    })
    }

    // MARK: - redactions

    /// The region's own rectangle, moved by dragging inside it and resized from its corner.
    @ViewBuilder private func redactionHandle(_ item: RedactionItem,
                                              in video: (x: Double, y: Double, width: Double, height: Double))
    -> some View {
        // A redaction's `y` runs from the TOP — it is a rectangle picked off a picture — so
        // unlike the text handle above, nothing is flipped here.
        let x = video.x + item.region.x * video.width
        let y = video.y + item.region.y * video.height
        let w = max(item.region.width * video.width, 8)
        let h = max(item.region.height * video.height, 8)

        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Theme.Lane.hide.opacity(0.16))
                .overlay {
                    Rectangle().strokeBorder(Theme.Lane.hide, style: StrokeStyle(
                        lineWidth: 1.5, dash: [5, 3]))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            move(item, to: Double(value.location.x), Double(value.location.y),
                                 in: video, grabbedWidth: w, grabbedHeight: h)
                        })
            Circle()
                .fill(Theme.Lane.hide)
                .frame(width: 12, height: 12)
                .offset(x: 6, y: 6)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            resize(item, cornerX: Double(value.location.x) + x,
                                   cornerY: Double(value.location.y) + y, in: video)
                        })
        }
        .frame(width: w, height: h)
        .offset(x: x, y: y)
    }

    private func move(_ item: RedactionItem, to pointX: Double, _ pointY: Double,
                      in video: (x: Double, y: Double, width: Double, height: Double),
                      grabbedWidth: Double, grabbedHeight: Double) {
        // The drag's location is inside the rectangle, so the rectangle's ORIGIN is that point
        // less where it was grabbed — the alternative pins the corner to the pointer and the
        // region jumps on the first pixel of every drag.
        let originX = (pointX - grabbedWidth / 2 - video.x) / video.width
        let originY = (pointY - grabbedHeight / 2 - video.y) / video.height
        var updated = item
        updated.region = RedactionRegion(id: item.region.id, x: originX, y: originY,
                                         width: item.region.width, height: item.region.height,
                                         style: item.region.style, isOval: item.region.isOval)
        redactions.update(updated)
        onChange()
    }

    private func resize(_ item: RedactionItem, cornerX: Double, cornerY: Double,
                        in video: (x: Double, y: Double, width: Double, height: Double)) {
        let width = (cornerX - video.x) / video.width - item.region.x
        let height = (cornerY - video.y) / video.height - item.region.y
        var updated = item
        updated.region = RedactionRegion(id: item.region.id, x: item.region.x, y: item.region.y,
                                         width: max(width, 0.01), height: max(height, 0.01),
                                         style: item.region.style, isOval: item.region.isOval)
        redactions.update(updated)
        onChange()
    }
}

/// The grab target for a positioned thing: a dot, and the thing's name beside it.
///
/// **Bigger than it looks.** The visible dot is 12 points and the hit area is 34, because a
/// target the size of what it draws is one people miss — the same reason `SplitHandle` is seven
/// points tall for a one-point line.
private struct HandlePuck: View {
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: Space.tight) {
            Circle()
                .fill(tint)
                .frame(width: 12, height: 12)
                .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, Space.tight + 1)
                .padding(.vertical, 1)
                .background(Capsule().fill(.black.opacity(0.55)))
        }
        .padding(11)
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(0.4), radius: 4)
    }
}

/// A camera position as the style keeps it: fractions of the output, y measured UP.
struct CameraPlacement: Equatable {
    var x: Double
    var y: Double
}

extension PreviewOverlay {
    /// The style's authored position. **Not where the camera is drawn**: `rect` clamps that to
    /// the edge margin, and a drag that started from the clamped value would lose whatever the
    /// clamp had taken off.
    func placement(of style: CameraOverlayStyle) -> CameraPlacement {
        let fractions = style.position?.fractions ?? (x: style.x, y: style.y)
        return CameraPlacement(x: fractions.x, y: fractions.y)
    }

    /// The camera's own rectangle on the preview, draggable, with a corner to resize by.
    ///
    /// **Placed through `CameraOverlayStyle.rect`, not by repeating its arithmetic.** That
    /// function already decides where the camera goes, including the margin that keeps it inside
    /// the frame and the shrink a zoom applies; a second copy here would be a handle that sits
    /// where the camera is not.
    @ViewBuilder func cameraHandle(_ style: Binding<CameraOverlayStyle>,
                                   in video: (x: Double, y: Double,
                                              width: Double, height: Double)) -> some View {
        // The source aspect is unknown here — the camera's file is not loaded by this view — so
        // 16:9 stands in. It only affects a rectangular camera's height, and the handle is a grab
        // target rather than a preview of the picture.
        let box = style.wrappedValue.rect(inOutputWidth: outputWidth, outputHeight: outputHeight,
                                          sourceAspect: 16.0 / 9)
        let scale = video.width / Double(max(outputWidth, 1))
        // `rect`'s y runs UP from the bottom and the view's runs down, so it is flipped once here.
        let onScreen = (x: video.x + box.x * scale,
                        y: video.y + (Double(outputHeight) - box.y - box.height) * scale,
                        width: box.width * scale,
                        height: box.height * scale)

        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.9), lineWidth: 1.5)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let width = max(video.width, 1), height = max(video.height, 1)
                            // **The position the drag started from, remembered — not read back
                            // out of the thing the drag is moving.** `translation` is cumulative,
                            // and this used to add it to a `startX` derived from `box`, which is
                            // derived from the style this very closure rewrites on every change.
                            // The base advanced with the camera, so the camera moved at roughly
                            // twice the pointer and slammed into the edge margin, where it stuck:
                            // reported as "it will not drag any further before it reaches the
                            // edge". The comment above it already named this mistake, having been
                            // written about a different drag. Third time in this app.
                            let origin = cameraDragOrigin ?? placement(of: style.wrappedValue)
                            cameraDragOrigin = origin
                            let x = origin.x + Double(value.translation.width) / width
                            let y = origin.y - Double(value.translation.height) / height
                            // **Clamped to where the camera can actually GO**, which the style
                            // itself answers — the same function `rect` clamps with. Clamping to
                            // 0...1 here let the handle accept travel the camera could not make,
                            // so the last part of every drag toward an edge did nothing.
                            let reach = style.wrappedValue.placementRange(
                                inOutputWidth: outputWidth, outputHeight: outputHeight,
                                sourceAspect: 16.0 / 9)
                            style.wrappedValue = style.wrappedValue.changing(
                                x: min(max(x, reach.x.lowerBound), reach.x.upperBound),
                                y: min(max(y, reach.y.lowerBound), reach.y.upperBound))
                            // **While dragging, not when the drag ends.** The style reaches
                            // `StageCompositor` on every change already; what a PAUSED player
                            // needs is a reason to redraw the frame it is showing, and that is
                            // what `onChange` asks for. Deferring it to `onEnded` meant the
                            // camera followed the pointer as a blue outline while the picture
                            // underneath stayed where it was until you let go.
                            onChange()
                        }
                        .onEnded { _ in
                            cameraDragOrigin = nil
                            onChange()
                        }
                )

            // The corner that resizes. Bottom-trailing because that is where every resize grip
            // on this system is, and because the camera's usual home is the opposite corner.
            Circle()
                .fill(Theme.accent)
                .frame(width: 10, height: 10)
                .offset(x: 5, y: 5)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let widened = box.width + Double(value.translation.width) / scale
                            style.wrappedValue = style.wrappedValue.changing(
                                widthFraction: widened / Double(max(outputWidth, 1)))
                            onChange()
                        }
                        .onEnded { _ in onChange() }
                )
        }
        .frame(width: onScreen.width, height: onScreen.height)
        .offset(x: onScreen.x, y: onScreen.y)
    }
}
