import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Headless

// The first `swift test` tests of four files that moved out of the app target in Phase
// 3A-3. Until the move, `swift test` could not link them: `Tests/AppSourceTests` read
// them AS TEXT and everything else was the hand-run probe or a person. `1a98402` is what
// that arrangement misses.

// MARK: - CGGeometryBridge: the capture tier's CoreGraphics entry

/// The four scalars survive in order. A bridge that transposed width and height, or
/// origin and size, still returns a rect of the right type — only distinct values catch
/// it, so no two numbers here are equal.
@Test func aPixelRectCarriesTheFourScalarsInOrder() {
    let rect = CGGeometryBridge.pixelRect(from: CGRect(x: 11, y: 22, width: 33, height: 44))
    #expect(rect.x == 11)
    #expect(rect.y == 22)
    #expect(rect.width == 33)
    #expect(rect.height == 44)
}

/// The same for points, which are a different unit and a different type — the whole
/// reason there is no single `convert(_:)` on this bridge.
@Test func aPointRectCarriesTheFourScalarsInOrder() {
    let rect = CGGeometryBridge.pointRect(from: CGRect(x: 1.5, y: 2.5, width: 3.5, height: 4.5))
    #expect(rect.x == 1.5)
    #expect(rect.y == 2.5)
    #expect(rect.width == 3.5)
    #expect(rect.height == 4.5)
}

/// `standardized` is applied, so a negative-extent rect — which `CGRect` permits and
/// this project's own types do not — arrives with a positive origin and extent rather
/// than as a rect nothing downstream can reason about.
@Test func aNegativeExtentRectIsStandardisedOnTheWayIn() {
    let rect = CGGeometryBridge.pixelRect(from: CGRect(x: 100, y: 50, width: -40, height: -20))
    #expect(rect.x == 60)
    #expect(rect.y == 30)
    #expect(rect.width == 40)
    #expect(rect.height == 20)
}

/// Out and back. The exit is a separate function from the entry, so a round trip is a
/// real claim about two pieces of code agreeing rather than about one being invertible.
@Test func aPixelRectRoundTripsThroughTheBridge() {
    let original = PixelRect(x: 7, y: 9, width: 1920, height: 1080)
    #expect(CGGeometryBridge.pixelRect(from: CGGeometryBridge.rect(from: original)) == original)
}

@Test func aPointRectRoundTripsThroughTheBridge() {
    let original = PointRect(x: 0.25, y: 0.5, width: 640, height: 360)
    #expect(CGGeometryBridge.pointRect(from: CGGeometryBridge.rect(from: original)) == original)
}

@Test func aLocationCarriesXThenY() {
    let location = CGGeometryBridge.location(from: CGPoint(x: 3, y: -4))
    #expect(location.x == 3)
    #expect(location.y == -4)
}

/// `NSValue` is the shape `SCStreamFrameInfoContentRect` and friends arrive in.
@Test func aFrameAttachmentDecodesFromAnNSValue() {
    let attachment = NSValue(rect: NSRect(x: 5, y: 6, width: 7, height: 8))
    let rect = CGGeometryBridge.pointRect(fromFrameAttachment: attachment)
    #expect(rect == PointRect(x: 5, y: 6, width: 7, height: 8))
}

/// `CGRect(dictionaryRepresentation:)` is the other shape the same attachments arrive
/// in, so both branches are exercised rather than whichever one the machine happened to
/// produce the day someone looked.
@Test func aFrameAttachmentDecodesFromADictionaryRepresentation() {
    let source = CGRect(x: 9, y: 10, width: 11, height: 12)
    let dictionary = source.dictionaryRepresentation as NSDictionary
    #expect(CGGeometryBridge.pointRect(fromFrameAttachment: dictionary)
            == PointRect(x: 9, y: 10, width: 11, height: 12))
}

/// A `nil` attachment and an attachment of the wrong type both decode to `nil` — a
/// missing frame attachment must read as absent, never as a zero rect that downstream
/// framing would treat as a real measurement.
@Test func anAbsentOrWrongTypedFrameAttachmentIsNil() {
    #expect(CGGeometryBridge.pointRect(fromFrameAttachment: nil) == nil)
    #expect(CGGeometryBridge.pointRect(fromFrameAttachment: "not a rect") == nil)
}

/// The AX decoders take a `CFTypeRef` that may be anything at all — AX hands back
/// `Any?`. A non-`AXValue` must decode to `nil` rather than being force-cast.
@Test func theAXDecodersRefuseAValueThatIsNotAnAXValue() {
    #expect(CGGeometryBridge.point(fromAXValue: "not an AXValue" as CFTypeRef) == nil)
    #expect(CGGeometryBridge.size(fromAXValue: "not an AXValue" as CFTypeRef) == nil)
    #expect(CGGeometryBridge.point(fromAXValue: nil) == nil)
    #expect(CGGeometryBridge.size(fromAXValue: nil) == nil)
}

/// A real `AXValue` of the wrong KIND — a size where a point is expected — must also
/// decode to `nil`. This is the case a `CFGetTypeID` check alone passes: the type ID is
/// right and only `AXValueGetValue`'s own return refuses it.
@Test func theAXPointDecoderRefusesAnAXValueOfTheWrongKind() {
    var size = CGSize(width: 3, height: 4)
    let value = unsafe AXValueCreate(.cgSize, &size)
    #expect(CGGeometryBridge.point(fromAXValue: value) == nil)
}

// MARK: - CaptureError and the blindness it becomes

/// `.alreadyObserving` maps to `nil` — a programming error in this app's own state
/// machine is not a statement about what the recording could see, and logging it as
/// blindness would put a false claim in a segment header.
@Test func onlyThePermissionShapedErrorsBecomeBlindness() {
    #expect(CaptureError.inputMonitoringUnavailable.blindness == .inputMonitoringUnavailable)
    #expect(CaptureError.eventTapRunLoopSourceUnavailable.blindness == .eventTapRunLoopSourceUnavailable)
    #expect(CaptureError.alreadyObserving.blindness == nil)
}

// MARK: - ObservationWriter: paths, and one real log written to disk

@Test func aSegmentLogFilenameIsZeroPaddedToTwoDigits() {
    #expect(ObservationWriter.logFilename(forSegment: 0) == "segment-00.jsonl")
    #expect(ObservationWriter.logFilename(forSegment: 7) == "segment-07.jsonl")
    // Three digits is the case padding must not truncate.
    #expect(ObservationWriter.logFilename(forSegment: 123) == "segment-123.jsonl")
}

@Test func aSegmentLogSitsUnderObservationsInsideThePackage() {
    let url = ObservationWriter.logURL(forSegment: 3, in: URL(filePath: "/tmp/x.soredemo"))
    #expect(url.lastPathComponent == "segment-03.jsonl")
    #expect(url.deletingLastPathComponent().lastPathComponent == "observations")
}

/// The media→log mapping is deliberately narrow: only `<package>/media/master-NN.mov`
/// has an expected log, because that is the only shape capture writes — media is named
/// `master-NN`, the log beside it `segment-NN`. Every refusal is asserted, since a
/// mapping that answered for any URL would produce a confident path to a file that
/// cannot exist. (The first draft of this test asserted `segment-00.mov` as the MEDIA
/// name and failed; the code was right and the test had misread its own subject.)
@Test func onlyAMasterMovInsideMediaHasAnExpectedLog() {
    let package = URL(filePath: "/tmp/x.soredemo")
    let media = package.appending(path: "media").appending(path: "master-00.mov")
    #expect(ObservationWriter.expectedLogURL(forMediaURL: media)?.lastPathComponent
            == "segment-00.jsonl")
    // Wrong extension, wrong directory, wrong prefix, and a non-numeric index.
    #expect(ObservationWriter.expectedLogURL(
        forMediaURL: package.appending(path: "media").appending(path: "master-00.mp4")) == nil)
    #expect(ObservationWriter.expectedLogURL(
        forMediaURL: package.appending(path: "elsewhere").appending(path: "master-00.mov")) == nil)
    #expect(ObservationWriter.expectedLogURL(
        forMediaURL: package.appending(path: "media").appending(path: "segment-00.mov")) == nil)
    #expect(ObservationWriter.expectedLogURL(
        forMediaURL: package.appending(path: "media").appending(path: "master-xx.mov")) == nil)
}

/// One real log, opened, appended to and closed on disk — the first time `swift test`
/// has run this file's actual I/O. Asserts the JSONL shape the format promises: header
/// first, records in between, trailer last, one JSON object per line.
@Test func aWrittenLogIsHeaderThenRecordsThenTrailer() throws {
    let package = URL.temporaryDirectory.appending(path: "obs-writer-\(UUID()).soredemo")
    defer { try? FileManager.default.removeItem(at: package) }

    let epoch = BootEpoch(id: UUID(uuidString: "3C7E5A21-0F44-4E9B-A1D2-6B8C0E5F1A93")!)
    let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(1_000),
                             wallClockUnixNanos: 1_785_000_000_000_000_000)
    let header = ObservationLogHeader(anchor: anchor, segmentIndex: 0,
                                      mediaFilename: "segment-00.mov",
                                      revision: GeometryRevision(id: 1), blindness: [])
    let writer = try ObservationWriter.open(segment: header, in: package)
    try writer.append(PointerSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(1_500)),
                                    position: NormalizedPoint(x: 0.25, y: 0.75),
                                    revision: GeometryRevision(id: 1)))
    let url = try writer.close(
        endedBy: .stopped,
        hostRange: HostRange(epoch: epoch, start: Nanoseconds(1_000), duration: Nanoseconds(1_000)),
        gapWatches: GapSite.allCases.map {
            GapWatch(site: $0, looks: 1, watchedSpanNanos: 1_000, gapsFound: 0, lost: 0)
        })

    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 3)
    // Read the kinds back through JSON rather than by substring: a line that merely
    // MENTIONS "logHeader" would satisfy a `contains` check.
    let kinds = try lines.map { line -> String in
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any])
        return try #require(object["kind"] as? String)
    }
    #expect(kinds == ["logHeader", "pointer", "logTrailer"])
}

/// A record stamped in another boot session is refused at `append`, not written and
/// sorted out later — the log's epoch is a property of the whole file.
@Test func aRecordFromAnotherEpochIsRefusedByTheWriter() throws {
    let package = URL.temporaryDirectory.appending(path: "obs-writer-\(UUID()).soredemo")
    defer { try? FileManager.default.removeItem(at: package) }

    let epoch = BootEpoch(id: UUID(uuidString: "3C7E5A21-0F44-4E9B-A1D2-6B8C0E5F1A93")!)
    let other = BootEpoch(id: UUID(uuidString: "0BADC0DE-0000-4000-8000-000000000003")!)
    let header = ObservationLogHeader(
        anchor: EpochAnchor(epoch: epoch, hostTime: Nanoseconds(0), wallClockUnixNanos: 0),
        segmentIndex: 0, mediaFilename: "segment-00.mov",
        revision: GeometryRevision(id: 1), blindness: [])
    let writer = try ObservationWriter.open(segment: header, in: package)

    #expect(throws: (any Error).self) {
        try writer.append(PointerSample(
            instant: HostInstant(epoch: other, hostTime: Nanoseconds(5)),
            position: NormalizedPoint(x: 0.5, y: 0.5), revision: GeometryRevision(id: 1)))
    }
}

// MARK: - AudioInterleave

/// `layoutDescription(of:)` is a diagnostic, and its job on a buffer with no format
/// description is to SAY so rather than to return an empty string a log would swallow.
@Test func anAudioLayoutDescriptionSaysWhenThereIsNoFormat() throws {
    var buffer: CMSampleBuffer?
    let status = unsafe CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
        sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
    #expect(status == noErr)
    let formatless = try #require(buffer)
    #expect(AudioInterleave.layoutDescription(of: formatless) == "no audio format description")
}

/// `rms(of:)` returns `nil` rather than `0` for a buffer it cannot read. Zero is a
/// legitimate RMS — digital silence — so returning it for "could not measure" would make
/// a silent track and an unreadable one indistinguishable.
@Test func theRMSOfAnUnreadableBufferIsNilAndNotZero() throws {
    var buffer: CMSampleBuffer?
    let status = unsafe CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
        sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
    #expect(status == noErr)
    #expect(AudioInterleave.rms(of: try #require(buffer)) == nil)
}
