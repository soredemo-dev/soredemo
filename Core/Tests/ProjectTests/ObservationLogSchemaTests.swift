import Testing
import Foundation
import Geometry
import Timeline
@testable import Project

// The log *as a document*: its clock, its gap register and what it may hold.

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

private func fullGapWatches(looks: Int = 1) -> [GapWatch] {
    GapSite.allCases.map {
        GapWatch(site: $0, looks: looks, watchedSpanNanos: 1_000_000_000,
                 gapsFound: 0, lost: 0)
    }
}
private func anchor(_ epoch: BootEpoch = epochA) -> EpochAnchor {
    EpochAnchor(epoch: epoch, hostTime: Nanoseconds(5_000), wallClockUnixNanos: 1_785_000_000_000_000_000)
}

// MARK: - the log's clock

@Test func everyRecordTypeAnswersWithTheEpochOfItsOwnInstant() {
    let pointer = PointerSample(instant: at(1), position: NormalizedPoint(x: 0.5, y: 0.5), revision: rev)
    let button = ButtonEvent(instant: at(2), position: NormalizedPoint(x: 0.5, y: 0.5),
                             revision: rev, button: .right, phase: .down)
    let key = KeySample(instant: at(3), shortcut: "cmd-s")
    let secure = SecureInputInterval(interval: span(4, 10), endedBy: .secureInputDisabled)
    let tap = TapDisabledInterval(interval: span(5, 10), disabledBy: nil,
                                  lowerBoundFrom: .lastEnabledPoll, detectedBy: .enabledPoll)
    let crop = ContentCropSample(instant: at(6), content: .whole, contentScale: 1)

    #expect(crop.epochs == [epochA])
    #expect(pointer.epochs == [epochA])
    #expect(button.epochs == [epochA])
    #expect(key.epochs == [epochA])
    #expect(secure.epochs == [epochA])
    #expect(tap.epochs == [epochA])
    // A type answering with nothing would make `checkEpoch` vacuous for itself.
    for record: any ObservationRecord in [pointer, button, key, secure, tap, crop] {
        #expect(!record.epochs.isEmpty, "\(record.kind) answered `epochs` with nothing")
    }
}

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

/// One element read is off the log's clock: a guard checking only the primary instant misses it.
@Test func checkEpochRefusesAChainWhoseElementWasReadInAnotherEpoch() {
    let straddling = chain(instant: at(100), hitTest: span(100, 50),
                           ancestorRead: span(200, 10, epochB))
    #expect(throws: ObservationLogError.foreignEpoch(kind: "axChain",
                                                     expected: epochA.id, found: epochB.id)) {
        try ObservationLog.checkEpoch(of: straddling, against: epochA)
    }
}

/// No shipped record type lacks an instant; this keeps `noEpoch` from being dead text.
private struct RecordWithNoInstant: ObservationRecord {
    // `var`, because an immutable property with an initial value is never decoded into — the
    // compiler warns, and a fixture that cannot round-trip is a fixture that proves nothing.
    var kind = "noInstant"
    var epochs: [BootEpoch] { [] }
}

@Test func checkEpochRefusesARecordThatCarriesNoInstantAtAll() {
    #expect(throws: ObservationLogError.noEpoch(kind: "noInstant")) {
        try ObservationLog.checkEpoch(of: RecordWithNoInstant(), against: epochA)
    }
}

// MARK: - zero versus never-measured

/// The four cases are the gap rows a producer can fill at segment close.
@Test func gapSiteCoversEveryD6aRowAProducerCanMeasure() {
    #expect(GapSite.allCases.count == 4,
            "a new D6a row that a PRODUCER can measure at segment close needs a case here and a GapWatch in every trailer")
    #expect(Set(GapSite.allCases.map(\.rawValue))
            == ["axAncestorWalk", "videoFramesNotProduced", "secureInput", "tapDisabled"])
}

/// The unit is fixed by the site, so one site cannot be reported in two units.
@Test func everyGapSiteFixesTheUnitItsLossIsMeasuredIn() {
    #expect(GapSite.axAncestorWalk.lostUnit == .levels)
    #expect(GapSite.videoFramesNotProduced.lostUnit == .frames)
    #expect(GapSite.secureInput.lostUnit == .nanoseconds)
    #expect(GapSite.tapDisabled.lostUnit == .nanoseconds)
    for site in GapSite.allCases {
        let watch = GapWatch(site: site, looks: 1, watchedSpanNanos: 1, gapsFound: 0, lost: 0)
        #expect(watch.lostUnit == site.lostUnit,
                "GapWatch derived a unit its site does not name")
    }
}

@Test func aGapWatchWhoseUnitDisagreesWithItsSiteFailsToDecode() {
    let mismatched = Data("""
        {"site":"videoFramesNotProduced","looks":10,"watchedSpanNanos":1000,\
        "gapsFound":0,"lost":0,"lostUnit":"nanoseconds"}
        """.utf8)
    #expect(throws: (any Error).self) {
        let _: GapWatch = try ObservationLog.decode(mismatched)
    }
    // The control: same bytes with the site's own unit must decode.
    let matched = Data("""
        {"site":"videoFramesNotProduced","looks":10,"watchedSpanNanos":1000,\
        "gapsFound":0,"lost":0,"lostUnit":"frames"}
        """.utf8)
    #expect(throws: Never.self) { let _: GapWatch = try ObservationLog.decode(matched) }
}

@Test func theNamedGapWatchConstructorsCarryTheirProducersOwnNumbers() {
    let tap = GapWatch.tapDisabled(tapEnabledPolls: 1247, tapPollingSpanNanos: 124_700_000_000,
                                   tapDisabledIntervals: 0, tapBlindNanos: 0)
    #expect(tap.site == .tapDisabled)
    #expect(tap.looks == 1247)
    #expect(tap.isAMeasurement)

    let secure = GapWatch.secureInput(secureInputChecks: 0, secureInputCheckSpanNanos: 0,
                                      secureInputIntervals: 0, suppressedNanos: 0)
    #expect(!secure.isAMeasurement,
            "a run in which nothing consulted the predicate is a row that says so")

    let video = GapWatch.videoFramesNotProduced(frameCallbacksObserved: 664,
                                                observationSpanNanos: 20_000_000_000,
                                                idleFrames: 402)
    #expect(video.lostUnit == .frames)
    #expect(video.gapsFound == 402)

    let ax = GapWatch.axAncestorWalk(chainsRecorded: 8, observationSpanNanos: 20_000_000_000,
                                     truncatedWalks: 8)
    #expect(ax.lostUnit == .levels)
    #expect(ax.looks == 8)
}

@Test func aGapWatchWithNoLooksIsNotAMeasurement() {
    let nothingLooked = GapWatch(site: .tapDisabled, looks: 0, watchedSpanNanos: 0,
                                 gapsFound: 0, lost: 0)
    let somethingLooked = GapWatch(site: .tapDisabled, looks: 1247, watchedSpanNanos: 124_700_000_000,
                                   gapsFound: 0, lost: 0)
    #expect(!nothingLooked.isAMeasurement)
    #expect(somethingLooked.isAMeasurement)
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
    let watch = GapWatch(site: .axAncestorWalk, looks: 1, watchedSpanNanos: 5_000,
                         gapsFound: 1, lost: 1)
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

/// An absent row would read as "no gaps at that site". Built as bytes because
/// the memberwise initialiser `precondition`s on the complete set.
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
                            gapsFound: 0, lost: 0))
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
                            gapsFound: 0, lost: 0))
    let trailer = ObservationLogTrailer(segmentIndex: 0, hostRange: span(0, 1),
                                        endedBy: .stopped, recordCounts: [:],
                                        gapWatches: watches)
    #expect(trailer.sitesNothingWasWatching == [.secureInput])
    #expect(trailer.accounting.contains("NOTHING WAS LOOKING"))
}

/// `"key": 0` and an absent `"key"` are different facts.
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
    let header = ObservationLogHeader(anchor: anchor(), segmentIndex: 3,
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

/// Without this, a blind segment is byte-identical to an idle mouse.
@Test func aHeaderCarriesWhyAWholeSegmentSawNothing() throws {
    let blind = ObservationLogHeader(anchor: anchor(), segmentIndex: 0,
                                     mediaFilename: "master-00.mov", revision: rev,
                                     blindness: [.inputMonitoringUnavailable])
    let sighted = ObservationLogHeader(anchor: anchor(), segmentIndex: 0,
                                       mediaFilename: "master-00.mov", revision: rev,
                                       blindness: [])
    #expect(blind != sighted, "a blind segment and a clear one encode identically")
    let back: ObservationLogHeader = try ObservationLog.decode(try ObservationLog.encode(blind))
    #expect(back.blindness == [.inputMonitoringUnavailable])
}

/// An absent `blindness` key is a build that did not look, not "nothing was blind".
@Test func aHeaderWithNoBlindnessKeyFailsToDecode() throws {
    let json = """
        {"kind":"logHeader","schemaVersion":1,\
        "anchor":\(String(decoding: try ObservationLog.encode(anchor()), as: UTF8.self)),\
        "segmentIndex":0,"mediaFilename":"master-00.mov",\
        "revision":\(String(decoding: try ObservationLog.encode(rev), as: UTF8.self))}
        """
    #expect(throws: (any Error).self) {
        let _: ObservationLogHeader = try ObservationLog.decode(Data(json.utf8))
    }
}

// MARK: - the JSONL reader

/// `droppedBytes == 0` means both "clean file" and "no file"; this separates them.
@Test func theJSONLReaderReportsHowManyBytesItExamined() {
    let clean = JSONLReader.lines(from: Data("a\nbb\nccc\n".utf8))
    #expect(clean.droppedBytes == 0)
    #expect(clean.bytesScanned == 9)

    let nothing = JSONLReader.lines(from: Data())
    #expect(nothing.droppedBytes == 0)
    #expect(nothing.bytesScanned == 0)

    // Identical `droppedBytes`: without `bytesScanned` they are one measurement.
    #expect(clean.droppedBytes == nothing.droppedBytes)
    #expect(clean.bytesScanned != nothing.bytesScanned)
    #expect(nothing.accounting.contains("NOTHING WAS READ"))
    #expect(!clean.accounting.contains("NOTHING WAS READ"))
}

@Test func bytesScannedCountsTheDroppedTailToo() {
    let r = JSONLReader.lines(from: Data("a\nb\n{\"partial\":".utf8))
    #expect(r.droppedBytes == 11)
    #expect(r.bytesScanned == 15)
}

// MARK: - the header's version line

/// A future build's header must be refused, not read as this version.
@Test func aHeaderFromAFutureBuildIsRefusedRatherThanReadAsThisOne() throws {
    func headerJSON(schemaVersion: Int, kind: String = "logHeader") throws -> Data {
        Data("""
            {"kind":"\(kind)","schemaVersion":\(schemaVersion),\
            "anchor":\(String(decoding: try ObservationLog.encode(anchor()), as: UTF8.self)),\
            "segmentIndex":0,"mediaFilename":"master-00.mov",\
            "revision":\(String(decoding: try ObservationLog.encode(rev), as: UTF8.self)),\
            "blindness":[]}
            """.utf8)
    }
    // The control: without it, a decoder that refuses everything passes.
    #expect(throws: Never.self) {
        let _: ObservationLogHeader = try ObservationLog.decode(
            try headerJSON(schemaVersion: ObservationLog.schemaVersion))
    }
    // The specific case, both directions: `(any Error).self` also passed when
    // `tooNew` was thrown for a version BELOW this build's.
    #expect(throws: ProjectFormatError.tooNew(found: 9,
                                              supported: ObservationLog.schemaVersion)) {
        let _: ObservationLogHeader = try ObservationLog.decode(try headerJSON(schemaVersion: 9))
    }
    #expect(throws: ProjectFormatError.unsupportedLegacyVersion(0)) {
        let _: ObservationLogHeader = try ObservationLog.decode(try headerJSON(schemaVersion: 0))
    }
    // The real v1 log wrote `"epoch"` for `"anchor"`: it must fail by name at
    // the version line, not deeper on `keyNotFound`.
    let realV1Header = Data("""
        {"kind":"logHeader","schemaVersion":1,\
        "epoch":\(String(decoding: try ObservationLog.encode(epochA), as: UTF8.self)),\
        "segmentIndex":0,"mediaFilename":"master-00.mov",\
        "revision":\(String(decoding: try ObservationLog.encode(rev), as: UTF8.self)),\
        "blindness":[]}
        """.utf8)
    #expect(throws: ProjectFormatError.unsupportedLegacyVersion(1)) {
        let _: ObservationLogHeader = try ObservationLog.decode(realV1Header)
    }
    #expect(throws: (any Error).self) {
        let _: ObservationLogHeader = try ObservationLog.decode(
            try headerJSON(schemaVersion: 1, kind: "logTrailer"))
    }
}

/// The anchor is the only place a package says when it was recorded.
@Test func aHeaderDatesItsRecording() throws {
    let header = ObservationLogHeader(anchor: anchor(), segmentIndex: 0,
                                      mediaFilename: "master-00.mov", revision: rev,
                                      blindness: [])
    let back: ObservationLogHeader = try ObservationLog.decode(try ObservationLog.encode(header))
    #expect(back.anchor.wallClockUnixNanos == 1_785_000_000_000_000_000)
    #expect(back.anchor.hostTime == Nanoseconds(5_000))
    // The log's clock is the anchor's epoch, not a second field that could disagree.
    #expect(back.epoch == back.anchor.epoch)
    #expect(back.epoch == epochA)
}

// MARK: - the read-side gap row

@Test func theReadReportCarriesD6aRowOneAndTheTrailerCarriesTheOtherFour() throws {
    let trailer = ObservationLogTrailer(segmentIndex: 0, hostRange: span(0, 1),
                                        endedBy: .stopped, recordCounts: ["pointer": 3],
                                        gapWatches: fullGapWatches())
    let clean = ObservationLogReadReport(header: nil, trailer: trailer, recordLines: 3,
                                         trailerCount: 1, trailerIsLastCompleteLine: true,
                                         droppedBytes: 0, bytesScanned: 512)
    #expect(clean.producerGapWatches.count == GapSite.allCases.count)
    #expect(clean.isAMeasurement)
    #expect(clean.closedCleanly)
    #expect(clean.closeFault == nil)
    #expect(!clean.truncatedTailAccounting.contains("NOTHING WAS READ"))

    // `trailer != nil` is not "closed cleanly" — these two states are why.
    let closedTwice = ObservationLogReadReport(header: nil, trailer: trailer, recordLines: 3,
                                               trailerCount: 2, trailerIsLastCompleteLine: true,
                                               droppedBytes: 0, bytesScanned: 512)
    #expect(closedTwice.trailer != nil)
    #expect(!closedTwice.closedCleanly)
    #expect(closedTwice.closeFault?.contains("closed more than once") == true)

    let grewAfterClosing = ObservationLogReadReport(header: nil, trailer: trailer, recordLines: 3,
                                                    trailerCount: 1,
                                                    trailerIsLastCompleteLine: false,
                                                    droppedBytes: 0, bytesScanned: 512)
    #expect(grewAfterClosing.trailer != nil)
    #expect(!grewAfterClosing.closedCleanly)
    #expect(grewAfterClosing.closeFault?.contains("not the last line") == true)

    let nothing = ObservationLogReadReport(header: nil, trailer: nil, recordLines: 0,
                                           trailerCount: 0, trailerIsLastCompleteLine: false,
                                           droppedBytes: 0, bytesScanned: 0)
    #expect(clean.droppedBytes == nothing.droppedBytes)
    #expect(!nothing.isAMeasurement)
    #expect(nothing.truncatedTailAccounting.contains("NOTHING WAS READ"))
    #expect(!nothing.closedCleanly)
    #expect(nothing.accounting.contains("NO TRAILER"))
}

@Test func aProducerCannotClaimTheReadSideRow() {
    #expect(!GapSite.allCases.map(\.rawValue).contains("jsonlTruncatedTail"),
            "a producer with no reader could write a `looks` for this site that means nothing")
}

// MARK: - one foreign epoch per epoch-bearing field

/// The compiler does not enforce that a new epoch-bearing field reaches `epochs`; one case per field does.
@Test func everyEpochBearingFieldOfEveryRecordTypeIsRefusedWhenItIsForeign() {
    func refuses(_ record: some ObservationRecord, _ what: String) {
        #expect(throws: (any Error).self,
                "\(record.kind): a foreign epoch in \(what) was accepted") {
            try ObservationLog.checkEpoch(of: record, against: epochA)
        }
    }
    let p = NormalizedPoint(x: 0.5, y: 0.5)

    refuses(PointerSample(instant: at(1, epochB), position: p, revision: rev), "instant")
    refuses(ButtonEvent(instant: at(1, epochB), position: p, revision: rev,
                        button: .left, phase: .down), "instant")
    refuses(KeySample(instant: at(1, epochB), shortcut: "cmd-s"), "instant")
    refuses(SecureInputInterval(interval: span(1, 2, epochB), endedBy: .observationStopped),
            "interval")
    refuses(TapDisabledInterval(interval: span(1, 2, epochB), disabledBy: nil,
                                lowerBoundFrom: .observationStart, detectedBy: .enabledPoll),
            "interval")

    // Each of `AXChainRecord`'s five epochs is moved on its own.
    refuses(chain(instant: at(1, epochB), hitTest: span(1, 1)), "instant")
    refuses(chain(instant: at(1), hitTest: span(1, 1, epochB)), "hitTestInterval")
    refuses(AXChainRecord(instant: at(1), clickPosition: p, clickRevision: rev,
                          hitTestGlobalX: 1, hitTestGlobalY: 1, hitTestInterval: span(1, 1),
                          hit: element(readAt: span(2, 1, epochB)), ancestors: [], children: nil,
                          truncation: .reachedRoot, axCalls: 1, depthCap: 30,
                          walkBudgetNanos: 1), "hit.readInterval")
    refuses(AXChainRecord(instant: at(1), clickPosition: p, clickRevision: rev,
                          hitTestGlobalX: 1, hitTestGlobalY: 1, hitTestInterval: span(1, 1),
                          hit: element(readAt: span(2, 1)),
                          ancestors: [element(readAt: span(3, 1, epochB))], children: nil,
                          truncation: .reachedRoot, axCalls: 1, depthCap: 30,
                          walkBudgetNanos: 1), "ancestors[0].readInterval")
    refuses(AXChainRecord(instant: at(1), clickPosition: p, clickRevision: rev,
                          hitTestGlobalX: 1, hitTestGlobalY: 1, hitTestInterval: span(1, 1),
                          hit: element(readAt: span(2, 1)), ancestors: [],
                          children: [element(readAt: span(3, 1, epochB))],
                          truncation: .reachedRoot, axCalls: 1, depthCap: 30,
                          walkBudgetNanos: 1), "children[0].readInterval")

    // The control: without it, a guard that refuses everything passes.
    #expect(throws: Never.self) {
        try ObservationLog.checkEpoch(
            of: AXChainRecord(instant: at(1), clickPosition: p, clickRevision: rev,
                              hitTestGlobalX: 1, hitTestGlobalY: 1, hitTestInterval: span(1, 1),
                              hit: element(readAt: span(2, 1)),
                              ancestors: [element(readAt: span(3, 1))],
                              children: [element(readAt: span(4, 1))],
                              truncation: .reachedRoot, axCalls: 1, depthCap: 30,
                              walkBudgetNanos: 1),
            against: epochA)
    }
}

// MARK: - the join field, dangling

/// A log whose media never arrived, or was compacted away, names a missing file.
@Test func aLogNamingMediaTheManifestDoesNotReferenceIsReported() throws {
    let fm = FileManager.default
    let packageURL = fm.temporaryDirectory
        .appending(path: "t11-dangle-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
    defer { try? fm.removeItem(at: packageURL) }
    try ProjectPackageIO.save(
        ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                        geometries: GeometryRegistry(), mediaFilenames: []),
        to: packageURL)

    let observations = packageURL.appending(path: "observations", directoryHint: .isDirectory)
    func writeLog(named name: String, mediaFilename: String) throws {
        var data = try ObservationLog.encode(
            ObservationLogHeader(anchor: anchor(), segmentIndex: 0, mediaFilename: mediaFilename,
                                 revision: rev, blindness: []))
        data.append(UInt8(ascii: "\n"))
        try data.write(to: observations.appending(path: name, directoryHint: .notDirectory))
    }
    try writeLog(named: "segment-00.jsonl", mediaFilename: "master-00.mov")
    try writeLog(named: "segment-01.jsonl", mediaFilename: "master-01.mov")
    // A log with no header cannot state its media either — same failure.
    try Data("not json\n".utf8)
        .write(to: observations.appending(path: "segment-02.jsonl", directoryHint: .notDirectory))

    let partial = ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                                  geometries: GeometryRegistry(),
                                  mediaFilenames: ["master-00.mov"])
    #expect(try ProjectPackageIO.danglingObservationLogs(in: packageURL, snapshot: partial)
            == ["segment-01.jsonl", "segment-02.jsonl"])

    let complete = ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                                   geometries: GeometryRegistry(),
                                   mediaFilenames: ["master-00.mov", "master-01.mov"])
    #expect(try ProjectPackageIO.danglingObservationLogs(in: packageURL, snapshot: complete)
            == ["segment-02.jsonl"])

    // Reported, never deleted: `compact` removes only what `unreferencedSidecars` names.
    _ = try ProjectPackageIO.compact(packageURL, snapshot: partial)
    #expect(fm.fileExists(atPath: observations.appending(path: "segment-01.jsonl").path))
}

// MARK: - the join field, looked up

/// The log for a media file is the one whose header names it — not the one whose filename
/// looks like it should. Here the log for `master-00.mov` is called `segment-07.jsonl` and a
/// `segment-00.jsonl` beside it names another file.
@Test func theLogForAMediaFileIsTheOneWhoseHeaderNamesIt() throws {
    let fm = FileManager.default
    let packageURL = fm.temporaryDirectory
        .appending(path: "t11-join-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
    defer { try? fm.removeItem(at: packageURL) }
    try ProjectPackageIO.save(
        ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                        geometries: GeometryRegistry(), mediaFilenames: ["master-00.mov"]),
        to: packageURL)
    let observations = packageURL.appending(path: "observations", directoryHint: .isDirectory)
    try fm.createDirectory(at: observations, withIntermediateDirectories: true)
    func writeLog(named name: String, mediaFilename: String) throws {
        var data = try ObservationLog.encode(
            ObservationLogHeader(anchor: anchor(), segmentIndex: 0, mediaFilename: mediaFilename,
                                 revision: rev, blindness: []))
        data.append(UInt8(ascii: "\n"))
        try data.write(to: observations.appending(path: name, directoryHint: .notDirectory))
    }
    #expect(try ProjectPackageIO.observationLog(forMedia: "master-00.mov", in: packageURL) == nil,
            "no log names it yet")

    try writeLog(named: "segment-00.jsonl", mediaFilename: "master-01.mov")
    try writeLog(named: "segment-07.jsonl", mediaFilename: "master-00.mov")
    #expect(try ProjectPackageIO.observationLog(forMedia: "master-00.mov", in: packageURL)?.lastPathComponent
            == "segment-07.jsonl")

    // A link that names it is not followed, so it is neither found nor counted.
    try fm.createSymbolicLink(at: observations.appending(path: "segment-08.jsonl"),
                              withDestinationURL: observations.appending(path: "segment-07.jsonl"))
    #expect(try ProjectPackageIO.observationLog(forMedia: "master-00.mov", in: packageURL)?.lastPathComponent
            == "segment-07.jsonl")

    try writeLog(named: "segment-09.jsonl", mediaFilename: "master-00.mov")
    #expect(throws: ProjectFormatError.severalLogsNameOneMedia("master-00.mov",
                                                              ["segment-07.jsonl", "segment-09.jsonl"])) {
        try ProjectPackageIO.observationLog(forMedia: "master-00.mov", in: packageURL)
    }
}

// MARK: - the pointer shape, added after two hundred thousand shape-less samples

/// Every schema-2 pointer line ever written — the committed row-14 fixture included —
/// carries no `shape` key, and every one of them must go on decoding. This is the
/// backwards-compatibility half of the design choice recorded on the field: absence is
/// honest history ("unrecorded"), not the ambiguity `CursorOverride.epoch` refused.
@Test func aShapelessPointerLineStillDecodesAndSaysUnrecorded() throws {
    let schema2Line = Data("""
    {"kind":"pointer","instant":{"epoch":{"id":"6495B81D-14D1-4E05-8851-DD30BE41D757"},\
    "hostTime":{"rawValue":1000}},"position":{"x":0.25,"y":0.75},"revision":{"id":1}}
    """.utf8)
    let decoded = try JSONDecoder().decode(PointerSample.self, from: schema2Line)
    #expect(decoded.shape == nil)
    #expect(decoded.position == NormalizedPoint(x: 0.25, y: 0.75))
}

/// A recorded shape survives the round trip, and `.other` survives as itself rather than
/// collapsing to `nil` — the two are different facts and the wire must keep them apart.
@Test func aRecordedShapeRoundTripsAndOtherStaysOther() throws {
    let rev = GeometryRevision(id: 1)
    for shape in [PointerShape.iBeam, .pointingHand, .other] {
        let sample = PointerSample(instant: at(1), position: NormalizedPoint(x: 0.5, y: 0.5),
                                   revision: rev, shape: shape)
        let back = try JSONDecoder().decode(PointerSample.self, from: JSONEncoder().encode(sample))
        #expect(back.shape == shape)
    }
}
