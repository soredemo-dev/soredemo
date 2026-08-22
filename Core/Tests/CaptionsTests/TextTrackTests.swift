import Testing
import Foundation
import Render
import Timeline
@testable import Captions

private func ns(_ seconds: Double) -> Nanoseconds {
    Nanoseconds(Int64((seconds * 1000).rounded()) * 1_000_000)
}

@Suite struct TextTrackTests {
    @Test func addingMintsAscendingIdsAndKeepsStartOrder() {
        let track = TextTrack()
            .adding(text: "second", start: ns(5), end: ns(6))
            .adding(text: "first", start: ns(1), end: ns(2))
        #expect(track.items.map(\.text) == ["first", "second"])
        #expect(Set(track.items.map(\.id)).count == 2)
        #expect(track.nextID == 2)
    }

    /// **A deleted id is never reused**, or an old selection would attach to a new title.
    @Test func removingAnItemDoesNotFreeItsIdForTheNextOne() {
        let one = TextTrack().adding(text: "a", start: ns(0), end: ns(1))
        let firstID = one.items[0].id
        let two = one.removing(firstID).adding(text: "b", start: ns(0), end: ns(1))
        #expect(two.items.count == 1)
        #expect(two.items[0].id != firstID)
    }

    @Test func removingAnIdNobodyHasIsANoOp() {
        let track = TextTrack().adding(text: "a", start: ns(0), end: ns(1))
        #expect(track.removing(9_999) == track)
        #expect(track.replacing(TextItem(id: 9_999, text: "x", start: ns(0), end: ns(1)))
                == track)
    }

    @Test func replacingKeepsIdentityAndPosition() {
        let track = TextTrack().adding(text: "typo", start: ns(1), end: ns(3))
        var item = track.items[0]
        item.text = "fixed"
        let updated = track.replacing(item)
        #expect(updated.items[0].text == "fixed")
        #expect(updated.items[0].id == item.id)
        #expect(updated.items[0].start == ns(1))
    }

    /// The difference from `CaptionTrack`: two captions at once is a bug, a title over a lower
    /// third is a layout.
    @Test func severalOverlaysCanBeOnScreenAtOnce() {
        let track = TextTrack()
            .adding(text: "title", start: ns(0), end: ns(10))
            .adding(text: "lower third", start: ns(2), end: ns(4))
        #expect(track.items(at: ns(3)).count == 2)
        #expect(track.items(at: ns(5)).map(\.text) == ["title"])
        #expect(track.items(at: ns(20)).isEmpty)
        // The end is exclusive, so an item does not linger on the frame that replaces it.
        #expect(track.items(at: ns(10)).isEmpty)
    }

    @Test func retimingDropsItemsInsideACutAndMovesTheOnesAfterIt() {
        let timeline = EditTimeline.whole(duration: ns(10))
            .removing(sourceRange: ns(2).rawValue..<ns(4).rawValue)
        let track = TextTrack()
            .adding(text: "before", start: ns(0), end: ns(1))
            .adding(text: "inside", start: ns(2.2), end: ns(3.5))
            .adding(text: "after", start: ns(5), end: ns(6))
        let retimed = track.retimed(through: timeline)
        #expect(retimed.items.map(\.text) == ["before", "after"])
        #expect(retimed.items[1].start == ns(3))
    }

    /// **Both halves keep the id**, because both halves are the same title.
    @Test func anItemSpanningACutIsSplitAndBothHalvesKeepTheirIdentity() {
        let timeline = EditTimeline.whole(duration: ns(10))
            .removing(sourceRange: ns(3).rawValue..<ns(5).rawValue)
        let track = TextTrack().adding(text: "across", start: ns(2), end: ns(6))
        let retimed = track.retimed(through: timeline)
        #expect(retimed.items.count == 2)
        #expect(retimed.items[0].id == retimed.items[1].id)
        #expect(retimed.items[0].end == ns(3))
        #expect(retimed.items[1].start == ns(3))
    }

    @Test func retimingThroughAnUncutTimelineChangesNothing() {
        let timeline = EditTimeline.whole(duration: ns(10))
        let track = TextTrack().adding(text: "a", start: ns(1), end: ns(2))
        #expect(track.retimed(through: timeline) == track)
    }

    @Test func aTrackRoundTripsThroughItsOwnEncoding() throws {
        let track = TextTrack()
            .adding(text: "hello", start: ns(0), end: ns(2), style: .default)
        let data = try JSONEncoder().encode(track)
        let back = try JSONDecoder().decode(TextTrack.self, from: data)
        #expect(back == track)
        #expect(back.nextID == track.nextID)
    }

    /// A track written before `nextID` existed recovers one from its items rather than minting
    /// an id an existing item already has.
    @Test func aTrackWithNoStoredCounterRecoversOneFromItsItems() throws {
        // **Built by encoding a real track and removing the key**, not hand-written. A
        // hand-written fixture here would be asserting my guess about how `Nanoseconds` encodes
        // rather than about the decoder — which is exactly how an earlier fixture in this
        // repository tested nothing.
        let current = TextTrack(items: [TextItem(id: 7, text: "a", start: ns(0), end: ns(1))],
                                nextID: 8)
        var fields = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)) as? [String: Any])
        fields.removeValue(forKey: "nextID")
        let older = try JSONSerialization.data(withJSONObject: fields)

        let track = try JSONDecoder().decode(TextTrack.self, from: older)
        #expect(track.nextID == 8)
        #expect(track.adding(text: "b", start: ns(0), end: ns(1)).items.map(\.id).sorted()
                == [7, 8])
    }

    @Test func aDurationIsNeverNegativeHoweverTheEndsWereGiven() {
        let backwards = TextItem(id: 0, text: "x", start: ns(5), end: ns(1))
        #expect(backwards.duration == Nanoseconds(0))
        #expect(!backwards.contains(ns(3)))
    }
}

@Suite struct TextOverlayStyleTests {
    /// Rule 8: a style also arrives from a decoder, and an out-of-range value must not trap.
    @Test func everyFieldIsClampedRatherThanTrappedOn() {
        let wild = TextOverlayStyle(
            heightFraction: 99, x: -4, y: 12, anchor: .leading, isBold: true,
            red: 5, green: -5, blue: 0.5, alpha: 9,
            plateOpacity: -1, plateCornerFraction: 9, plateRed: 2, plateGreen: 0.5, plateBlue: -2,
            shadowOpacity: 4, shadowBlurFraction: 99, maximumWidthFraction: 0, lineGapRatio: -9)
        #expect(wild.heightFraction <= 0.6)
        #expect(wild.x == 0)
        #expect(wild.y == 1)
        #expect(wild.red == 1)
        #expect(wild.green == 0)
        #expect(wild.alpha == 1)
        #expect(wild.plateOpacity == 0)
        #expect(wild.shadowBlurFraction <= 0.1)
        #expect(wild.maximumWidthFraction >= 0.1)
        #expect(wild.lineGapRatio == 0)
    }

    /// The eighteen-argument initialiser is why `changing` exists: a UI repeating it per slider
    /// would be eighteen chances to pass `green` where `blue` belongs.
    @Test func changingOneFieldLeavesEveryOtherAlone() {
        let base = TextOverlayStyle.default
        let bigger = base.changing(heightFraction: 0.2)
        #expect(bigger.heightFraction == 0.2)
        #expect(bigger.x == base.x)
        #expect(bigger.shadowOpacity == base.shadowOpacity)
        #expect(base.changing(anchor: .trailing).anchor == .trailing)
        #expect(base.changing() == base)
    }

    /// A caption IS a piece of text — this is the conversion that keeps one drawing path.
    @Test func aCaptionStyleBecomesACentredBottomTextStyle() {
        let caption = CaptionStyle.default
        let text = caption.asTextStyle
        #expect(text.anchor == .center)
        #expect(text.x == 0.5)
        #expect(text.y == caption.bottomInsetFraction)
        #expect(text.heightFraction == caption.heightFraction)
        #expect(text.plateOpacity == caption.backgroundOpacity)
        #expect(text.maximumWidthFraction == caption.maximumWidthFraction)
    }

    @Test func aStyleRoundTripsThroughItsOwnEncoding() throws {
        let data = try JSONEncoder().encode(TextOverlayStyle.default)
        #expect(try JSONDecoder().decode(TextOverlayStyle.self, from: data)
                == TextOverlayStyle.default)
    }

    @Test func everyAnchorSaysWhatItIs() {
        #expect(Set(TextAnchor.allCases.map(\.displayName)).count == TextAnchor.allCases.count)
    }
}
