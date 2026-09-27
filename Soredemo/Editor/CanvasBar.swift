import Capture
import Geometry
import Render
import SwiftUI
import Variants

/// The strip above the preview: what shape the export is, and what part of the recording it uses.
///
/// **These two were in the inspector, three tabs deep.** A canvas preset and
/// its crop button directly over the picture — "YouTube / 桌面 16:9" and a crop icon — and the
/// reason is that both are decisions about the frame you are looking at. A control that changes
/// what is on screen belongs beside what is on screen.
struct CanvasBar: View {
    @Binding var variant: AspectVariant
    @Binding var crop: CropRect
    @Binding var isCropping: Bool
    /// Whether the safe-frame guides are drawn over the preview. Beside Crop because both are
    /// about the SHAPE of the export rather than about what is in it.
    @Binding var showsSafeFrame: Bool
    let outputWidth: Int
    let outputHeight: Int
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: Space.regular) {
            Picker("", selection: $variant) {
                ForEach(AspectVariant.all, id: \.self) { shape in
                    Self.label(shape).tag(shape)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .tooltip("The shape of the export")

            Text(verbatim: "\(outputWidth)\u{00D7}\(outputHeight)")
                .font(Type.readout)
                .foregroundStyle(Theme.Ink.tertiary)

            Divider().frame(height: 16).overlay(Theme.Line.hairline)

            Toggle(isOn: $isCropping) {
                Label("Crop", systemImage: "crop")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(Theme.accent)
            .tooltip("Choose the part of the recording to use")

            Toggle(isOn: $showsSafeFrame) {
                Label("Guides", systemImage: "square.dashed")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(Theme.accent)
            .tooltip("Show where captions may be cut off or covered")

            if !crop.isWhole {
                Text(verbatim: Self.cropLabel(crop))
                    .font(Type.readout)
                    .foregroundStyle(Theme.Ink.accent)
                Button("Reset") {
                    crop = .whole
                    onChange()
                }
                .controlSize(.small)
                .tooltip("Use the whole recording again")
            }

            Spacer()
        }
        .padding(.horizontal, Space.regular)
        .frame(height: 32)
        .background(Theme.Surface.raised)
    }

    /// `Landscape 16:9` — the name a person chose it by, and the ratio they recognise it by.
    static func label(_ variant: AspectVariant) -> Text {
        let size = variant.dimensions(longestEdge: 1920)
        let ratio = ratio(width: size.width, height: size.height)
        return Text("\(Text(LocalizedStringKey(variant.name))) \u{00B7} \(ratio)")
    }

    /// The aspect as a small whole-number ratio. **Reduced by the greatest common divisor**, so
    /// 1920×1080 reads as 16:9 rather than as 1.78 — which is the form on every preset menu in
    /// every editor, because it is the form people say out loud.
    static func ratio(width: Int, height: Int) -> String {
        let divisor = greatestCommonDivisor(width, height)
        guard divisor > 0 else { return "\(width):\(height)" }
        return "\(width / divisor):\(height / divisor)"
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// How much of the recording survives, as a percentage of each edge — the number a person
    /// uses to decide whether they cropped too far.
    static func cropLabel(_ crop: CropRect) -> String {
        "\(Int((crop.width * 100).rounded()))% \u{00D7} \(Int((crop.height * 100).rounded()))%"
    }
}

/// The crop's handles, over the preview.
///
/// **Drawn in the PICTURE's rectangle, not the view's.** The preview letterboxes, so the part of
/// the view showing the recording is the fitted rectangle `PreviewOverlay.videoRect` computes —
/// and a crop drawn against the view would be off by the letterbox on every non-matching aspect.
struct CropOverlay: View {
    @Binding var crop: CropRect
    let outputWidth: Int
    let outputHeight: Int
    let onCommit: () -> Void

    @State private var applied: (x: Double, y: Double) = (0, 0)

    var body: some View {
        GeometryReader { geometry in
            let video = PreviewOverlay.videoRect(in: geometry.size.width, geometry.size.height,
                                                 outputWidth: outputWidth,
                                                 outputHeight: outputHeight)
            let box = (x: video.x + crop.x * video.width,
                       y: video.y + crop.y * video.height,
                       width: crop.width * video.width,
                       height: crop.height * video.height)
            ZStack(alignment: .topLeading) {
                // Everything outside the crop, dimmed. Four rectangles rather than a mask,
                // because a mask would need a shape difference and this needs four rectangles.
                Color.black.opacity(0.5)
                    .mask(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                            Rectangle()
                                .frame(width: box.width, height: box.height)
                                .offset(x: box.x, y: box.y)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.x, y: box.y)
                    .allowsHitTesting(false)

                CropHandle()
                    .position(x: box.x, y: box.y)
                    .gesture(drag { dx, dy in
                        let right = crop.x + crop.width
                        let bottom = crop.y + crop.height
                        let newX = min(max(crop.x + dx / video.width, 0), right - 0.02)
                        let newY = min(max(crop.y + dy / video.height, 0), bottom - 0.02)
                        crop = CropRect(x: newX, y: newY,
                                        width: right - newX, height: bottom - newY)
                    })

                CropHandle()
                    .position(x: box.x + box.width, y: box.y + box.height)
                    .gesture(drag { dx, dy in
                        crop = crop.changing(width: crop.width + dx / video.width,
                                             height: crop.height + dy / video.height)
                    })
            }
        }
    }

    /// **The increment, not the running total.** `DragGesture.translation` is cumulative from
    /// where the drag began, so a handler that adds it to a value moves that value by the whole
    /// distance on every callback — the same trap `SplitHandle` documents.
    private func drag(_ apply: @escaping (Double, Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let total = (Double(value.translation.width), Double(value.translation.height))
                apply(total.0 - applied.x, total.1 - applied.y)
                applied = (total.0, total.1)
            }
            .onEnded { _ in
                applied = (0, 0)
                onCommit()
            }
    }
}

private struct CropHandle: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
            .frame(width: 12, height: 12)
            // The hit area is three times the dot, for `SplitHandle`'s reason: a target the size
            // of what it draws is one people miss.
            .padding(12)
            .contentShape(Rectangle())
    }
}
