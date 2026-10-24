import Foundation
import Geometry
import Testing
import Timeline
@testable import Framing

// `CameraMotion.zoomProfile` — the camera's depth over time, one value per pixel column, for the
// zoom lane to draw. `docs/design/2026-10-25-the-zoom-lane-draws-the-camera.md`.
//
// **Every block here starts well after second zero**, so a profile measured from the first
// block's start rather than from the window asked for would put the rise in the wrong columns.

private let epoch = BootEpoch(id: UUID(uuidString: "2F0E5A11-7B3C-4D1E-9A2B-5C6D7E8F9012")!)

private func at(_ seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
}

private func block(_ from: Double, _ to: Double) -> ZoomBlock {
    let target = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: 0.3, y: 0.6),
                               size: NormalizedSize(width: 0.05, height: 0.05),
                               revision: GeometryRevision(id: 4)), role: "AXButton")
    return ZoomBlock(origin: at(from), start: at(from), end: at(to), target: target,
                     zoom: FramingDepth.zoom(for: target, coverage: 1, intensity: 1))
}

/// One column per tenth of a second from 0 to `seconds`, so a column's index is its time × 10.
private func profile(_ blocks: [ZoomBlock], seconds: Double) -> [Double] {
    CameraMotion(blocks: blocks).zoomProfile(from: at(0), to: at(seconds),
                                             columns: Int(seconds * 10))
}

@Suite struct ZoomProfileTests {
    @Test func oneValuePerColumnEachFiniteAndNeverBelowOne() {
        let values = profile([block(6, 9)], seconds: 15)
        #expect(values.count == 150)
        #expect(values.allSatisfy { $0.isFinite && $0 >= 1 })
    }

    @Test func atRestBeforeTheBlockAndBackToRestWellAfterIt() {
        let values = profile([block(6, 9)], seconds: 15)
        #expect(values[0..<58].allSatisfy { $0 < 1.001 }, "nothing before the block starts")
        #expect(values[140..<150].allSatisfy { $0 < 1.02 }, "back at rest seconds after it ends")
    }

    /// The camera arrives during the block and is near its depth before the end.
    @Test func itRisesInsideTheBlockAndHoldsNearItsDepth() throws {
        let depth = try #require(CameraMotion(blocks: [block(6, 9)]).blocksForTesting.first).zoom
        let values = profile([block(6, 9)], seconds: 15)
        #expect(values[62] > 1.05, "moving within 0.2 s of the start")
        #expect(abs(values[85] - depth) < 0.05 * depth, "within 5% of \(depth) by 8.5 s, was \(values[85])")
    }

    /// **Two blocks closer than `chainedPanGap` pan; two further apart go back out between.**
    /// The lane exists to show this difference, which a rectangle per block cannot.
    @Test func aChainedGapStaysZoomedAndALongGapReturnsToRest() {
        let chained = profile([block(3, 5), block(5.8, 8)], seconds: 12)
        #expect(chained[52..<58].allSatisfy { $0 > 1.5 }, "0.8 s apart: the camera pans, it does not dip")
        let apart = profile([block(3, 5), block(10, 12)], seconds: 14)
        #expect(apart[80..<95].allSatisfy { $0 < 1.05 }, "5 s apart: back at rest in between")
    }

    /// A column keeps its HIGHEST sample, so a short arrival narrower than a column is not lost.
    @Test func aColumnKeepsItsPeakNotItsFirstSample() {
        let camera = CameraMotion(blocks: [block(6, 9)])
        // One column spanning 5–9 s: its first sample is at rest, its peak is the hold.
        let wide = camera.zoomProfile(from: at(5), to: at(9), columns: 1)
        #expect(wide.count == 1 && wide[0] > 1.5)
    }

    @Test func noColumnsOrAnEmptySpanIsNoProfile() {
        let camera = CameraMotion(blocks: [block(6, 9)])
        #expect(camera.zoomProfile(from: at(0), to: at(10), columns: 0).isEmpty)
        #expect(camera.zoomProfile(from: at(4), to: at(4), columns: 10).isEmpty)
        let other = BootEpoch(id: UUID(uuidString: "00000000-1111-2222-3333-444444444444")!)
        #expect(camera.zoomProfile(from: at(0), to: HostInstant(epoch: other, hostTime: Nanoseconds(1)),
                                   columns: 10).isEmpty, "a span across two boots is not a span")
    }
}
