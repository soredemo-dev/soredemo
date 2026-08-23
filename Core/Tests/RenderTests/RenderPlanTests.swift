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
        #expect(base.changing(clickEffect: .none).scale == base.scale)
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
