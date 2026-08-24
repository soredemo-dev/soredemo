import Testing
import Foundation
import Timeline
import Render
@testable import Overlays

private let epoch = BootEpoch(id: UUID(uuidString: "4E450000-0000-4000-8000-0000000000EE")!)
private func at(_ seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
}
private func press(_ seconds: Double, _ shortcut: String) -> KeystrokeTrack.Press {
    KeystrokeTrack.Press(instant: at(seconds), shortcut: shortcut)
}

/// The badge's life: rising before the press so it is whole AT the press, held, fading, gone.
@Test func aBadgeRisesIntoThePressHoldsAndFades() throws {
    let track = KeystrokeTrack(presses: [press(2.0, "⌘C")])
    let fadeIn = Double(KeystrokeTrack.fadeIn.rawValue) / 1e9
    let hold = Double(KeystrokeTrack.hold.rawValue) / 1e9
    let fadeOut = Double(KeystrokeTrack.fadeOut.rawValue) / 1e9

    #expect(track.badge(at: at(2.0 - fadeIn - 0.01)) == nil, "shown before its rise began")
    let rising = try #require(track.badge(at: at(2.0 - fadeIn / 2)))
    #expect(rising.opacity > 0.3 && rising.opacity < 0.7, "mid-rise at \(rising.opacity)")
    #expect(track.badge(at: at(2.0)) == KeystrokeBadge(text: "⌘C", opacity: 1), "not whole at the press")
    #expect(track.badge(at: at(2.0 + hold - 0.01))?.opacity == 1, "faded inside the hold")
    let falling = try #require(track.badge(at: at(2.0 + hold + fadeOut / 2)))
    #expect(falling.opacity > 0.3 && falling.opacity < 0.7, "mid-fall at \(falling.opacity)")
    #expect(track.badge(at: at(2.0 + hold + fadeOut + 0.01)) == nil, "shown after its fall")
}

/// A second press inside the first's hold replaces it — one badge, the newer text, a fresh hold.
@Test func aLaterPressReplacesTheBadge() {
    let track = KeystrokeTrack(presses: [press(2.0, "⌘C"), press(2.4, "⌘V")])
    #expect(track.badge(at: at(2.2))?.text == "⌘C")
    #expect(track.badge(at: at(2.5)) == KeystrokeBadge(text: "⌘V", opacity: 1))
    // The hold is the SECOND press's: at 2.0 + hold + a little, ⌘C alone would be fading.
    let hold = Double(KeystrokeTrack.hold.rawValue) / 1e9
    #expect(track.badge(at: at(2.0 + hold + 0.1))?.opacity == 1, "the replaced press's hold ran the clock")
}

/// Another boot session's press does not show here — overlapping host times, once more.
@Test func anotherEpochsPressIsNotShown() {
    let other = BootEpoch(id: UUID(uuidString: "0BADC0DE-0000-4000-8000-00000000000E")!)
    let foreign = KeystrokeTrack.Press(instant: HostInstant(epoch: other, hostTime: Nanoseconds(2_000_000_000)),
                                       shortcut: "⌘Z")
    let track = KeystrokeTrack(presses: [foreign])
    #expect(track.badge(at: at(2.1)) == nil)
    #expect(track.badge(at: HostInstant(epoch: other, hostTime: Nanoseconds(2_100_000_000)))?.text == "⌘Z")
}

/// Unsorted input sorts; an empty track is empty and shows nothing.
@Test func pressesAreSortedAndAnEmptyTrackShowsNothing() {
    let track = KeystrokeTrack(presses: [press(5, "⌘S"), press(1, "⌘A")])
    #expect(track.count == 2)
    #expect(track.badge(at: at(1.5))?.text == "⌘A")
    #expect(KeystrokeTrack().isEmpty)
    #expect(KeystrokeTrack().badge(at: at(1)) == nil)
}
