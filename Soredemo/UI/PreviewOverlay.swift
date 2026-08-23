import Overlays
import Render
import SwiftUI
import Timeline

/// Handles drawn over the preview, for the things that have a position.
///
/// **Two sliders is not how anyone places a title.** Positioning a caption or a redaction by
/// dragging numbers means looking away from the thing being positioned, moving a value, looking
/// back, and repeating. a native editor has a `TransformOverlayView` and a `CropOverlayView` for
/// exactly this; every editor worth copying lets you grab the thing itself.
///
/// **The video's rectangle is computed, not asked for.** `AVPlayerView` letterboxes with
/// `.resizeAspect`, so the picture is the output's aspect fitted and centred inside the view —
/// which is a formula, not a secret. Reading `videoBounds` off the player view would need the
/// representable to publish it and would be the same number arrived at less directly.
struct PreviewOverlay: View {
    let outputWidth: Int
    let outputHeight: Int
    let texts: TextOverlaysModel
    let redactions: RedactionsModel
    /// Which inspector tab is showing, so the overlay only offers handles for what is being
    /// edited — a redaction handle on screen while a person is writing a caption is a handle
    /// they will grab by accident.
    let tab: StageWindow.InspectorTab
    let onChange: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let video = Self.videoRect(in: geometry.size.width, geometry.size.height,
                                       outputWidth: outputWidth, outputHeight: outputHeight)
            ZStack(alignment: .topLeading) {
                Color.clear
                switch tab {
                case .text:
                    if let item = texts.selected { textHandle(item, in: video) }
                case .hide:
                    if let item = redactions.selected { redactionHandle(item, in: video) }
                default:
                    EmptyView()
                }
            }
        }
        // The overlay must not swallow clicks meant for the picture when nothing is selected.
        .allowsHitTesting(hasHandle)
    }

    private var hasHandle: Bool {
        switch tab {
        case .text: texts.selected != nil
        case .hide: redactions.selected != nil
        default: false
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
