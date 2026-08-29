import AppKit
import ImageIO
import Render
import SwiftUI

/// The pictures a person can put behind their recording without going to find one.
///
/// **"Choose image…" is a file panel, and a file panel is a place you have to already know the
/// answer.** ScreenKite ships a wallpaper grid with a download button on each; the point is that
/// a background is a look, and looks are chosen by seeing them. This is the same idea from what
/// is already on the machine, which needs no download at all.
///
/// **Three sources, and the order is by how likely each is to be wanted.** The desktop a person
/// is looking at right now is the commonest answer — a recording on the same wallpaper reads as
/// part of their screen rather than as a slide. Then the system's own pictures, then the
/// gradients this app draws, which cost nothing and are always there.
@MainActor
enum WallpaperGallery {
    /// Where macOS keeps the pictures it ships. **Only the plain images**: the rest are
    /// `.madesktop` files, which are XML describing a dynamic wallpaper rather than a picture,
    /// and handing one to `CIImage(contentsOf:)` produces nothing.
    private static let systemDirectory = URL(fileURLWithPath: "/System/Library/Desktop Pictures")

    /// The wallpaper currently on each screen, de-duplicated.
    ///
    /// `NSWorkspace.desktopImageURL(for:)` reads the person's OWN choice, which is the one file
    /// this app has any business knowing about here — as distinct from enumerating what they
    /// have in Pictures.
    static func currentDesktops() -> [URL] {
        var seen = Set<URL>()
        return NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            .filter { seen.insert($0).inserted }
    }

    /// The system's shipped pictures, by name.
    static func systemPictures() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: systemDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "heic" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// A thumbnail, small. **`NSImage(contentsOf:)` decodes the whole file**, and a wallpaper is
    /// a 6K HEIC — a grid of twenty would decode a couple of hundred megapixels to draw postage
    /// stamps. `CGImageSourceCreateThumbnailAtIndex` decodes only what it needs.
    /// `nonisolated` so a tile can decode off the main actor: a grid that decoded twenty HEICs
    /// while laying itself out would stutter the panel it is in. It touches no shared state.
    nonisolated static func thumbnail(of url: URL, maximumPixel: Int = 240) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixel,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// The grid.
struct WallpaperPicker: View {
    let model: StageStyleModel
    let packageURL: URL
    let onChange: () -> Void

    @State private var source = Source.desktop
    @State private var failure: String?

    private enum Source: String, CaseIterable, Hashable {
        case desktop, system, gradient, none

        var title: String {
            switch self {
            case .desktop: "Desktop"
            case .system: "System"
            case .gradient: "Gradients"
            case .none: "None"
            }
        }
    }

    private var urls: [URL] {
        switch source {
        case .desktop: WallpaperGallery.currentDesktops()
        case .system: WallpaperGallery.systemPictures()
        case .gradient, .none: []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Picker("", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if source == .none {
                transparent
            } else if source == .gradient {
                gradients
            } else if urls.isEmpty {
                Text(source == .desktop
                     ? "This Mac's wallpaper could not be read."
                     : "No pictures were found in the system's wallpaper folder.")
                    .font(Type.detail).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: Space.snug)],
                          spacing: Space.snug) {
                    ForEach(urls, id: \.self) { url in
                        WallpaperTile(url: url,
                                      isSelected: model.imageBackgroundName == url.lastPathComponent) {
                            failure = model.useImageBackground(url, inPackageAt: packageURL)
                            onChange()
                        }
                    }
                }
            }

            if let failure {
                Text(failure).font(Type.detail).foregroundStyle(Signal.paused)
            }
        }
    }

    /// **No background at all — the export carries a hole where the colour was.**
    ///
    /// Drawn as the checkerboard every image editor uses for transparency rather than as an
    /// empty square, because an empty square is what a black background looks like too, and the
    /// difference between those two is the entire feature.
    ///
    /// The note under it is not decoration. Only two of the five codecs can carry transparency,
    /// and the export refuses the others by name rather than handing back a black rectangle —
    /// but somebody is better told here, while they are choosing, than at the moment they press
    /// Export.
    @ViewBuilder private var transparent: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Button {
                model.useTransparentBackground()
                onChange()
            } label: {
                Self.checkerboard
                    .frame(height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(model.isTransparent ? Theme.accent : Theme.Line.hairline,
                                          lineWidth: model.isTransparent ? 2 : 1)
                    }
            }
            .buttonStyle(.plain)

            Text("Nothing behind the card, so the recording can be dropped onto a page or over "
                 + "another clip. Export as HEVC with Alpha — it is the smallest of the two "
                 + "formats that keep transparency, and ProRes 4444 is around a hundred times "
                 + "larger for the same picture.")
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The checkerboard that means "nothing here" in every image editor ever made.
    ///
    /// **Rectangles rather than a drawn image, and that is D6 rule 5 rather than taste.** The
    /// obvious spelling is `Image(size:)` with a `GraphicsContext` filling four `CGRect`s — which
    /// names two CoreGraphics geometry types in the app target, and the allow-list scan caught it
    /// the moment it was written. A grid of `Rectangle`s says the same thing in the app's own
    /// vocabulary and needs no bridge.
    ///
    /// Twelve by four at a 42-point height gives squares of about ten points, which reads as a
    /// checkerboard rather than as noise or as two grey halves.
    private static var checkerboard: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { column in
                        Rectangle()
                            .fill(Color(white: (row + column).isMultiple(of: 2) ? 0.87 : 0.72))
                    }
                }
            }
        }
    }

    /// The gradients this app draws. Not files, so there is nothing to copy and nothing to lose:
    /// a project carrying one carries three numbers and an angle.
    @ViewBuilder private var gradients: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: Space.snug)],
                  spacing: Space.snug) {
            ForEach(StageBackground.presets, id: \.name) { preset in
                Button {
                    model.selectBackground(named: preset.name)
                    onChange()
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Self.swatch(preset.background))
                        .frame(height: 42)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(model.presetName == preset.name
                                              ? Theme.accent : Theme.Line.hairline,
                                              lineWidth: model.presetName == preset.name ? 2 : 1)
                        }
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    /// A preset drawn as SwiftUI would draw it. The angle is converted the way
    /// `CoreImageFrameRenderer` measures it, so a swatch is a picture of the output.
    static func swatch(_ background: StageBackground) -> AnyShapeStyle {
        switch background {
        case .solid(let red, let green, let blue):
            AnyShapeStyle(Color(red: red, green: green, blue: blue))
        case .linearGradient(let sr, let sg, let sb, let er, let eg, let eb, let angle):
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: sr, green: sg, blue: sb),
                         Color(red: er, green: eg, blue: eb)],
                startPoint: Self.unitPoint(atDegrees: angle + 180),
                endPoint: Self.unitPoint(atDegrees: angle)))
        case .image:
            AnyShapeStyle(Color.gray)
        case .transparent:
            // **A flat grey, and the None tab draws the real checkerboard.** This function
            // returns a `ShapeStyle` for the preset swatches, and no preset is transparent —
            // deliberately, because a swatch of nothing is a swatch of black. The case exists
            // because the switch must be exhaustive, and answering it with a colour is honest;
            // answering it with something that looked like a checkerboard would suggest this
            // path draws one, which it does not.
            AnyShapeStyle(Color(white: 0.8))
        }
    }

    static func unitPoint(atDegrees degrees: Double) -> UnitPoint {
        let radians = degrees * .pi / 180
        return UnitPoint(x: 0.5 + cos(radians) / 2, y: 0.5 - sin(radians) / 2)
    }
}

/// One picture in the grid. **The thumbnail is loaded once, off the main actor** — a grid that
/// decoded twenty HEICs while laying itself out would stutter the panel it is in.
private struct WallpaperTile: View {
    let url: URL
    let isSelected: Bool
    let choose: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: choose) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.Fill.track)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.Line.hairline,
                                  lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(url.deletingPathExtension().lastPathComponent)
        .task {
            guard thumbnail == nil else { return }
            let url = url
            thumbnail = await Task.detached { WallpaperGallery.thumbnail(of: url) }.value
        }
    }
}
