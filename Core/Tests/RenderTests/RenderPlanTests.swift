import Testing
import Foundation
@testable import Render

/// The background a person can choose a picture for.
@Suite struct ImageBackgroundTests {
    /// **A filename is joined to a directory by whoever draws it**, so a value carrying `../`
    /// would reach outside the package. `Codable` cannot be trusted to hand back what was
    /// written — rule 8's case exactly.
    @Test func aFilenameWithAPathInItIsRefusedOnDecode() throws {
        let escaping = Data(#"{"image":{"filename":"../../etc/passwd"}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(StageBackground.self, from: escaping)
        }
        let hidden = Data(#"{"image":{"filename":".ssh"}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(StageBackground.self, from: hidden)
        }
    }

    @Test func theNameCheckAgreesWithTheDecoder() {
        #expect(StageBackground.isSafeImageFilename("wallpaper.png"))
        #expect(!StageBackground.isSafeImageFilename(""))
        #expect(!StageBackground.isSafeImageFilename("../x.png"))
        #expect(!StageBackground.isSafeImageFilename("a/b.png"))
        #expect(!StageBackground.isSafeImageFilename(".hidden"))
    }

    /// The other two cases still decode exactly as before — the hand-written conformance
    /// replaced a synthesised one, and a wire-format change would open every saved project
    /// with no background.
    @Test func solidAndGradientStillRoundTrip() throws {
        for background in StageBackground.presets.map(\.background) + [
            StageBackground.image(filename: "shot.png"),
        ] {
            let data = try JSONEncoder().encode(background)
            #expect(try JSONDecoder().decode(StageBackground.self, from: data) == background)
        }
    }
}

/// The cursor's own look — the two things every reference recorder makes a choice and this one
/// had as constants.
@Suite struct CursorStyleTests {
    /// Rule 8: these arrive from sliders AND from a decoder, and neither may trap.
    @Test func everyFieldIsClampedRatherThanTrappedOn() {
        let wild = CursorStyle(scale: 99, clickEffect: .pulse, clickOpacity: -4,
                               clickSize: 0, red: 5, green: -1, blue: 0.5)
        #expect(wild.scale == 3)
        #expect(wild.clickOpacity == 0)
        #expect(wild.clickSize == 0.25)
        #expect(wild.red == 1)
        #expect(wild.green == 0)
        #expect(wild.blue == 0.5)
    }

    /// A project written before this existed opens with the defaults rather than failing — the
    /// absence-tolerance every field in `EditState` promises.
    @Test func aStyleWithNoKeysAtAllDecodesToTheDefault() throws {
        let empty = Data("{}".utf8)
        #expect(try JSONDecoder().decode(CursorStyle.self, from: empty) == .default)
    }

    @Test func aStyleRoundTripsThroughItsOwnEncoding() throws {
        let style = CursorStyle.default.changing(scale: 1.8, clickEffect: .pulse, clickSize: 2)
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(CursorStyle.self, from: data) == style)
    }

    @Test func changingOneFieldLeavesEveryOtherAlone() {
        let base = CursorStyle.default
        #expect(base.changing(scale: 2).clickEffect == base.clickEffect)
        // `CursorStyle.ClickEffect.none` spelled out: a bare `.none` in an optional context is
        // `Optional.none`, and the compiler cannot tell which was meant.
        #expect(base.changing(clickEffect: CursorStyle.ClickEffect.none).scale == base.scale)
        #expect(base.changing() == base)
    }

    /// **Turning a click effect off is one of the three cases**, not an opacity of zero: a
    /// person recording a drawing app wants no ring, and a zero-opacity ring still costs the
    /// canvas the room to draw it in.
    @Test func everyClickEffectSaysWhatItIsAndOneOfThemIsNothing() {
        #expect(CursorStyle.ClickEffect.allCases.contains(.none))
        #expect(Set(CursorStyle.ClickEffect.allCases.map(\.displayName)).count
                == CursorStyle.ClickEffect.allCases.count)
    }
}

/// The part of the recording used at all.
@Suite struct CropRectTests {
    /// **Clamped into the frame and never zero-area.** Sliders and decoders both reach here, and
    /// a crop of no area is a video with no picture in it.
    @Test func aCropIsClampedRatherThanTrappedOn() {
        let wild = CropRect(x: -1, y: 0.9, width: 9, height: 9)
        #expect(wild.x == 0)
        #expect(wild.y == 0.9)
        #expect(wild.width == 1)
        #expect(abs(wild.height - 0.1) < 1e-12)

        let empty = CropRect(x: 0.5, y: 0.5, width: 0, height: 0)
        #expect(empty.width >= 0.01)
        #expect(empty.height >= 0.01)
    }

    /// **`.whole` is a value rather than `nil`**, so a caller compares against one thing in every
    /// place instead of a rectangle here and an optional there.
    @Test func theWholeRecordingIsAValue() {
        #expect(CropRect.whole.isWhole)
        #expect(!CropRect(x: 0.1, y: 0, width: 0.5, height: 1).isWhole)
        #expect(CropRect(x: 0, y: 0, width: 1, height: 1) == .whole)
    }

    /// The cropped size is even on both edges, for the reason every buffer dimension here is.
    @Test func theCroppedSizeIsEvenOnBothEdges() {
        let crop = CropRect(x: 0, y: 0, width: 0.333, height: 0.777)
        let size = crop.size(ofSourceWidth: 1920, sourceHeight: 1080)
        #expect(size.width % 2 == 0)
        #expect(size.height % 2 == 0)
        #expect(size.width > 0 && size.height > 0)
    }

    /// A project written before crops existed has no key; the decoder still has to clamp, because
    /// the synthesised one would not.
    @Test func aDecodedCropIsClampedTheSameWayAConstructedOneIs() throws {
        let wild = Data(#"{"x":-2,"y":0,"width":9,"height":9}"#.utf8)
        let crop = try JSONDecoder().decode(CropRect.self, from: wild)
        #expect(crop.x == 0)
        #expect(crop.width == 1)
    }

    @Test func aCropRoundTripsAndChangingOneEdgeLeavesTheRest() throws {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        let data = try JSONEncoder().encode(crop)
        #expect(try JSONDecoder().decode(CropRect.self, from: data) == crop)
        #expect(crop.changing(width: 0.4).y == 0.2)
    }
}
