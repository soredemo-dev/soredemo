import Foundation
import Testing
@testable import Timeline

private func ns(_ value: Int64) -> Nanoseconds { Nanoseconds(value) }

/// Ported from a native editor (GPL-3.0) — see `SnapEngine`'s header and `NOTICE.md`. These tests
/// are written here rather than ported: the value of a port is the algorithm, and a test that
/// came with it would only prove the port copied faithfully, not that the behaviour is right.
@Suite struct SnapEngineTests {
    private let edges: [SnapEngine.Target] = [
        SnapEngine.Target(time: ns(1_000), kind: .clipEdge),
        SnapEngine.Target(time: ns(5_000), kind: .clipEdge),
    ]

    @Test func aPositionInsideTheThresholdSnapsToTheEdge() {
        var state = SnapEngine.State()
        let result = SnapEngine.snap(position: ns(1_040), targets: edges,
                                     state: &state, threshold: ns(100))
        #expect(result?.time == ns(1_000))
    }

    @Test func aPositionOutsideEveryThresholdDoesNotSnap() {
        var state = SnapEngine.State()
        #expect(SnapEngine.snap(position: ns(3_000), targets: edges,
                                state: &state, threshold: ns(100)) == nil)
    }

    /// **The reason to take this algorithm rather than write the obvious one.** A plain
    /// nearest-within-N rule makes a drag near an edge oscillate: one nanosecond of movement
    /// flips between snapped and free and the clip jitters under the cursor. A held snap
    /// survives out to 1.5× the threshold.
    @Test func anExistingSnapHoldsPastTheThresholdThatMadeIt() {
        var state = SnapEngine.State()
        _ = SnapEngine.snap(position: ns(1_040), targets: edges, state: &state, threshold: ns(100))

        // 130 away: outside the 100 that would have made the snap, inside the 150 that holds it.
        #expect(SnapEngine.snap(position: ns(1_130), targets: edges,
                                state: &state, threshold: ns(100))?.time == ns(1_000))
        // 160 away: past the hold threshold, so it lets go — and finds nothing else.
        #expect(SnapEngine.snap(position: ns(1_160), targets: edges,
                                state: &state, threshold: ns(100)) == nil)
        #expect(state.snappedTo == nil, "the state must forget a snap it released")
    }

    /// A held snap whose target has gone — the clip it belonged to was deleted mid-drag — must
    /// release rather than keep returning a position nothing is at any more.
    @Test func aHeldSnapReleasesWhenItsTargetDisappears() {
        var state = SnapEngine.State()
        _ = SnapEngine.snap(position: ns(1_040), targets: edges, state: &state, threshold: ns(100))
        let remaining = [SnapEngine.Target(time: ns(5_000), kind: .clipEdge)]
        #expect(SnapEngine.snap(position: ns(1_040), targets: remaining,
                                state: &state, threshold: ns(100)) == nil)
    }

    /// The playhead's wider threshold, ISOLATED from its distance.
    ///
    /// **The first draft of this test could not tell the two apart.** It put the probe nearer
    /// the playhead than the clip edge, so the playhead would have won on distance alone and
    /// the assertion said nothing about thresholds. The targets are placed equidistant here —
    /// 130 either side — so the only thing that can decide it is that 130 is inside the
    /// playhead's 150 and outside a clip edge's 100.
    @Test func thePlayheadIsReachableFromFartherAway() {
        let mixed = [
            SnapEngine.Target(time: ns(1_000), kind: .playhead),
            SnapEngine.Target(time: ns(1_260), kind: .clipEdge),
        ]
        var state = SnapEngine.State()
        #expect(SnapEngine.snap(position: ns(1_130), targets: mixed,
                                state: &state, threshold: ns(100))?.time == ns(1_000))
    }

    /// …and the wider threshold is reach, not precedence: a nearer clip edge still wins.
    @Test func aNearerClipEdgeBeatsThePlayheadsReach() {
        let mixed = [
            SnapEngine.Target(time: ns(1_000), kind: .playhead),
            SnapEngine.Target(time: ns(1_100), kind: .clipEdge),
        ]
        var state = SnapEngine.State()
        // Both in range — 90 from the playhead, 10 from the edge — so distance decides.
        #expect(SnapEngine.snap(position: ns(1_090), targets: mixed,
                                state: &state, threshold: ns(100))?.time == ns(1_100))
    }

    /// A dragged clip looks for targets with BOTH its edges, and the result says which found
    /// one — the caller needs that to place the clip rather than its probe.
    @Test func aClipsEndCanFindTheTargetItsStartCouldNotReach() {
        var state = SnapEngine.State()
        // A 3,000-long clip dragged so its END lands 50 from the 5,000 edge while its start,
        // at 2,050, is over a thousand from anything. **The first draft used a start of 1,030,
        // which is 30 from the 1,000 edge** — so the start probe won and the test proved the
        // opposite of its name. The code was right; the fixture was not.
        let result = SnapEngine.snap(position: ns(2_050), probeOffsets: [ns(0), ns(3_000)],
                                     targets: edges, state: &state, threshold: ns(100))
        #expect(result?.time == ns(5_000))
        #expect(result?.probeOffset == ns(3_000), "the caller cannot place the clip without this")
    }

    @Test func aZeroThresholdSnapsToNothing() {
        var state = SnapEngine.State()
        #expect(SnapEngine.snap(position: ns(1_000), targets: edges,
                                state: &state, threshold: ns(0)) == nil)
    }

    // MARK: - targets from a timeline

    /// **Source time, not output time.** The timeline a person drags on is drawn from the
    /// recording, so its visible edges are source positions — and the two spaces are equal
    /// only until the first cut, which is when a mistake here would start showing.
    @Test func targetsAreEveryClipBoundaryInSourceTime() {
        let timeline = EditTimeline.whole(duration: ns(10_000))
            .removing(sourceRange: 2_000..<5_000)
        let targets = SnapEngine.targets(in: timeline)
        #expect(targets.map(\.time.rawValue) == [0, 2_000, 5_000, 10_000])
        #expect(targets.allSatisfy { $0.kind == .clipEdge })
    }

    @Test func thePlayheadIsIncludedOnlyWhenGiven() {
        let timeline = EditTimeline.whole(duration: ns(10_000))
        #expect(SnapEngine.targets(in: timeline).count == 2)
        let withPlayhead = SnapEngine.targets(in: timeline, playhead: ns(3_000))
        #expect(withPlayhead.first == SnapEngine.Target(time: ns(3_000), kind: .playhead))
    }
}
