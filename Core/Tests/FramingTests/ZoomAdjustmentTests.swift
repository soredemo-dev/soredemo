import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

private let epoch = BootEpoch(id: UUID(uuidString: "9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07")!)
/// **`.rounded()`, not a truncating `Int64(_:)`.** `4.1 * 1_000_000_000` is 4099999999.99…
/// in binary floating point, and truncating gives 4099999999 — one nanosecond short of what
/// the code, working in integers throughout, produces. The first version of this helper
/// truncated and two tests failed against correct arithmetic.
private func at(_ seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64((seconds * 1_000_000_000).rounded())))
}

/// **What makes a zoom an object on a timeline rather than a decision in a panel.** A review
/// panel that only offers "don't zoom" can reject a zoom but cannot fix one that is a quarter
/// of a second late. Screen Studio shows each click as a keyframe with an adjustable duration;
/// ScreenKite gives zooms a lane of their own.
@Suite struct ZoomAdjustmentTests {
    private func block(originSeconds: Double, start: Double, end: Double) -> ZoomBlock {
        ZoomBlock(
            origin: at(originSeconds), start: at(start), end: at(end),
            target: FramingTarget(
                frame: NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                                       size: NormalizedSize(width: 0.1, height: 0.1),
                                       revision: GeometryRevision(id: 1)),
                role: "AXButton"),
            zoom: 2.0)
    }

    @Test func noAdjustmentLeavesABlockAlone() {
        let blocks = [block(originSeconds: 5, start: 4.6, end: 6)]
        #expect([ZoomAdjustment]().applied(to: blocks) == blocks)
    }

    /// Moving a block moves BOTH ends: the end delta is measured from the block's own end,
    /// which has already travelled with the start.
    @Test func movingABlockMovesBothEnds() {
        let blocks = [block(originSeconds: 5, start: 4.6, end: 6)]
        let moved = [ZoomAdjustment(origin: at(5)).movedBy(-500_000_000)].applied(to: blocks)
        #expect(moved[0].start == at(4.1))
        #expect(moved[0].end == at(5.5))
        #expect(moved[0].origin == at(5), "moving a zoom changed which click it belongs to")
    }

    @Test func resizingChangesTheEndAlone() {
        let blocks = [block(originSeconds: 5, start: 4.6, end: 6)]
        let longer = [ZoomAdjustment(origin: at(5)).resizedBy(1_000_000_000)].applied(to: blocks)
        #expect(longer[0].start == at(4.6))
        #expect(longer[0].end == at(7))
    }

    /// **A block whose adjustment would empty it is dropped, not clamped.** A person dragging
    /// an end past the start has said something, and the honest reading is "no zoom here"; a
    /// one-nanosecond block is a zoom nobody can see and nobody asked for.
    @Test func anAdjustmentThatEmptiesABlockRemovesIt() {
        let blocks = [block(originSeconds: 5, start: 4.6, end: 6)]
        #expect([ZoomAdjustment(origin: at(5)).resizedBy(-2_000_000_000)]
            .applied(to: blocks).isEmpty)
    }

    /// A block cannot begin before the recording did.
    @Test func aBlockDraggedBeforeTheStartClampsToZero() {
        let blocks = [block(originSeconds: 1, start: 0.6, end: 2)]
        let moved = [ZoomAdjustment(origin: at(1)).movedBy(-5_000_000_000)].applied(to: blocks)
        #expect(moved[0].start.hostTime.rawValue == 0)
        #expect(moved[0].end.hostTime.rawValue > 0, "the block collapsed instead of clamping")
    }

    /// Suppressing keeps the timing, so unsuppressing restores what a person had set — the
    /// same reason `AudioMix` keeps a muted source's level.
    @Test func suppressingKeepsTheTimingItHides() {
        let blocks = [block(originSeconds: 5, start: 4.6, end: 6)]
        let adjusted = ZoomAdjustment(origin: at(5)).movedBy(-500_000_000)
        #expect([adjusted.settingSuppressed(true)].applied(to: blocks).isEmpty)
        // …and turning it back on returns to the moved position, not the derived one.
        let back = [adjusted.settingSuppressed(true).settingSuppressed(false)].applied(to: blocks)
        #expect(back[0].start == at(4.1))
    }

    /// **Deltas, not absolute times**, so a correction survives `preRoll` being retuned. The
    /// same adjustment applied to a block derived with a different pre-roll still moves it by
    /// what the person asked for.
    @Test func anAdjustmentSurvivesTheDerivationChangingItsMind() {
        let adjustment = [ZoomAdjustment(origin: at(5)).movedBy(-250_000_000)]
        // Pre-roll of 0.4 s…
        let narrow = adjustment.applied(to: [block(originSeconds: 5, start: 4.6, end: 6)])
        // …and of 0.8 s. Both move by the same quarter second.
        let wide = adjustment.applied(to: [block(originSeconds: 5, start: 4.2, end: 6)])
        #expect(narrow[0].start == at(4.35))
        #expect(wide[0].start == at(3.95))
    }

    /// An adjustment for a block that is no longer derived — the click stopped passing the
    /// gates — applies to nothing rather than resurrecting a zoom.
    @Test func anAdjustmentForAVanishedBlockDoesNothing() {
        let blocks = [block(originSeconds: 5, start: 4.6, end: 6)]
        let other = [ZoomAdjustment(origin: at(9)).movedBy(-500_000_000)]
        #expect(other.applied(to: blocks) == blocks)
    }

    // MARK: - the set

    @Test func replacingKeepsOneAdjustmentPerOrigin() {
        var set: [ZoomAdjustment] = []
        set = set.replacing(ZoomAdjustment(origin: at(5)).movedBy(-100))
        set = set.replacing(ZoomAdjustment(origin: at(5)).movedBy(-200))
        set = set.replacing(ZoomAdjustment(origin: at(9)).movedBy(-300))
        #expect(set.count == 2)
        #expect(set.adjustment(for: at(5)).startDelta.rawValue == -200)
    }

    /// **An adjustment that says "leave it alone" is dropped.** Keeping it would make a
    /// "has this been edited" check on the whole set lie, which is what a UI uses to decide
    /// whether to offer a reset.
    @Test func anAdjustmentThatChangesNothingIsNotKept() {
        let set = [ZoomAdjustment].init().replacing(ZoomAdjustment(origin: at(5)))
        #expect(set.isEmpty)

        // …including one edited back to where it started.
        let edited = [ZoomAdjustment].init()
            .replacing(ZoomAdjustment(origin: at(5)).movedBy(-100))
        #expect(edited.count == 1)
        #expect(edited.replacing(edited[0].movedBy(100)).isEmpty)
    }

    @Test func askingForAnUntouchedOriginGivesAFreshAdjustment() {
        let fresh = [ZoomAdjustment]().adjustment(for: at(5))
        #expect(fresh.origin == at(5))
        #expect(!fresh.changesAnything)
    }

    @Test func anAdjustmentSurvivesCoding() throws {
        let adjustment = ZoomAdjustment(origin: at(5)).movedBy(-250_000_000)
            .resizedBy(500_000_000).settingSuppressed(true)
        let data = try JSONEncoder().encode(adjustment)
        #expect(try JSONDecoder().decode(ZoomAdjustment.self, from: data) == adjustment)
    }
}
