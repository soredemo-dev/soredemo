import Foundation
import Geometry
import Testing
import Timeline
@testable import Project

private let epoch = BootEpoch(id: UUID(uuidString: "77777777-8888-9999-AAAA-BBBBBBBBBBBB")!)

private func at(_ nanos: Int64) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(nanos))
}

@Test func aContentCropSampleKeepsWhatItWasBuiltWith() {
    let window = CropRect(x: 0, y: 0, width: 1419.0 / 1600, height: 1)
    let record = ContentCropSample(instant: at(1_000), content: window, contentScale: 1.7733)
    #expect(record.kind == "contentCrop")
    #expect(record.content == window)
    #expect(record.contentScale == 1.7733)
    #expect(record.epochs == [epoch])
}

/// Rule 8. The synthesised decode would accept every one of these, and each would then travel
/// as if a producer had vouched for it.
@Test func decodingAContentCropRefusesWhatTheInitialiserWouldTrapOn() throws {
    let good = ContentCropSample(instant: at(0), content: .whole, contentScale: 1)
    let encoded = try JSONEncoder().encode(good)
    #expect(try JSONDecoder().decode(ContentCropSample.self, from: encoded) == good)

    // A scale of zero is not "no scaling applied"; it is a stream that said nothing usable,
    // and a reader dividing by it would produce an infinity nobody could trace back to here.
    for scale in ["0", "-1", "1e400"] {
        let line = Data("""
            {"kind":"contentCrop","instant":{"epoch":{"id":"\(epoch.id.uuidString)"},\
            "hostTime":{"rawValue":0}},\
            "content":{"x":0,"y":0,"width":1,"height":1},"contentScale":\(scale)}
            """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ContentCropSample.self, from: line)
        }
    }

    // And a line carrying somebody else's `kind`, which is how a mis-routed record becomes a
    // crop nobody asked for.
    let wrongKind = Data("""
        {"kind":"still","instant":{"epoch":{"id":"\(epoch.id.uuidString)"},\
        "hostTime":{"rawValue":0}},\
        "content":{"x":0,"y":0,"width":1,"height":1},"contentScale":1}
        """.utf8)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ContentCropSample.self, from: wrongKind)
    }
}

/// The log routes by `kind` without decoding, so the discriminator has to be on the wire.
@Test func theLogCanRouteAContentCropWithoutDecodingIt() throws {
    let record = ContentCropSample(instant: at(5), content: .whole, contentScale: 0.727)
    let line = try ObservationLog.encode(record)
    #expect(try ObservationLog.kind(of: line) == "contentCrop")
}
