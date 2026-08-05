import Testing
import Foundation
import Geometry
import Timeline
@testable import Project

private let ep = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)
private let rev = GeometryRevision(id: 0xbcf4_9ed7_dcb4_2be0)
private func at(_ ns: Int64) -> HostInstant { HostInstant(epoch: ep, hostTime: Nanoseconds(ns)) }

/// Top-level object keys of raw JSON, in document order: a quoted string at
/// depth 1 followed by `:` (the `:` filters out top-level string *values*).
/// Byte order in the text, which a key-order-insensitive decode cannot see.
private func topLevelKeys(from json: Data) -> [String] {
    let bytes = [UInt8](json)
    var keys: [String] = []
    var depth = 0
    var idx = 0
    let quote = UInt8(ascii: "\"")
    let backslash = UInt8(ascii: "\\")
    let colon = UInt8(ascii: ":")
    let openers: Set<UInt8> = [UInt8(ascii: "{"), UInt8(ascii: "[")]
    let closers: Set<UInt8> = [UInt8(ascii: "}"), UInt8(ascii: "]")]

    while idx < bytes.count {
        let b = bytes[idx]
        if b == quote {
            let atDepth = depth
            var content: [UInt8] = []
            idx += 1
            while idx < bytes.count, bytes[idx] != quote {
                if bytes[idx] == backslash, idx + 1 < bytes.count {
                    content.append(bytes[idx]); idx += 1
                }
                content.append(bytes[idx])
                idx += 1
            }
            idx += 1 // closing quote
            if atDepth == 1, idx < bytes.count, bytes[idx] == colon {
                keys.append(String(decoding: content, as: UTF8.self))
            }
        } else if openers.contains(b) {
            depth += 1
            idx += 1
        } else if closers.contains(b) {
            depth -= 1
            idx += 1
        } else {
            idx += 1
        }
    }
    return keys
}

@Test func aPointerSampleRoundTripsThroughOneJSONLLine() throws {
    let s = PointerSample(instant: at(1_000), position: NormalizedPoint(x: 0.25, y: 0.75), revision: rev)
    let line = try ObservationLog.encode(s)
    #expect(!line.contains(UInt8(ascii: "\n")), "a record must occupy exactly one JSONL line")
    let back: PointerSample = try ObservationLog.decode(line)
    #expect(back == s)
}

/// The reason kind() exists: a v1 build meets a record type it does not know.
@Test func kindIsReadableWithoutDecodingTheRecord() throws {
    let future = Data(#"{"kind":"somethingFromAFutureBuild","instant":{},"extra":42}"#.utf8)
    #expect(try ObservationLog.kind(of: future) == "somethingFromAFutureBuild")
}

@Test func decodingAsTheWrongTypeThrowsRatherThanReturningAnEmptyValue() throws {
    let s = PointerSample(instant: at(1), position: NormalizedPoint(x: 0, y: 0), revision: rev)
    let line = try ObservationLog.encode(s)
    #expect(throws: (any Error).self) { let _: KeySample = try ObservationLog.decode(line) }
}

/// A click at (0,0) with button 0 is every field's identity, so the fixture
/// carries a non-identity value for each.
@Test func aButtonEventCarriesItsButtonAndPhase() throws {
    let e = ButtonEvent(instant: at(2_000), position: NormalizedPoint(x: 0.4, y: 0.6),
                        revision: rev, button: .right, phase: .up)
    let back: ButtonEvent = try ObservationLog.decode(try ObservationLog.encode(e))
    #expect(back.button == .right)
    #expect(back.phase == .up)
    #expect(back.position.x == 0.4)
}

@Test func theLogsSchemaVersionIsItsOwnNumber() {
    #expect(ObservationLog.schemaVersion == 2)
    #expect(ProjectSnapshot.currentSchemaVersion == 1)
    // Two separate literals: pinning values cannot detect one being derived
    // from the other. They differ because the log's wire format changed twice
    // and the document manifest's did not.
    #expect(ObservationLog.schemaVersion != ProjectSnapshot.currentSchemaVersion,
            "the two version lines have diverged, which is what having two is for")
}

/// 23 is the exact byte count of the truncated tail `{"kind":"pointer","inst`
/// with no trailing newline.
@Test func recordsSurviveJSONLReaderIncludingATruncatedTail() throws {
    var data = Data()
    for i in 0..<3 {
        data.append(try ObservationLog.encode(
            PointerSample(instant: at(Int64(i)), position: NormalizedPoint(x: 0.1, y: 0.2), revision: rev)))
        data.append(UInt8(ascii: "\n"))
    }
    data.append(Data(#"{"kind":"pointer","inst"#.utf8))   // a crash mid-write
    let r = JSONLReader.lines(from: data)
    #expect(r.lines.count == 3)
    #expect(r.droppedBytes == 23)
}

/// The deterministic half of catching a dropped `.sortedKeys`: the flag on the
/// real code path, red every run regardless of hash seed. Pinned to the EXACT
/// set — `.contains(.sortedKeys)` stays green if `.prettyPrinted` is added,
/// and pretty-printed output breaks substring scans over the log.
@Test func sortedKeysIsSetOnTheEncoder() {
    #expect(ObservationLog.outputFormatting == [.sortedKeys])
}

/// The byte-order half: `decode` matches keys by name, so only the raw bytes
/// can see order. Probabilistic — `PointerSample`'s 4 keys give 24 orderings,
/// so a dropped `.sortedKeys` passes ~1 run in 24 — but it catches encoders
/// built without `ObservationLog.outputFormatting`, which the flag test cannot.
@Test func encodedKeysAreInSortedOrderNotJustRoundTrippable() throws {
    let s = PointerSample(instant: at(1), position: NormalizedPoint(x: 0.1, y: 0.2), revision: rev)
    let keys = topLevelKeys(from: try ObservationLog.encode(s))
    let expectedKeys = ["instant", "kind", "position", "revision"]
    #expect(expectedKeys == expectedKeys.sorted(), "fixture sanity: the expected literal must itself be sorted")
    #expect(keys == expectedKeys)
}

// MARK: - secure input

/// An interval with no samples must be stated, not inferred from a gap, and
/// `kind` must be a distinct value a reader can dispatch on.
@Test func aSecureInputIntervalRoundTripsAndCarriesItsOwnKind() throws {
    let record = SecureInputInterval(
        interval: HostRange(epoch: ep, start: Nanoseconds(1_000), duration: Nanoseconds(4_000)),
        endedBy: .secureInputDisabled)
    let line = try ObservationLog.encode(record)
    #expect(try ObservationLog.kind(of: line) == "secureInput")
    let back: SecureInputInterval = try ObservationLog.decode(line)
    #expect(back == record)
    #expect(back.interval.end == Nanoseconds(5_000))
}

/// `.observationStopped` means the end instant is when observing stopped, not
/// when secure input did — a lower bound, not a measurement. Without the
/// discriminator the two are indistinguishable on disk.
@Test func theTwoWaysASecureInputIntervalCanEndAreDistinguishableOnDisk() throws {
    let range = HostRange(epoch: ep, start: Nanoseconds(7), duration: Nanoseconds(11))
    let measured = SecureInputInterval(interval: range, endedBy: .secureInputDisabled)
    let bounded = SecureInputInterval(interval: range, endedBy: .observationStopped)
    #expect(measured != bounded, "same interval, different reason — the records must not compare equal")
    let measuredLine = try ObservationLog.encode(measured)
    let boundedLine = try ObservationLog.encode(bounded)
    #expect(measuredLine != boundedLine)
    #expect(try ObservationLog.decode(measuredLine) as SecureInputInterval == measured)
    #expect(try ObservationLog.decode(boundedLine) as SecureInputInterval == bounded)
}

/// A disabled tap is a span of unobserved time; the count it replaced made
/// 400 ms and 4 ms of lost pointer track the same number.
@Test func aTapDisabledIntervalRoundTripsAndCarriesItsOwnKind() throws {
    let record = TapDisabledInterval(
        interval: HostRange(epoch: ep, start: Nanoseconds(1_000), duration: Nanoseconds(9_000)),
        disabledBy: .timeout, lowerBoundFrom: .lastObservedEvent, detectedBy: .notification)
    let line = try ObservationLog.encode(record)
    #expect(try ObservationLog.kind(of: line) == "tapDisabled")
    let back: TapDisabledInterval = try ObservationLog.decode(line)
    #expect(back == record)
    #expect(back.interval.end == Nanoseconds(10_000),
            "the width is the point: a consumer asks whether a beat spans this range")
}

/// `disabledBy` says whose fault the window was; `lowerBoundFrom` says how far
/// the left edge can be trusted (a real event is within a frame or two, the
/// start of observation is as wide as the run). Collapsing either pair would
/// put two different facts in one field.
@Test func aBlindWindowsCauseAndItsTrustworthinessAreBothOnDisk() throws {
    let range = HostRange(epoch: ep, start: Nanoseconds(7), duration: Nanoseconds(11))
    var lines: Set<Data> = []
    let reasons: [TapDisableReason?] = [.timeout, .userInput, nil]
    for reason in reasons {
        for bound in [TapBlindWindowLowerBound.lastEnabledPoll, .lastObservedEvent, .observationStart] {
            for channel in [TapDisableDetection.notification, .enabledPoll] {
                let record = TapDisabledInterval(interval: range, disabledBy: reason,
                                                 lowerBoundFrom: bound, detectedBy: channel)
                let line = try ObservationLog.encode(record)
                lines.insert(line)
                #expect(try ObservationLog.decode(line) as TapDisabledInterval == record)
            }
        }
    }
    #expect(lines.count == 18, """
            the same interval with different causes, lower bounds and detection channels must not \
            collapse to fewer than 3 × 3 × 2 distinct records on disk
            """)
}

/// A polled window reports no reason, and `nil` must survive as `nil`: the
/// reason arrives only on a notification, which a `.listenOnly` tap never
/// gets. Defaulting to `.timeout` would mint an accusation from nothing.
@Test func aPolledBlindWindowReportsNoReasonRatherThanGuessingOne() throws {
    let record = TapDisabledInterval(
        interval: HostRange(epoch: ep, start: Nanoseconds(20), duration: Nanoseconds(100_000_000)),
        disabledBy: nil, lowerBoundFrom: .lastEnabledPoll, detectedBy: .enabledPoll)
    let line = try ObservationLog.encode(record)
    let text = String(decoding: line, as: UTF8.self)
    #expect(!text.contains("disabledBy"),
            "an unknown reason encodes as an absent key, not as a value: \(text)")

    let back: TapDisabledInterval = try ObservationLog.decode(line)
    #expect(back == record)
    #expect(back.disabledBy == nil, "and it decodes back to nothing, not to a default")
    #expect(back.detectedBy == .enabledPoll)
    #expect(back.lowerBoundFrom == .lastEnabledPoll)
}

/// A zero-width interval is legal — secure input can go on and off between two
/// pointer samples — and is still a record, not a reason to emit nothing.
@Test func aZeroWidthSecureInputIntervalIsStillARecord() throws {
    let record = SecureInputInterval(
        interval: HostRange(epoch: ep, start: Nanoseconds(42), duration: Nanoseconds(0)),
        endedBy: .secureInputDisabled)
    let line = try ObservationLog.encode(record)
    #expect(try ObservationLog.kind(of: line) == "secureInput")
    #expect(try ObservationLog.decode(line) as SecureInputInterval == record)
}

/// A `KeySample`'s one payload field is an identifier, not text: the shape
/// itself is the privacy claim, with nowhere to put a typed character.
@Test func aKeySampleHasNowhereToPutTypedText() throws {
    let sample = KeySample(instant: at(3), shortcut: "cmd+c")
    let keys = topLevelKeys(from: try ObservationLog.encode(sample))
    #expect(keys == ["instant", "kind", "shortcut"])
}
