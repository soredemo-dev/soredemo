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
