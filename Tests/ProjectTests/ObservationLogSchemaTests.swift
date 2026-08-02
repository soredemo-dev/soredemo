import Testing
import Foundation
import Geometry
import Timeline
@testable import Project

// The three coordinator additions this task's format had to settle before any
// log existed, checked here rather than in `ObservationLogTests` because they
// are about the log *as a document* — its clock, its gap register and what it
// is allowed to hold — rather than about a record round-tripping.

private let epochA = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)
private let epochB = BootEpoch(id: UUID(uuidString: "0BF2A3C4-9D5E-4F60-8A71-B2C3D4E5F607")!)
private let rev = GeometryRevision(id: 0xbcf4_9ed7_dcb4_2be0)

private func at(_ ns: Int64, _ epoch: BootEpoch = epochA) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(ns))
}
private func span(_ start: Int64, _ duration: Int64, _ epoch: BootEpoch = epochA) -> HostRange {
    HostRange(epoch: epoch, start: Nanoseconds(start), duration: Nanoseconds(duration))
}
private func element(readAt range: HostRange) -> AXElementRecord {
    AXElementRecord(role: "AXButton", title: "Save",
                    frame: NormalizedFrame(origin: NormalizedPoint(x: 0.1, y: 0.1),
                                           size: NormalizedSize(width: 0.2, height: 0.05),
                                           revision: rev),
                    readInterval: range)
}
private func chain(instant: HostInstant,
                   hitTest: HostRange,
                   ancestorRead: HostRange? = nil) -> AXChainRecord {
    AXChainRecord(instant: instant,
                  clickPosition: NormalizedPoint(x: 0.15, y: 0.12),
                  clickRevision: rev,
                  hitTestGlobalX: 640, hitTestGlobalY: 400,
                  hitTestInterval: hitTest,
                  hit: element(readAt: hitTest),
                  ancestors: ancestorRead.map { [element(readAt: $0)] } ?? [],
                  children: nil,
                  truncation: .reachedRoot,
                  axCalls: 41, depthCap: 30, walkBudgetNanos: 35_000_000)
}

/// The five `GapSite` rows, each with something that looked.
private func fullGapWatches(looks: Int = 1) -> [GapWatch] {
    GapSite.allCases.map {
        GapWatch(site: $0, looks: looks, watchedSpanNanos: 1_000_000_000,
                 gapsFound: 0, lost: 0, lostUnit: unit(for: $0))
    }
}
private func unit(for site: GapSite) -> GapUnit {
    switch site {
    case .jsonlTruncatedTail: .bytes
    case .axAncestorWalk: .levels
    case .videoFramesNotProduced: .frames
    case .secureInput, .tapDisabled: .nanoseconds
    }
}

// MARK: - Addition B: the log's clock

@Test func everyRecordTypeAnswersWithTheEpochOfItsOwnInstant() {
    let pointer = PointerSample(instant: at(1), position: NormalizedPoint(x: 0.5, y: 0.5), revision: rev)
    let button = ButtonEvent(instant: at(2), position: NormalizedPoint(x: 0.5, y: 0.5),
                             revision: rev, button: .right, phase: .down)
    let key = KeySample(instant: at(3), shortcut: "cmd-s")
    let secure = SecureInputInterval(interval: span(4, 10), endedBy: .secureInputDisabled)
    let tap = TapDisabledInterval(interval: span(5, 10), disabledBy: nil,
                                  lowerBoundFrom: .lastEnabledPoll, detectedBy: .enabledPoll)

    #expect(pointer.epochs == [epochA])
    #expect(button.epochs == [epochA])
    #expect(key.epochs == [epochA])
    #expect(secure.epochs == [epochA])
    #expect(tap.epochs == [epochA])
    // No record type may answer with nothing — `checkEpoch` reports an empty
    // answer as a fault, and a type that produced one would make the guard
    // vacuous for exactly itself.
    for record: any ObservationRecord in [pointer, button, key, secure, tap] {
        #expect(!record.epochs.isEmpty, "\(record.kind) answered `epochs` with nothing")
    }
}

/// The record type where "all of them, not just the first" is load-bearing.
@Test func anAXChainReportsTheEpochOfEveryIntervalItHolds() {
    let straddling = chain(instant: at(100), hitTest: span(100, 50),
                           ancestorRead: span(200, 10, epochB))
    #expect(straddling.epochs.contains(epochA))
    #expect(straddling.epochs.contains(epochB),
            "an ancestor read in another boot session did not show up in `epochs`")
}

@Test func checkEpochAcceptsARecordStampedWithTheLogsOwnEpoch() throws {
    let s = PointerSample(instant: at(1), position: NormalizedPoint(x: 0, y: 0), revision: rev)
    try ObservationLog.checkEpoch(of: s, against: epochA)
}

@Test func checkEpochRefusesARecordFromAnotherBootSession() {
    let s = PointerSample(instant: at(1, epochB), position: NormalizedPoint(x: 0, y: 0), revision: rev)
    #expect(throws: ObservationLogError.foreignEpoch(kind: "pointer",
                                                     expected: epochA.id, found: epochB.id)) {
        try ObservationLog.checkEpoch(of: s, against: epochA)
    }
}

/// The `AXChainRecord` case: the click is on the log's clock and one element
/// read is not. A guard that checked only the primary instant would let this
/// through, and the record's own `clickToHitTestAnswerNanos` would then be
/// `nil` forever with nothing on disk saying why.
@Test func checkEpochRefusesAChainWhoseElementWasReadInAnotherEpoch() {
    let straddling = chain(instant: at(100), hitTest: span(100, 50),
                           ancestorRead: span(200, 10, epochB))
    #expect(throws: ObservationLogError.foreignEpoch(kind: "axChain",
                                                     expected: epochA.id, found: epochB.id)) {
        try ObservationLog.checkEpoch(of: straddling, against: epochA)
    }
}

/// A record type that carries no instant at all. There is none in the package
/// today; this is the fixture that keeps the `noEpoch` branch from being dead
/// text the first time somebody adds one.
private struct RecordWithNoInstant: ObservationRecord {
    let kind = "noInstant"
    var epochs: [BootEpoch] { [] }
}

@Test func checkEpochRefusesARecordThatCarriesNoInstantAtAll() {
    #expect(throws: ObservationLogError.noEpoch(kind: "noInstant")) {
        try ObservationLog.checkEpoch(of: RecordWithNoInstant(), against: epochA)
    }
}

// MARK: - Addition A: zero versus never-measured

@Test func thereIsOneGapSiteForEachRowOfD6a() {
    #expect(GapSite.allCases.count == 5,
            "D6a has five rows; a sixth needs a case here and a GapWatch in every trailer")
}

/// The middle state — present, and nothing looked.
@Test func aGapWatchWithNoLooksIsNotAMeasurement() {
    let nothingLooked = GapWatch(site: .tapDisabled, looks: 0, watchedSpanNanos: 0,
                                 gapsFound: 0, lost: 0, lostUnit: .nanoseconds)
    let somethingLooked = GapWatch(site: .tapDisabled, looks: 1247, watchedSpanNanos: 124_700_000_000,
                                   gapsFound: 0, lost: 0, lostUnit: .nanoseconds)
    #expect(!nothingLooked.isAMeasurement)
    #expect(somethingLooked.isAMeasurement)
    // Both report zero gaps. The point of the type is that the two rows do not
    // read the same, so the printed form must differ too.
    #expect(nothingLooked.gapsFound == somethingLooked.gapsFound)
    #expect(nothingLooked.accounting.contains("NOTHING WAS LOOKING"))
    #expect(!somethingLooked.accounting.contains("NOTHING WAS LOOKING"))
}

@Test func aGapWatchThatFoundGapsWithoutLookingFailsToDecode() {
    let contradictory = Data("""
        {"site":"tapDisabled","looks":0,"watchedSpanNanos":0,\
        "gapsFound":3,"lost":400000000,"lostUnit":"nanoseconds"}
        """.utf8)
    #expect(throws: (any Error).self) {
        let _: GapWatch = try ObservationLog.decode(contradictory)
    }
}

@Test func aGapWatchWithANegativeCountFailsToDecode() {
    let negative = Data("""
        {"site":"secureInput","looks":-1,"watchedSpanNanos":0,\
        "gapsFound":0,"lost":0,"lostUnit":"nanoseconds"}
        """.utf8)
    #expect(throws: (any Error).self) {
        let _: GapWatch = try ObservationLog.decode(negative)
    }
}

@Test func aGapWatchRoundTripsThroughOneJSONLLine() throws {
    let watch = GapWatch(site: .jsonlTruncatedTail, looks: 1, watchedSpanNanos: 5_000,
                         gapsFound: 1, lost: 23, lostUnit: .bytes)
    let line = try ObservationLog.encode(watch)
    #expect(!line.contains(UInt8(ascii: "\n")))
    let back: GapWatch = try ObservationLog.decode(line)
    #expect(back == watch)
}

// MARK: - the trailer, and the site it must not be able to omit

@Test func aTrailerRoundTripsWithOneRowPerGapSite() throws {
    let trailer = ObservationLogTrailer(segmentIndex: 2, hostRange: span(0, 20_000_000_000),
                                        endedBy: .paused,
                                        recordCounts: ["pointer": 1200, "button": 14, "key": 0],
                                        gapWatches: fullGapWatches())
    let line = try ObservationLog.encode(trailer)
    #expect(try ObservationLog.kind(of: line) == "logTrailer")
    let back: ObservationLogTrailer = try ObservationLog.decode(line)
    #expect(back == trailer)
    #expect(back.endedBy == .paused)
}

/// **The one that Addition A is for.** A synthesised `Decodable` accepts a
/// four-row trailer silently, and a reader then sees four rows, has no reason
/// to count them, and reads the absent fifth as "no gaps at that site".
///
/// The fixture is assembled as **bytes**, not as a value: the memberwise
/// initialiser `precondition`s on the complete set, so a short trailer cannot
/// be constructed in memory at all. Off disk is the only way one arrives,
/// which is precisely why the check has to be on the decode path.
@Test func aTrailerWhoseBytesOmitASiteFailsToDecode() throws {
    let watches = fullGapWatches()
    let dropped = watches.first { $0.site == .secureInput }
    let shortList = watches.filter { $0.site != .secureInput }
    let json = """
        {"kind":"logTrailer","segmentIndex":0,\
        "hostRange":\(String(decoding: try ObservationLog.encode(span(0, 1)), as: UTF8.self)),\
        "endedBy":\(String(decoding: try ObservationLog.encode(SegmentBoundary.stopped), as: UTF8.self)),\
        "recordCounts":{},\
        "gapWatches":\(String(decoding: try ObservationLog.encode(shortList), as: UTF8.self))}
        """
    #expect(dropped != nil, "the fixture dropped nothing — it would pass vacuously")
    #expect(throws: (any Error).self) {
        let _: ObservationLogTrailer = try ObservationLog.decode(Data(json.utf8))
    }
    // The complete list, through the identical construction, must decode — so a
    // failure above is about the missing site and not about the fixture's shape.
    let full = """
        {"kind":"logTrailer","segmentIndex":0,\
        "hostRange":\(String(decoding: try ObservationLog.encode(span(0, 1)), as: UTF8.self)),\
        "endedBy":\(String(decoding: try ObservationLog.encode(SegmentBoundary.stopped), as: UTF8.self)),\
        "recordCounts":{},\
        "gapWatches":\(String(decoding: try ObservationLog.encode(watches), as: UTF8.self))}
        """
    let back: ObservationLogTrailer = try ObservationLog.decode(Data(full.utf8))
    #expect(back.gapWatches.count == GapSite.allCases.count)
}

@Test func aTrailerWithTwoRowsForOneSiteFailsToDecode() throws {
    var watches = fullGapWatches()
    watches.append(GapWatch(site: .tapDisabled, looks: 0, watchedSpanNanos: 0,
                            gapsFound: 0, lost: 0, lostUnit: .nanoseconds))
    let json = """
        {"kind":"logTrailer","segmentIndex":0,\
        "hostRange":\(String(decoding: try ObservationLog.encode(span(0, 1)), as: UTF8.self)),\
        "endedBy":\(String(decoding: try ObservationLog.encode(SegmentBoundary.stopped), as: UTF8.self)),\
        "recordCounts":{},\
        "gapWatches":\(String(decoding: try ObservationLog.encode(watches), as: UTF8.self))}
        """
    #expect(throws: (any Error).self) {
        let _: ObservationLogTrailer = try ObservationLog.decode(Data(json.utf8))
    }
}

@Test func theTrailerNamesTheSitesNothingWasWatching() {
    var watches = fullGapWatches().filter { $0.site != .secureInput }
    watches.append(GapWatch(site: .secureInput, looks: 0, watchedSpanNanos: 0,
                            gapsFound: 0, lost: 0, lostUnit: .nanoseconds))
    let trailer = ObservationLogTrailer(segmentIndex: 0, hostRange: span(0, 1),
                                        endedBy: .stopped, recordCounts: [:],
                                        gapWatches: watches)
    #expect(trailer.sitesNothingWasWatching == [.secureInput])
    #expect(trailer.accounting.contains("NOTHING WAS LOOKING"))
}

/// `"key": 0` and no `"key"` key are different facts, and the dictionary is
/// what keeps them apart. A set of named counters could not express the second.
@Test func recordCountsKeepAZeroApartFromAnAbsentKey() throws {
    let sawNoShortcuts = ObservationLogTrailer(segmentIndex: 0, hostRange: span(0, 1),
                                               endedBy: .stopped,
                                               recordCounts: ["pointer": 900, "key": 0],
                                               gapWatches: fullGapWatches())
    let doesNotEmitShortcuts = ObservationLogTrailer(segmentIndex: 0, hostRange: span(0, 1),
                                                     endedBy: .stopped,
                                                     recordCounts: ["pointer": 900],
                                                     gapWatches: fullGapWatches())
    #expect(sawNoShortcuts != doesNotEmitShortcuts)
    let a: ObservationLogTrailer = try ObservationLog.decode(try ObservationLog.encode(sawNoShortcuts))
    let b: ObservationLogTrailer = try ObservationLog.decode(try ObservationLog.encode(doesNotEmitShortcuts))
    #expect(a.recordCounts["key"] == 0)
    #expect(b.recordCounts["key"] == nil)
}

@Test func aTrailerWithANegativeRecordCountFailsToDecode() throws {
    let json = """
        {"kind":"logTrailer","segmentIndex":0,\
        "hostRange":\(String(decoding: try ObservationLog.encode(span(0, 1)), as: UTF8.self)),\
        "endedBy":\(String(decoding: try ObservationLog.encode(SegmentBoundary.stopped), as: UTF8.self)),\
        "recordCounts":{"pointer":-1},\
        "gapWatches":\(String(decoding: try ObservationLog.encode(fullGapWatches()), as: UTF8.self))}
        """
    #expect(throws: (any Error).self) {
        let _: ObservationLogTrailer = try ObservationLog.decode(Data(json.utf8))
    }
}

// MARK: - the header

@Test func aHeaderRoundTripsAndSaysWhatItIsALogOf() throws {
    let header = ObservationLogHeader(epoch: epochA, segmentIndex: 3,
                                      mediaFilename: "master-03.mov", revision: rev,
                                      blindness: [])
    let line = try ObservationLog.encode(header)
    #expect(try ObservationLog.kind(of: line) == "logHeader")
    let back: ObservationLogHeader = try ObservationLog.decode(line)
    #expect(back == header)
    #expect(back.schemaVersion == ObservationLog.schemaVersion)
    #expect(back.mediaFilename == "master-03.mov")
    #expect(back.epoch == epochA)
}

/// `CaptureError.inputMonitoringUnavailable` maps to `.observationBlind` and
/// had no consumer anywhere until this field. A recording made without Input
/// Monitoring is byte-identical to a recording of somebody not touching the
/// mouse; this is what tells them apart.
@Test func aHeaderCarriesWhyAWholeSegmentSawNothing() throws {
    let blind = ObservationLogHeader(epoch: epochA, segmentIndex: 0,
                                     mediaFilename: "master-00.mov", revision: rev,
                                     blindness: [.inputMonitoringUnavailable])
    let sighted = ObservationLogHeader(epoch: epochA, segmentIndex: 0,
                                       mediaFilename: "master-00.mov", revision: rev,
                                       blindness: [])
    #expect(blind != sighted, "a blind segment and a clear one encode identically")
    let back: ObservationLogHeader = try ObservationLog.decode(try ObservationLog.encode(blind))
    #expect(back.blindness == [.inputMonitoringUnavailable])
}

/// The three-state rule for the header: an absent `blindness` key is not
/// "nothing was blind", it is a log from a build that did not look.
@Test func aHeaderWithNoBlindnessKeyFailsToDecode() throws {
    let json = """
        {"kind":"logHeader","schemaVersion":1,\
        "epoch":\(String(decoding: try ObservationLog.encode(epochA), as: UTF8.self)),\
        "segmentIndex":0,"mediaFilename":"master-00.mov",\
        "revision":\(String(decoding: try ObservationLog.encode(rev), as: UTF8.self))}
        """
    #expect(throws: (any Error).self) {
        let _: ObservationLogHeader = try ObservationLog.decode(Data(json.utf8))
    }
}

// MARK: - Addition A at D6a's first row: the JSONL reader

/// `droppedBytes == 0` had two readings — a clean file, and no file — and this
/// is the companion that separates them.
@Test func theJSONLReaderReportsHowManyBytesItExamined() {
    let clean = JSONLReader.lines(from: Data("a\nbb\nccc\n".utf8))
    #expect(clean.droppedBytes == 0)
    #expect(clean.bytesScanned == 9)

    let nothing = JSONLReader.lines(from: Data())
    #expect(nothing.droppedBytes == 0)
    #expect(nothing.bytesScanned == 0)

    // The two rows above carry the identical `droppedBytes`. Without
    // `bytesScanned` they are the same measurement.
    #expect(clean.droppedBytes == nothing.droppedBytes)
    #expect(clean.bytesScanned != nothing.bytesScanned)
    #expect(nothing.accounting.contains("NOTHING WAS READ"))
    #expect(!clean.accounting.contains("NOTHING WAS READ"))
}

@Test func bytesScannedCountsTheDroppedTailToo() {
    // The tail is dropped from `lines` but it WAS examined, so it is part of
    // what the reader looked at. A `bytesScanned` that excluded it would be a
    // second name for "bytes kept", which is what `lines` already reports.
    let r = JSONLReader.lines(from: Data("a\nb\n{\"partial\":".utf8))
    #expect(r.droppedBytes == 11)
    #expect(r.bytesScanned == 15)
}
