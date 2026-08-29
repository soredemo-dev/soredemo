import Testing
import Foundation
import Render
import Timeline
@testable import Overlays

private func ns(_ seconds: Double) -> Nanoseconds {
    Nanoseconds(Int64((seconds * 1000).rounded()) * 1_000_000)
}

@Suite struct RedactionTrackTests {
    @Test func addingMintsAscendingIdsAndNeverReusesADeletedOne() {
        let one = RedactionTrack().adding(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let firstID = one.items[0].id
        let two = one.removing(firstID).adding(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(two.items.count == 1)
        #expect(two.items[0].id != firstID)
    }

    /// The default: the thing being hidden is usually a window that is on screen throughout.
    @Test func aNewRegionCoversTheWholeRecordingByDefault() {
        let track = RedactionTrack().adding(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        #expect(track.regions(at: ns(0)).count == 1)
        #expect(track.regions(at: ns(9_999)).count == 1)
    }

    @Test func aRegionWithASpanOnlyCoversIt() {
        var track = RedactionTrack().adding(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        var item = track.items[0]
        item.coversEverything = false
        item.start = ns(2)
        item.end = ns(4)
        track = track.replacing(item)
        #expect(track.regions(at: ns(1)).isEmpty)
        #expect(track.regions(at: ns(3)).count == 1)
        // The end is exclusive, so a region does not linger onto the frame that reveals it.
        #expect(track.regions(at: ns(4)).isEmpty)
    }

    /// A click that never became a drag leaves a zero-area region; drawing one is a filter pass
    /// that changes nothing.
    @Test func aZeroAreaRegionIsNeverReturned() {
        let track = RedactionTrack().adding(x: 0.5, y: 0.5, width: 0, height: 0.3)
        #expect(track.items.count == 1)
        #expect(track.regions(at: ns(0)).isEmpty)
        #expect(track.items[0].region.isEmpty)
    }

    @Test func replacingOrRemovingAnIdNobodyHasIsANoOp() {
        let track = RedactionTrack().adding(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        #expect(track.removing(9_999) == track)
        let stranger = RedactionItem(
            region: RedactionRegion(id: 9_999, x: 0, y: 0, width: 1, height: 1),
            start: ns(0), end: ns(1))
        #expect(track.replacing(stranger) == track)
    }

    @Test func aTrackRoundTripsThroughItsOwnEncoding() throws {
        let track = RedactionTrack()
            .adding(x: 0.1, y: 0.2, width: 0.3, height: 0.4, style: .black)
        let data = try JSONEncoder().encode(track)
        #expect(try JSONDecoder().decode(RedactionTrack.self, from: data) == track)
    }
}

@Suite struct RedactionRegionTests {
    /// A region dragged off the edge is one a person meant to put at the edge; one stored
    /// outside the frame would silently cover nothing.
    @Test func aRegionIsClampedIntoTheFrameRatherThanStoredOutsideIt() {
        let region = RedactionRegion(id: 0, x: -0.5, y: 0.8, width: 4, height: 4)
        #expect(region.x == 0)
        #expect(region.y == 0.8)
        #expect(region.width == 1)
        // Height is clamped to what is left below `y`, not to 1 — a region cannot extend past
        // the bottom of the picture it is covering.
        #expect(abs(region.height - 0.2) < 1e-12)
    }

    /// Rule 8: the synthesised decoder never calls the validating initialiser, so the hand-
    /// written one must — and a file with nonsense in it must open rather than throw.
    @Test func aDecodedRegionIsClampedTheSameWayAConstructedOneIs() throws {
        let wild = Data(#"""
            {"id":3,"x":-2,"y":0.5,"width":9,"height":9,
             "style":{"mosaic":{"blockFraction":99}}}
            """#.utf8)
        let region = try JSONDecoder().decode(RedactionRegion.self, from: wild)
        #expect(region.x == 0)
        #expect(region.width == 1)
        #expect(abs(region.height - 0.5) < 1e-12)
        #expect(region.isOval == false)
        if case .mosaic(let fraction) = region.style {
            #expect(fraction <= 0.25)
        } else {
            Issue.record("the style did not survive as a mosaic")
        }
    }

    /// **A Gaussian blur is not one of the choices, and the enum is where that is enforced.**
    /// A blur is invertible enough that text under a light one has been recovered from published
    /// video; a normaliser that returns "mosaic" whatever it is given exists for this
    /// reason. If a `.blur` case ever appears here, this test is what should have stopped it.
    @Test func theOnlyWaysToHideSomethingAreDestructiveOnes() {
        let styles: [RedactionStyle] = [.defaultMosaic, .black]
        for style in styles {
            switch style.clamped {
            case .mosaic, .solid: break
            }
        }
        if case .mosaic(let fraction) = RedactionStyle.defaultMosaic { #expect(fraction > 0) }
        if case .solid(let r, let g, let b) = RedactionStyle.black {
            #expect(r == 0 && g == 0 && b == 0)
        }
    }

    @Test func aStyleIsClampedOnTheWayOutAsWellAsIn() {
        if case .mosaic(let fraction) = RedactionStyle.mosaic(blockFraction: -5).clamped {
            #expect(fraction >= 0.002)
        }
        if case .solid(let r, _, _) = RedactionStyle.solid(red: 9, green: 0, blue: 0).clamped {
            #expect(r == 1)
        }
    }
}
