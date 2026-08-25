import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// `zoom-blocks`' row carries its own warning: demo clicks are 1–3 s apart, and an
// over-eager merge collapses a whole demo into one zoom. The collapse test below is that
// warning turned into an assertion.

private let epoch = BootEpoch(id: UUID(uuidString: "B10CC0DE-2222-4333-8444-555566667777")!)
private let revision = GeometryRevision(id: 4)

private func at(seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
}

private func target(x: Double = 0.4, y: Double = 0.4,
                    extent: Double = 0.05) -> FramingTarget {
    FramingTarget(frame: NormalizedFrame(origin: NormalizedPoint(x: x, y: y),
                                         size: NormalizedSize(width: extent, height: extent),
                                         revision: revision),
                  role: "AXButton")
}

private func click(_ seconds: Double, _ t: FramingTarget = target()) -> FramedClick {
    FramedClick(instant: at(seconds: seconds), target: t)
}

private func seconds(_ n: Nanoseconds) -> Double { Double(n.rawValue) / 1_000_000_000 }

// MARK: - the row's own warning

/// **The collapse test.** Six clicks with a realistic demo cadence — paced, then a rapid
/// trio, then a pause — must NOT become one block. Measured before the implementation
/// existed: at a merge tolerance of 0.5 s this exact sequence collapses from four blocks to
/// two, because each merged block's end reaches the next block's start and the merge
/// chains. Overlap-only is what stops it.
@Test func aRealisticDemoCadenceDoesNotCollapseIntoOneZoom() {
    let clicks = [1.0, 2.5, 4.2, 5.0, 5.4, 8.0].map { click($0) }
    let blocks = ZoomBlock.blocks(for: clicks, coverage: 1)
    #expect(blocks.count == 4, """
        six clicks at a demo cadence produced \(blocks.count) block(s): \
        \(blocks.map { "[\(seconds($0.start.hostTime)), \(seconds($0.end.hostTime))]" }
            .joined(separator: " ")) — the row's own warning is that an over-eager merge \
        collapses a whole demo into one zoom
        """)
}

/// The rapid trio inside that sequence DOES become one block: 4.2, 5.0 and 5.4 are close
/// enough that three separate zooms would be a camera twitching. This is the other half of
/// the claim above — merging is not simply disabled.
@Test func clicksInsideOneAnothersBlocksBecomeOneZoom() {
    let blocks = ZoomBlock.blocks(for: [click(4.2), click(5.0), click(5.4)], coverage: 1)
    #expect(blocks.count == 1)
    #expect(abs(seconds(blocks[0].start.hostTime) - (4.2 - seconds(ZoomBlock.preRoll))) < 1e-6)
    #expect(abs(seconds(blocks[0].end.hostTime) - (5.4 + seconds(ZoomBlock.hold))) < 1e-6)
}

// MARK: - pre-roll and hold

/// The camera has to ARRIVE before the thing it is showing happens: a zoom that begins at
/// the click shows the aftermath, not the action.
@Test func aBlockOpensBeforeItsClickAndClosesAfterIt() {
    let blocks = ZoomBlock.blocks(for: [click(10.0)], coverage: 1)
    #expect(blocks.count == 1)
    #expect(seconds(blocks[0].start.hostTime) < 10.0)
    #expect(seconds(blocks[0].end.hostTime) > 10.0)
    #expect(abs(seconds(blocks[0].start.hostTime) - (10.0 - seconds(ZoomBlock.preRoll))) < 1e-6)
}

/// A click early enough that its pre-roll would start before the recording is clamped, not
/// dropped and not left negative — a negative instant is not a time this project can hold.
@Test func aClickAtTheVeryStartClampsItsPreRollRatherThanGoingNegative() {
    let blocks = ZoomBlock.blocks(for: [click(0.1)], coverage: 1)
    #expect(blocks.count == 1)
    #expect(blocks[0].start.hostTime.rawValue >= 0)
}

// MARK: - deterministic

/// Same clicks, any input order, same blocks. "Deterministic merge" is the row's word, and
/// a sweep that depended on arrival order would produce different footage from one
/// recording between runs.
@Test func theMergeIsIndependentOfInputOrder() {
    let ascending = [click(1.0), click(4.2), click(5.0), click(8.0)]
    let shuffled = [click(5.0), click(1.0), click(8.0), click(4.2)]
    let a = ZoomBlock.blocks(for: ascending, coverage: 1)
    let b = ZoomBlock.blocks(for: shuffled, coverage: 1)
    #expect(a == b)
}

@Test func noClicksProduceNoBlocks() {
    #expect(ZoomBlock.blocks(for: [], coverage: 1).isEmpty)
}

// MARK: - what a merged block frames

/// Two clicks far apart on screen, merged in time: the block frames the UNION, because a
/// camera that framed only one of them would leave the other action off-screen while it
/// happened. The union is wider than either, so its depth is shallower — the zoom pulls
/// back to cover both rather than picking a winner.
@Test func aMergedBlockFramesTheUnionOfItsTargetsAndPullsBack() {
    let left = target(x: 0.05, y: 0.5, extent: 0.05)
    let right = target(x: 0.80, y: 0.5, extent: 0.05)
    let merged = ZoomBlock.blocks(for: [click(4.0, left), click(4.5, right)], coverage: 1)
    #expect(merged.count == 1)

    let frame = merged[0].target.frame
    #expect(frame.minX <= 0.05 && frame.maxX >= 0.85,
            "the merged frame \(frame.minX)…\(frame.maxX) does not cover both targets")
    #expect(merged[0].zoom < FramingDepth.zoom(for: left, coverage: 1),
            "the merged block zooms deeper than one of its own targets would")
}

/// A block from ONE click keeps that click's own target and depth — merging is what
/// changes them, so a lone click must be untouched by the union logic.
@Test func aLoneBlockKeepsItsOwnTargetAndDepth() {
    let only = target(x: 0.3, y: 0.3, extent: 0.04)
    let blocks = ZoomBlock.blocks(for: [click(2.0, only)], coverage: 1)
    #expect(blocks[0].target == only)
    #expect(blocks[0].zoom == FramingDepth.zoom(for: only, coverage: 1))
}

// MARK: - epochs

/// Clicks from another boot session do not merge with this one's: their host times overlap
/// by coincidence, and a block spanning two epochs would be a duration computed across two
/// clocks — the `1a98402` family. Grouped, not silently interleaved.
@Test func clicksFromTwoEpochsNeverShareABlock() {
    let other = BootEpoch(id: UUID(uuidString: "0BADC0DE-0000-4000-8000-00000000000E")!)
    let foreign = FramedClick(
        instant: HostInstant(epoch: other, hostTime: Nanoseconds(4_300_000_000)),
        target: target())
    let blocks = ZoomBlock.blocks(for: [click(4.2), foreign], coverage: 1)
    #expect(blocks.count == 2, "clicks from two boot sessions were merged into one block")
    #expect(Set(blocks.map(\.start.epoch)).count == 2)
}
