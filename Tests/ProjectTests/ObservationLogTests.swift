import Testing
import Foundation
import Geometry
import Timeline
@testable import Project

private let ep = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)
private let rev = GeometryRevision(id: 0xbcf4_9ed7_dcb4_2be0)
private func at(_ ns: Int64) -> HostInstant { HostInstant(epoch: ep, hostTime: Nanoseconds(ns)) }

/// Pulls the top-level object keys out of raw JSON text, in document order,
/// by tracking brace/bracket depth and recording a quoted string at depth 1
/// only when it is immediately followed by `:` (a key, not a value — a
/// top-level string *value* like `"pointer"` also sits at depth 1, and is
/// filtered out by requiring the following character to be `:`).
///
/// Mirrors `RegistryTests.extractRevisionIDs`: an explicit contract about
/// byte order in the encoded text, not a round trip through decode (which is
/// key-order-insensitive and so cannot see this).
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

/// Fixture rule: a click at (0,0) with button 0 is the identity of every field
/// here, so the fixture carries a non-identity value for each.
@Test func aButtonEventCarriesItsButtonAndPhase() throws {
    let e = ButtonEvent(instant: at(2_000), position: NormalizedPoint(x: 0.4, y: 0.6),
                        revision: rev, button: .right, phase: .up)
    let back: ButtonEvent = try ObservationLog.decode(try ObservationLog.encode(e))
    #expect(back.button == .right)
    #expect(back.phase == .up)
    #expect(back.position.x == 0.4)
}

@Test func theLogsSchemaVersionIsItsOwnNumber() {
    #expect(ObservationLog.schemaVersion == 1)
    #expect(ProjectSnapshot.currentSchemaVersion == 1)
    // Pinned as two separate literals. This test cannot detect a coincidental
    // derivation of one from the other and its name does not claim to — see
    // the equivalent note in UpgradeTests.
}

/// `droppedBytes` here is 23, not a round number: it is the exact byte count
/// of `{"kind":"pointer","inst"` (no trailing newline), verified independently
/// with `wc -c` and Python's `len(s.encode())` before being pinned — not
/// hand-counted and trusted, per the project's history of wrong hand-counts.
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

/// Closes the gap the brief names for mutation 2 (dropping `.sortedKeys`):
/// a round trip through `decode` cannot see key order because
/// `JSONDecoder` matches keys by name, not position. This test inspects the
/// raw encoded bytes instead — the same move `RegistryTests
/// .encodingIsStableAcrossProcesses` makes for `GeometryRegistry`, and
/// `UpgradeTests.topLevelKeysEncodeInSortedOrder` already makes for
/// `ProjectSnapshot`: pin an explicit order contract in the text rather
/// than trust a round trip.
///
/// Verified this is the same shape, not just an analogous one, before
/// writing it: none of `PointerSample`/`ButtonEvent`/`KeySample` (nor
/// `HostInstant`, `NormalizedPoint`, `GeometryRevision` nested inside them)
/// contains a `Dictionary` or `Set` the way `GeometryRegistry` does, so it
/// would be easy to assume `JSONEncoder`'s keyed container falls back to a
/// fixed declaration order without one. It does not — a six-process probe
/// (`swift` invoked six times, encoding one flat struct with plain
/// `JSONEncoder`, no `.sortedKeys`) printed six different key orders here,
/// matching the measurement already recorded in
/// `ProjectSnapshot.makeEncoder()`'s doc comment ("five distinct byte
/// sequences across five processes... with no dictionary anywhere in it").
/// Foundation's `JSONEncoder` keyed container is not insertion-ordered on
/// Darwin regardless of the type's own shape, so `.sortedKeys` is load-
/// bearing for every `Codable` struct going through it, not only ones
/// wrapping a `Dictionary`.
@Test func encodedKeysAreInSortedOrderNotJustRoundTrippable() throws {
    let s = PointerSample(instant: at(1), position: NormalizedPoint(x: 0.1, y: 0.2), revision: rev)
    let keys = topLevelKeys(from: try ObservationLog.encode(s))
    #expect(keys == ["instant", "kind", "position", "revision"])
    #expect(keys == keys.sorted())
}
