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
        case desktop, system, gradient

        var title: String {
            switch self {
            case .desktop: "Desktop"
            case .system: "System"
            case .gradient: "Gradients"
            }
        }
    }

    private var urls: [URL] {
        switch source {
        case .desktop: WallpaperGallery.currentDesktops()
        case .system: WallpaperGallery.systemPictures()
        case .gradient: []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Picker("", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if source == .gradient {
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
