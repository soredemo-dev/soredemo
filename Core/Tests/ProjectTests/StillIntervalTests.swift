import Foundation
import Testing
import Timeline
@testable import Project

private let epoch = BootEpoch(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

private func interval(startNanos: Int64, durationNanos: Int64) -> HostRange {
    HostRange(epoch: epoch, start: Nanoseconds(startNanos), duration: Nanoseconds(durationNanos))
}

/// The floor is a decision, and the reason is that neither signal can resolve
/// anything shorter: `StillnessReader` measures the picture in slices of exactly
/// this length.
@Test func theShortestRecordedStretchMatchesTheSliceThePictureIsMeasuredIn() {
    #expect(StillInterval.shortestWorthRecording == Nanoseconds(250_000_000))
}

@Test func aStillIntervalKeepsWhatItWasBuiltWith() {
    let record = StillInterval(interval: interval(startNanos: 1_000, durationNanos: 2_000_000_000),
                               endedBy: .thePictureChanged, idleFrames: 120)
    #expect(record.kind == "still")
    #expect(record.idleFrames == 120)
    #expect(record.endedBy == .thePictureChanged)
    #expect(record.epochs == [epoch])
}

/// Rule 8. The synthesised decode would accept both of these, and each would
/// then travel as if a producer had vouched for it.
@Test func decodingRefusesWhatTheInitialiserWouldTrapOn() throws {
    let good = StillInterval(interval: interval(startNanos: 0, durationNanos: 1_000_000_000),
                             endedBy: .theSegmentEnded, idleFrames: 60)
    let encoded = try JSONEncoder().encode(good)
    #expect(try JSONDecoder().decode(StillInterval.self, from: encoded) == good)

    func mutated(_ key: String, _ value: Any) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(StillInterval.self, from: try mutated("idleFrames", 0))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(StillInterval.self, from: try mutated("idleFrames", -1))
    }
    // A record wearing another record's discriminator would be routed by `kind`
    // and decoded as this type anyway; refusing here is what stops that.
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(StillInterval.self, from: try mutated("kind", "pointer"))
    }
}

/// The two ends are not interchangeable: one is a measurement, the other a lower
/// bound, and a consumer that cut to the second as if it were the first would cut
/// into footage the recording never said was still.
@Test func theTwoEndingsSurviveTheRoundTripAndDoNotCompareEqual() throws {
    let changed = StillInterval(interval: interval(startNanos: 0, durationNanos: 3_000_000_000),
                                endedBy: .thePictureChanged, idleFrames: 180)
    let ended = StillInterval(interval: interval(startNanos: 0, durationNanos: 3_000_000_000),
                              endedBy: .theSegmentEnded, idleFrames: 180)
    #expect(changed != ended)
    let coded = try JSONDecoder().decode([StillInterval].self,
                                         from: try JSONEncoder().encode([changed, ended]))
    #expect(coded == [changed, ended])
}

/// `idleFrames` exists to separate a still picture from a stalled stream, so the
/// two must be distinguishable from the record alone. Three seconds spanned by
/// two callbacks is not stillness; the record carries what is needed to say so.
@Test func aStalledStreamIsDistinguishableFromAStillPicture() {
    let still = StillInterval(interval: interval(startNanos: 0, durationNanos: 3_000_000_000),
                              endedBy: .thePictureChanged, idleFrames: 180)
    let stalled = StillInterval(interval: interval(startNanos: 0, durationNanos: 3_000_000_000),
                                endedBy: .thePictureChanged, idleFrames: 2)
    let seconds = 3.0
    #expect(Double(still.idleFrames) / seconds > 30)
    #expect(Double(stalled.idleFrames) / seconds < 1)
}
