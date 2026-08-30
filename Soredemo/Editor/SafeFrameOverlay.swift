import Render
import SwiftUI

/// Where something else is likely to be sitting on the exported frame.
///
/// **Two guides, drawn differently because they are two different kinds of claim.** Title safe is
/// the broadcast convention and has not moved in decades; the band across the bottom of a
/// vertical frame is a guess about somebody else's interface that no platform publishes. Drawing
/// them the same way would let the second borrow the first's authority — so the citable one is a
/// thin line and the guess is a wash with its own label.
///
/// Nothing here is exported. It is a thing to look at while deciding where a caption sits, and
/// the band is the same fraction `CaptionStyle.presets`' Vertical entry clears — so this is how
/// somebody checks that number by eye.
struct SafeFrameOverlay: View {
    let outputWidth: Int
    let outputHeight: Int

    var body: some View {
        GeometryReader { proxy in
            // The frame as drawn, which is the output's aspect fitted into whatever the preview
            // is — a guide measured against the container rather than the picture would be in
            // the wrong place at every size but one.
            let fitted = Self.fitting(width: outputWidth, height: outputHeight, in: proxy.size)
            ZStack {
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: fitted.width * SafeArea.titleSafeFraction,
                           height: fitted.height * SafeArea.titleSafeFraction)

                if let band = SafeArea.chromeBand(width: outputWidth, height: outputHeight) {
                    VStack(spacing: 0) {
                        Spacer()
                        ZStack {
                            Rectangle().fill(.black.opacity(0.35))
                            Text("Covered on most vertical platforms")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 4)
                        }
                        .frame(height: fitted.height * band)
                    }
                    .frame(width: fitted.width, height: fitted.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .allowsHitTesting(false)
        }
    }

    /// The output's shape fitted inside the preview, the way the player letterboxes it.
    static func fitting(width: Int, height: Int, in container: CGSize) -> CGSize {
        guard width > 0, height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / Double(width), container.height / Double(height))
        return CGSize(width: Double(width) * scale, height: Double(height) * scale)
    }
}
