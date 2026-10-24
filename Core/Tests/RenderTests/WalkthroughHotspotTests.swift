import Foundation
import Geometry
import Testing
@testable import Render

// The pressed element's box on the exported picture. `docs/design/2026-10-25-where-the-element-is-in-the-picture.md`.
//
// **Every plan here is a non-identity**: the card is inset in a background (a translation), and
// the zoomed plan is centred off-centre (a scale and a shift), so a box drawn at the recorded
// fractions, or measured without the zoom, lands somewhere else. Expected values are worked out
// from the card and the zoom below, independently of the code.

private let revision = GeometryRevision(id: 6)

/// A quarter-by-quarter element whose bottom-left corner is at (0.25, 0.5) of the recording.
private let element = NormalizedFrame(origin: NormalizedPoint(x: 0.25, y: 0.5),
                                      size: NormalizedSize(width: 0.25, height: 0.25), revision: revision)

/// 1000 × 500 output, the card at (100, 50) and 800 × 400, bottom-left pixels.
private func plan(zoom: Double = 1, centre: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
                  tilt: StageTilt = .flat) -> RenderPlan {
    RenderPlan(outputWidth: 1000, outputHeight: 500,
               card: StageRect(x: 100, y: 50, width: 800, height: 400), cornerRadius: 0,
               style: StageStyle(insetFraction: 0.1, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
                                 background: .solid(red: 0, green: 0, blue: 0), tilt: tilt),
               pointer: nil, contentZoom: zoom, contentCentre: centre)
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Suite struct WalkthroughHotspotTests {
    /// Card-relative: x 300…500 px, y 250…350 px from the bottom — so 0.3 from the left and,
    /// flipped once, 0.3 from the top, 0.2 × 0.2 of the picture.
    @Test func onAnInsetCardTheBoxIsTheElementsPlaceOnTheCard() throws {
        let box = try #require(WalkthroughHotspot.box(of: element, in: plan()))
        #expect(near(box.x, 0.3) && near(box.y, 0.3) && near(box.width, 0.2) && near(box.height, 0.2),
                "got \(box)")
    }

    /// Zoom 2 centred on (0.25, 0.75): the content is 1600 × 800 with its origin at (100, −350),
    /// so the element spans x 500…900 and y 50…250 — half the picture's width from the left, and
    /// half from the top.
    @Test func underTheCameraTheBoxIsWhereTheZoomedElementIs() throws {
        let box = try #require(WalkthroughHotspot.box(of: element,
                                                      in: plan(zoom: 2, centre: NormalizedPoint(x: 0.25, y: 0.75))))
        #expect(near(box.x, 0.5) && near(box.y, 0.5) && near(box.width, 0.4) && near(box.height, 0.4),
                "got \(box)")
    }

    /// An element the camera has left is not on the picture, and has no box at all.
    @Test func anElementOutsideThePictureHasNoBox() {
        let far = NormalizedFrame(origin: NormalizedPoint(x: 0.9, y: 0.1),
                                  size: NormalizedSize(width: 0.05, height: 0.05), revision: revision)
        #expect(WalkthroughHotspot.box(of: far, in: plan(zoom: 2, centre: NormalizedPoint(x: 0.25, y: 0.75))) == nil)
    }

    /// Partly off the picture: the box is the part that is on it, not a box past the edge.
    @Test func aBoxIsClippedToThePicture() throws {
        let wide = NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.5),
                                   size: NormalizedSize(width: 0.5, height: 0.1), revision: revision)
        // Under the zoom above, x runs 740…1540: clipped at the picture's right edge, 1000.
        let box = try #require(WalkthroughHotspot.box(of: wide,
                                                      in: plan(zoom: 2, centre: NormalizedPoint(x: 0.25, y: 0.75))))
        #expect(near(box.x, 0.74) && near(box.x + box.width, 1.0), "got \(box)")
    }

    /// On a turned card the box follows the turn, as the cursor does: it holds the element's
    /// corners where the cursor's own placement puts them, and is not the flat box.
    @Test func onATurnedCardTheBoxFollowsTheTurn() throws {
        let turned = plan(tilt: StageTilt(pitch: 10, yaw: 25, distance: 2.5))
        let box = try #require(WalkthroughHotspot.box(of: element, in: turned))
        let flat = try #require(WalkthroughHotspot.box(of: element, in: plan()))
        #expect(box != flat)
        for corner in [NormalizedPoint(x: 0.25, y: 0.5), NormalizedPoint(x: 0.5, y: 0.75)] {
            let placed = StagePlanner.placement(for: corner, in: turned)
            let x = placed.x / 1000, y = 1 - placed.y / 500
            #expect(x >= box.x - 1e-9 && x <= box.x + box.width + 1e-9
                    && y >= box.y - 1e-9 && y <= box.y + box.height + 1e-9, "corner \(corner) outside \(box)")
        }
    }
}
