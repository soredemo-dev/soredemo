import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// The review list: which proposals a person still has to decide about, placed on the recording's
// clock. `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`, "The review list".
//
// **The recording starts at 100 s**, so a proposal placed by its absolute host time rather than
// by its offset from the recording's start would land 100 s late, and every expected range below
// is a literal: the dead-air fixture's three removals are 100–103.5, 104.5–114.5 and 115.5–120,
// which on the recording's own clock are 0–3.5, 4.5–14.5 and 15.5–20.

private let epoch = BootEpoch(id: UUID(uuidString: "C07AE71E-0000-4000-8000-000000000003")!)
private let otherBoot = BootEpoch(id: UUID(uuidString: "0BADB007-0000-4000-8000-000000000004")!)

private let second: Int64 = 1_000_000_000

private func at(_ seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64((seconds * 1_000_000_000).rounded())))
}

private func offset(_ seconds: Double) -> Int64 { Int64((seconds * 1_000_000_000).rounded()) }

private let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(100 * second), wallClockUnixNanos: 0)

private func step(_ number: Int, _ seconds: Double, until end: Double) -> RecordedStep {
    RecordedStep(origin: at(seconds), end: at(end), number: number, label: "Step \(number)",
                 role: "AXButton", application: "Finder", frame: nil)
}

/// Presses at 104 s and 115 s in a recording from 100 s to 120 s, nothing else: three proposals.
private func proposals() throws -> [CutProposal] {
    let take = try TakeActivity(
        recording: HostRange(epoch: epoch, start: Nanoseconds(100 * second), duration: Nanoseconds(20 * second)),
        steps: [step(1, 104, until: 115), step(2, 115, until: 120)],
        pointer: [], buttons: [], shortcuts: [], speech: [], unobserved: [])
    return DeadAirProposer().proposals(for: take)
}

private let uncut = EditTimeline.whole(duration: Nanoseconds(20 * second))

@Suite struct CutReviewTests {
    @Test func eachProposalIsPlacedOnTheRecordingsOwnClock() throws {
        let listing = CutReview.listing(try proposals(), dismissed: [], edit: uncut, anchor: anchor)
        #expect(listing.rows.map(\.source) == [offset(0)..<offset(3.5),
                                                offset(4.5)..<offset(14.5),
                                                offset(15.5)..<offset(20)])
    }

    @Test func anUneditedRecordingListsEveryProposalWhole() throws {
        let listing = CutReview.listing(try proposals(), dismissed: [], edit: uncut, anchor: anchor)
        #expect(listing.rows.map(\.survival) == [.whole, .whole, .whole])
        #expect(listing.alreadyCut == 0 && listing.dismissed == 0 && listing.unplaceable == 0)
    }

    /// Cut by hand, or accepted: either way nothing is left to decide, and undoing the cut brings
    /// it back, because the list is derived from the timeline rather than remembering acceptance.
    @Test func aProposalWhoseSpanIsAlreadyCutLeavesTheList() throws {
        let edit = uncut.removing(sourceRange: offset(4)..<offset(15))
        let listing = CutReview.listing(try proposals(), dismissed: [], edit: edit, anchor: anchor)
        #expect(listing.rows.map(\.source) == [offset(0)..<offset(3.5), offset(15.5)..<offset(20)])
        #expect(listing.alreadyCut == 1)
    }

    @Test func aProposalCutOnlyInPartStaysAndSaysSo() throws {
        let edit = uncut.removing(sourceRange: offset(10)..<offset(12))
        let listing = CutReview.listing(try proposals(), dismissed: [], edit: edit, anchor: anchor)
        #expect(listing.rows.map(\.survival) == [.whole, .partly, .whole])
    }

    @Test func aDismissedProposalLeavesTheListAndIsCounted() throws {
        let all = try proposals()
        let listing = CutReview.listing(all, dismissed: [all[1].key], edit: uncut, anchor: anchor)
        #expect(listing.rows.map(\.proposal) == [all[0], all[2]])
        #expect(listing.dismissed == 1)
    }

    /// An anchor from another boot cannot place anything. Each proposal is counted as such rather
    /// than placed at a subtraction that would read as a legal time.
    @Test func proposalsAnAnchorFromAnotherBootCannotPlaceAreCountedNotListed() throws {
        let foreign = EpochAnchor(epoch: otherBoot, hostTime: Nanoseconds(100 * second), wallClockUnixNanos: 0)
        let listing = CutReview.listing(try proposals(), dismissed: [], edit: uncut, anchor: foreign)
        #expect(listing.rows.isEmpty)
        #expect(listing.unplaceable == 3)
    }

    /// Every proposal goes exactly one way: listed, already cut, dismissed, or unplaceable.
    @Test func everyProposalIsAccountedForExactlyOnce() throws {
        let all = try proposals()
        let edit = uncut.removing(sourceRange: offset(15)..<offset(20))
        let listing = CutReview.listing(all, dismissed: [all[0].key], edit: edit, anchor: anchor)
        #expect(listing.rows.count == 1 && listing.dismissed == 1 && listing.alreadyCut == 1)
        #expect(listing.rows.count + listing.alreadyCut + listing.dismissed + listing.unplaceable == all.count)
    }

    @Test func acceptingARowCutsExactlyItsSpanAndItLeavesTheList() throws {
        let all = try proposals()
        let row = try #require(CutReview.listing(all, dismissed: [], edit: uncut, anchor: anchor).rows.dropFirst().first)
        let accepted = CutReview.accepting(row, in: uncut)
        #expect(accepted.outputDuration == Nanoseconds(10 * second), "ten seconds removed from twenty")
        #expect(accepted.survival(ofSource: offset(4.5)..<offset(14.5)) == .gone)
        #expect(accepted.survival(ofSource: offset(4)..<offset(4.5)) == .whole, "the breath before is kept")
        #expect(accepted.survival(ofSource: offset(14.5)..<offset(15)) == .whole, "and the breath after")
        let after = CutReview.listing(all, dismissed: [], edit: accepted, anchor: anchor)
        #expect(after.rows.count == 2 && after.alreadyCut == 1)
    }

    @Test func acceptingAPartlyCutRowCutsWhatIsLeftOfIt() throws {
        let all = try proposals()
        let edit = uncut.removing(sourceRange: offset(10)..<offset(12))
        let row = try #require(CutReview.listing(all, dismissed: [], edit: edit, anchor: anchor).rows.dropFirst().first)
        #expect(row.survival == .partly)
        let accepted = CutReview.accepting(row, in: edit)
        #expect(accepted.survival(ofSource: offset(4.5)..<offset(14.5)) == .gone)
        #expect(accepted.outputDuration == Nanoseconds(10 * second), "the two seconds already cut are not cut twice")
    }

    @Test func acceptingEveryRowIsOneEditThatRemovesEachOfThem() throws {
        let rows = CutReview.listing(try proposals(), dismissed: [], edit: uncut, anchor: anchor).rows
        let accepted = CutReview.acceptingAll(rows, in: uncut)
        #expect(accepted.outputDuration == Nanoseconds(2 * second), "20 s less 3.5, 10 and 4.5")
        #expect(CutReview.listing(try proposals(), dismissed: [], edit: accepted, anchor: anchor).rows.isEmpty)
    }

    /// What a person reads before cutting all: what still plays of each, not each one's length.
    @Test func whatCuttingAllWouldRemoveCountsOnlyWhatStillPlays() throws {
        let edit = uncut.removing(sourceRange: offset(10)..<offset(12))
        let rows = CutReview.listing(try proposals(), dismissed: [], edit: edit, anchor: anchor).rows
        #expect(CutReview.remaining(rows, in: edit) == Nanoseconds(16 * second), "18 s of proposals, 2 s already gone")
    }

    @Test func dismissalsAreWrittenInTheSameOrderWhateverOrderTheSetHolds() throws {
        let keys = try proposals().map(\.key)
        #expect(CutProposal.Key.fileOrder(Set(keys)) == keys, "by instant: the proposals are already in time order")
        #expect(CutProposal.Key.fileOrder(Set(keys.reversed())) == keys)
    }
}
