import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import Compositing
import Render

/// **Blurring somebody's own wallpaper is what makes it usable as a background.**
///
/// A desktop picture has a horizon, a face, a logo — all of it competing with the recording
/// sitting on top of it. Blurred, the same picture keeps its colours and its light and stops
/// being a picture, which is why the control belongs directly under the wallpaper grid and
/// where it belongs and where this app now has it.
///
/// **`.serialized`, because the renderer's image base is a process-global static.** Setting it is
/// how a background picture is found at all; two suites setting it at once would each render
/// against the other's directory. Restored after every test, so nothing downstream inherits it.
@Suite("Background blur", .serialized)
struct BackgroundBlurTests {
    // MARK: - The value

    @Test("a project written before the blur existed has a sharp background")
    func anOlderProjectIsSharp() throws {
        let json = Data("""
        {"insetFraction":0.06,"cornerRadius":18,"shadowRadius":32,"shadowOpacity":0.35,
         "background":{"solid":{"red":0.1,"green":0.1,"blue":0.1}}}
        """.utf8)
        let decoded = try JSONDecoder().decode(StageStyle.self, from: json)
        #expect(decoded.backgroundBlur == 0)
    }

    /// Clamped rather than trapped: it arrives from a slider and from a decoder, and rule 8
    /// forbids trapping on either.
    @Test("a blur outside the range is clamped rather than trapping")
    func anImpossibleBlurIsClamped() {
        func style(_ blur: Double) -> StageStyle {
            StageStyle(insetFraction: 0.06, cornerRadius: 18, shadowRadius: 32,
                       shadowOpacity: 0.35, background: .solid(red: 0, green: 0, blue: 0),
                       backgroundBlur: blur)
        }
        #expect(style(-1).backgroundBlur == 0)
        #expect(style(5).backgroundBlur == 1)
        #expect(style(.nan).backgroundBlur == 0)
        #expect(style(0.4).backgroundBlur == 0.4)
    }

    @Test("the blur survives a round trip")
    func itRoundTrips() throws {
        let style = StageStyle(insetFraction: 0.06, cornerRadius: 18, shadowRadius: 32,
                               shadowOpacity: 0.35, background: .image(filename: "w.png"),
                               backgroundBlur: 0.7)
        let decoded = try JSONDecoder().decode(
            StageStyle.self, from: try JSONEncoder().encode(style))
        #expect(decoded.backgroundBlur == 0.7)
        #expect(decoded == style)
    }

    /// **Expressed against the frame's width so the slider means the same thing at every export
    /// size.** A blur written in pixels is heavy at 720p and invisible at 4K, which would make a
    /// project look different depending on what it was exported as — the one thing a style must
    /// never do. Pinned, because the number was chosen by looking at the result.
    @Test("the strongest blur is a fraction of the frame rather than a pixel count")
    func theBlurScalesWithTheFrame() {
        #expect(CoreImageFrameRenderer.backgroundBlurFractionOfWidth == 0.04)
    }

    // MARK: - The renderer actually blurs

    /// **The check the rest of this rests on: a rendered frame with the blur on is measurably
    /// softer than the same frame with it off.**
    ///
    /// A background of hard black-and-white stripes is used because a blur's whole effect is on
    /// an edge: sharp, the pixels either side of a stripe boundary are 0 and 255; blurred, they
    /// move toward each other. The corner of the frame is sampled, which is background rather
    /// than card.
    ///
    /// Everything else in this file would pass against a renderer that stored the value and never
    /// used it.
    @Test("a blurred background is measurably softer than a sharp one")
    func theBlurReachesThePicture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-blur-\(UUID().uuidString)", directoryHint: .isDirectory)
        let backgrounds = directory.appending(path: StageBackground.imageDirectory,
                                              directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backgrounds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeStripes(to: backgrounds.appending(path: "stripes.png"))

        let previousBase = unsafe CoreImageFrameRenderer.imageBaseURL
        unsafe CoreImageFrameRenderer.imageBaseURL = directory
        defer { unsafe CoreImageFrameRenderer.imageBaseURL = previousBase }
        // The renderer caches decoded backgrounds by filename; a fresh one per render is what
        // keeps this test from measuring the previous one's picture.
        func spread(blur: Double) throws -> Int {
            let style = StageStyle(insetFraction: 0.3, cornerRadius: 0, shadowRadius: 0,
                                   shadowOpacity: 0, background: .image(filename: "stripes.png"),
                                   backgroundBlur: blur)
            let plan = StagePlanner.plan(outputWidth: 640, outputHeight: 360,
                                         sourceWidth: 640, sourceHeight: 360, style: style)
            let source = try makePixelBuffer(width: 640, height: 360, fill: (200, 40, 60))
            let destination = try makePixelBuffer(width: 640, height: 360, fill: (0, 0, 0))
            let renderer: any FrameRendering
            do { renderer = try CoreImageFrameRenderer() }
            catch FrameRenderingError.noRenderDevice {
                Issue.record("no Metal render device on this machine — a real answer, not a skip")
                return -1
            }
            try renderer.render(plan, source: source, camera: nil, into: destination)
            // The top strip of the frame is background: the card is inset by 30%.
            let all = try pixels(of: destination)
            let strip = all.prefix(640 * 20).map { Int($0.r) }
            return (strip.max() ?? 0) - (strip.min() ?? 0)
        }

        let sharp = try spread(blur: 0)
        let blurred = try spread(blur: 1)
        guard sharp >= 0, blurred >= 0 else { return }
        #expect(sharp > 100, "the sharp stripes should span most of the range, and spanned \(sharp)")
        #expect(blurred < sharp,
                "blurred spanned \(blurred) and sharp spanned \(sharp) — the blur did nothing")
    }

    /// Hard black-and-white stripes: the picture a blur has the most to do to.
    static func writeStripes(to url: URL) throws {
        let width = 256, height = 256
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (x / 8).isMultiple(of: 2) ? 255 : 0
                let index = (y * width + x) * 4
                bytes[index] = value; bytes[index + 1] = value
                bytes[index + 2] = value; bytes[index + 3] = 255
            }
        }
        let image = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4,
                            size: CGSize(width: width, height: height),
                            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        try CIContext().writePNGRepresentation(
            of: image, to: url, format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}

/// **The third time a hand-written rebuild dropped a new field, so this is the check that ends
/// it.**
///
/// `StageStylePicker.apply` dropped one and a scan caught it. `CameraOverlayStyle.changing` and
/// `.placed(at:)` dropped one and a `Mirror` walk caught it. `StageStyle.encode(to:)` dropped
/// `backgroundBlur` and a round-trip test caught it — after the field had already been added to
/// the type, the initialiser, the decoder and the CodingKeys, all four correctly.
///
/// The shape is always the same: a function that names every field by hand, and a field that is
/// added to the type and not to that function. It never fails to compile and it never reports
/// anything. It reads back as a default, in somebody's saved project, months later.
///
/// So this does not name the fields. It builds a value in which every field differs from the
/// default, writes it, reads it back, and compares the two through reflection — which means the
/// field somebody adds next is checked without them remembering to check it.
@Suite("Stage style round trip")
struct StageStyleRoundTripTests {
    /// Every field set away from `StageStyle.default`, so a dropped one changes value rather
    /// than landing back on the same number by luck.
    static let unusual = StageStyle(
        insetFraction: 0.21, cornerRadius: 42, shadowRadius: 7, shadowOpacity: 0.61,
        background: .image(filename: "wall.png"), borderOpacity: 0.29,
        deviceModel: .iPhone, deviceFinish: .deepBlue, backgroundBlur: 0.83)

    static func fields(of style: StageStyle) -> [String: String] {
        var found: [String: String] = [:]
        for child in Mirror(reflecting: style).children where child.label != nil {
            found[child.label!] = String(describing: child.value)
        }
        return found
    }

    @Test("every field of the style survives being written and read back")
    func everyStageStyleFieldSurvivesTheRoundTrip() throws {
        let decoded = try JSONDecoder().decode(
            StageStyle.self, from: try JSONEncoder().encode(Self.unusual))
        #expect(Self.fields(of: decoded) == Self.fields(of: Self.unusual))
        // A guard on the guard: reflection that saw no fields would pass the line above while
        // checking nothing at all.
        #expect(Self.fields(of: Self.unusual).count >= 9)
    }

    /// **The defaults must round-trip too**, and they are the case the encoder's conditional
    /// writes make interesting: `borderOpacity` and `backgroundBlur` are deliberately omitted
    /// when zero, so a decoder that did not default them to zero would read a plain style back
    /// as something else.
    @Test("a style with every default survives the round trip too")
    func theDefaultStyleRoundTrips() throws {
        let decoded = try JSONDecoder().decode(
            StageStyle.self, from: try JSONEncoder().encode(StageStyle.default))
        #expect(Self.fields(of: decoded) == Self.fields(of: StageStyle.default))
    }
}
