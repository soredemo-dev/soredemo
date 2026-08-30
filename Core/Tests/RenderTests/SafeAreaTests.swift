import Foundation
import Testing
@testable import Render

// MARK: - what something else is sitting on

/// **Two kinds of claim, and the test is that they stay apart.** Action and title safe are the
/// broadcast convention and have not moved in decades; the vertical band is a guess about
/// somebody else's interface that no platform publishes. A future edit that gave the guess a
/// citation, or the convention a wobble, should have to argue with this.
@Test func theCitableFiguresAreTheBroadcastOnes() {
    #expect(SafeArea.actionSafeFraction == 0.9)
    #expect(SafeArea.titleSafeFraction == 0.8)
    #expect(SafeArea.titleSafeFraction < SafeArea.actionSafeFraction,
            "title safe is the inner box; outside it text is cut on some screens")
}

/// **The overlay and the caption preset use ONE number.** The band drawn over the picture is the
/// band the Vertical preset sits clear of, so looking at the frame is how somebody checks that
/// preset — rather than the overlay being a second opinion that can drift away from it.
@Test func theVerticalPresetClearsExactlyTheBandTheGuideDraws() throws {
    let vertical = try #require(CaptionStyle.presets.first { $0.name == "Vertical" })
    #expect(vertical.style.bottomInsetFraction == SafeArea.verticalChromeFraction,
            """
            the Vertical preset and the safe-frame band have drifted apart — the guide is \
            supposed to be how a person checks that preset
            """)
}

/// Only a frame taller than it is wide gets the band. A landscape export is watched in a player,
/// and a player's controls fade.
@Test func onlyATallFrameCarriesPlatformChrome() {
    #expect(SafeArea.hasPlatformChrome(width: 1080, height: 1920))
    #expect(!SafeArea.hasPlatformChrome(width: 1920, height: 1080))
    // Square is not taller than wide, so it does not.
    #expect(!SafeArea.hasPlatformChrome(width: 1080, height: 1080))

    #expect(SafeArea.chromeBand(width: 1080, height: 1920) == SafeArea.verticalChromeFraction)
    #expect(SafeArea.chromeBand(width: 1920, height: 1080) == nil,
            "a landscape frame was given a band nothing covers")
}
