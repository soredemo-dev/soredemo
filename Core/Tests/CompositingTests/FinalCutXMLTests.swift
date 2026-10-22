import Foundation
import Testing
import Timeline
@testable import Compositing

/// **What can be checked without an editing application, and what cannot.**
///
/// Nothing here opens the file in Final Cut or Resolve. Resolve is installed on the machine this
/// was written on and ships no DTD and no scripting module; Final Cut is not installed. So the
/// claim these tests make is "this is the document the FCPXML reference describes", not "an
/// application accepted it" — and the second claim is settled by dragging one file in, which no
/// test suite can do.
///
/// What they do check is the half that is arithmetic, and it is the half that goes wrong
/// silently: **a document that parses and plays the wrong part of the recording.** The round-trip
/// below is the real test — the spine is parsed back and the timeline reconstructed from it,
/// frame for frame.
@Suite("Final Cut XML")
struct FinalCutXMLTests {
    static let rate = 60
    static let source = FinalCutXML.Source(
        url: URL(fileURLWithPath: "/Users/x/Product Demo/master-00.mov"),
        duration: Nanoseconds(60_000_000_000), width: 1920, height: 1080,
        frameRate: rate, hasAudio: true)

    static func timeline(_ clips: [(start: Int64, duration: Int64, speed: Double)])
    -> EditTimeline {
        EditTimeline(clips: clips.enumerated().map { index, clip in
            EditClip(id: ClipID(rawValue: index + 1),
                     sourceStart: Nanoseconds(clip.start),
                     duration: Nanoseconds(clip.duration), speed: clip.speed)
        })
    }

    static func text(_ timeline: EditTimeline,
                     source: FinalCutXML.Source = FinalCutXMLTests.source,
                     name: String = "Demo") throws -> String {
        guard case .document(let xml) = FinalCutXML.document(
            timeline: timeline, source: source, projectName: name) else {
            Issue.record("a well-formed timeline was refused")
            throw CancellationError()
        }
        return xml
    }

    // MARK: - Times

    /// `"0s"` is what the format uses for zero, and `"0/60s"` is arithmetically identical and is
    /// not what any reference document shows. Matching the convention costs one branch.
    @Test("zero is written the way the format writes zero")
    func zeroIsZeroS() {
        #expect(FinalCutXML.timeAttribute(0, frameRate: 60) == "0s")
    }

    /// **The denominator is always the frame rate**, so every number in the document reads
    /// directly as a frame index rather than as a fraction somebody has to divide.
    @Test("a time is a whole number of frames over the frame rate")
    func timesAreFramesOverTheRate() {
        #expect(FinalCutXML.timeAttribute(1_000_000_000, frameRate: 60) == "60/60s")
        #expect(FinalCutXML.timeAttribute(500_000_000, frameRate: 60) == "30/60s")
        #expect(FinalCutXML.timeAttribute(1_000_000_000, frameRate: 30) == "30/30s")
    }

    /// **Rounded, not truncated**, and this is the case that separates them: 1/120 of a second at
    /// 60 fps is half a frame. Truncation biases every value the same way and the drift
    /// accumulates across a timeline of forty clips.
    @Test("a time between frames rounds rather than truncating")
    func timesRoundRatherThanTruncate() {
        #expect(FinalCutXML.frames(8_400_000, frameRate: 60) == 1)   // 0.504 frames
        #expect(FinalCutXML.frames(8_200_000, frameRate: 60) == 0)   // 0.492 frames
    }

    /// A frame rate that is not a frame rate answers rather than dividing by zero.
    @Test("a frame rate of zero produces a time rather than a crash")
    func aZeroFrameRateDoesNotDivide() {
        #expect(FinalCutXML.timeAttribute(1_000_000_000, frameRate: 0) == "0s")
        #expect(FinalCutXML.frames(1_000_000_000, frameRate: 0) == 0)
        #expect(FinalCutXML.frameDuration(0) == "1/30s")
    }

    // MARK: - The document parses, and everything in it is on a frame

    @Test("the document is well-formed XML")
    func theDocumentParses() throws {
        let xml = try Self.text(Self.timeline([(0, 2_000_000_000, 1)]))
        #expect(throws: Never.self) {
            _ = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        }
    }

    /// **Every time in the document lands on a frame**, checked by walking the parsed tree rather
    /// than by trusting the one function that wrote them. A value between frames is where
    /// importers disagree — some round, some refuse, and the ones that round do not agree with
    /// each other.
    @Test("every time attribute in the document is a whole frame")
    func everyTimeIsOnAFrame() throws {
        let xml = try Self.text(Self.timeline([(1_000_000_000, 2_500_000_000, 1),
                                               (9_000_000_000, 1_333_333_333, 2)]))
        let document = try XMLDocument(xmlString: xml, options: [])
        var checked = 0
        func walk(_ node: XMLNode) {
            if let element = node as? XMLElement {
                for attribute in element.attributes ?? [] {
                    guard let value = attribute.stringValue,
                          value.hasSuffix("s"), value != "0s" else { continue }
                    let body = value.dropLast()
                    guard body.contains("/") else { continue }
                    let parts = body.split(separator: "/")
                    #expect(parts.count == 2, "\(value) is not a rational")
                    #expect(Int(parts[1]) == Self.rate,
                            "\(value) is not over the sequence's frame rate")
                    #expect(Int(parts[0]) != nil, "\(value) has no frame count")
                    checked += 1
                }
            }
            for child in node.children ?? [] { walk(child) }
        }
        walk(document)
        #expect(checked >= 6, "only \(checked) times were checked — this decided nothing")
    }

    // MARK: - The round trip, which is the real test

    /// **Parsed back, the spine reconstructs the timeline it came from.**
    ///
    /// Everything above would pass against a document that named the right numbers in the wrong
    /// attributes. This reads `offset`, `start` and `duration` off each `asset-clip` and rebuilds
    /// the edit: the offsets must run consecutively with no gap and no overlap, the durations must
    /// be each clip's OUTPUT length, and the starts must be each clip's source in-point. A
    /// document that plays the wrong part of the recording fails here and nowhere else.
    @Test("the clips read back as the timeline that was exported")
    func theSpineRoundTrips() throws {
        let clips: [(start: Int64, duration: Int64, speed: Double)] = [
            (0, 2_000_000_000, 1),
            (5_000_000_000, 3_000_000_000, 1),
            (20_000_000_000, 4_000_000_000, 1),
        ]
        let timeline = Self.timeline(clips)
        let document = try XMLDocument(xmlString: try Self.text(timeline), options: [])
        let assetClips = try document.nodes(forXPath: "//asset-clip").compactMap { $0 as? XMLElement }
        #expect(assetClips.count == clips.count)

        func frames(_ element: XMLElement, _ name: String) -> Int64? {
            guard let value = element.attribute(forName: name)?.stringValue else { return nil }
            if value == "0s" { return 0 }
            let parts = value.dropLast().split(separator: "/")
            guard parts.count == 2, let count = Int64(parts[0]) else { return nil }
            return count
        }

        var expectedOffset: Int64 = 0
        for (index, element) in assetClips.enumerated() {
            let clip = timeline.clips[index]
            #expect(frames(element, "offset")
                    == FinalCutXML.frames(expectedOffset, frameRate: Self.rate),
                    "clip \(index) is at the wrong place in the sequence")
            #expect(frames(element, "duration")
                    == FinalCutXML.frames(clip.outputDuration.rawValue, frameRate: Self.rate),
                    "clip \(index) plays for the wrong length")
            #expect(frames(element, "start")
                    == FinalCutXML.frames(clip.sourceStart.rawValue, frameRate: Self.rate),
                    "clip \(index) starts at the wrong point in the recording")
            expectedOffset += clip.outputDuration.rawValue
        }

        // And the sequence is as long as the sum of what plays — the number an importer uses to
        // size the timeline, and the one that is wrong if any clip's length is.
        let sequence = try #require(
            document.nodes(forXPath: "//sequence").first as? XMLElement)
        #expect(frames(sequence, "duration")
                == FinalCutXML.frames(timeline.outputDuration.rawValue, frameRate: Self.rate))
    }

    /// A clip that does not play at the recording's own pace carries a time map, and its `start`
    /// is on the output axis — divided by the speed, the same as its length. Getting this wrong
    /// does not fail; it plays the wrong part of the recording.
    @Test("a clip with a speed carries a ramp and an output-axis in-point")
    func aRetimedClipCarriesATimeMap() throws {
        let timeline = Self.timeline([(10_000_000_000, 4_000_000_000, 2)])
        let document = try XMLDocument(xmlString: try Self.text(timeline), options: [])
        let maps = try document.nodes(forXPath: "//timeMap")
        #expect(maps.count == 1, "a clip at 2x carries exactly one ramp")
        let points = try document.nodes(forXPath: "//timept")
        #expect(points.count == 2, "the ramp runs from one point to another")

        let clip = try #require(
            document.nodes(forXPath: "//asset-clip").first as? XMLElement)
        // 10s of recording played at 2x begins 5s along the output axis: 300 frames at 60.
        #expect(clip.attribute(forName: "start")?.stringValue == "300/60s")
        // And 4s of recording at 2x plays for 2s: 120 frames.
        #expect(clip.attribute(forName: "duration")?.stringValue == "120/60s")
    }

    /// A clip at the recording's own pace carries no ramp at all — an identity time map is a
    /// thing importers have to interpret for no gain.
    @Test("a clip at normal speed carries no time map")
    func anUnretimedClipHasNoTimeMap() throws {
        let document = try XMLDocument(
            xmlString: try Self.text(Self.timeline([(0, 2_000_000_000, 1)])), options: [])
        #expect(try document.nodes(forXPath: "//timeMap").isEmpty)
    }

    // MARK: - Text that would otherwise break the document

    /// **A project called `Q&A "draft" <v2>` is an ordinary name.** Escaping four of the five
    /// characters gives a document that parses until somebody uses the fifth.
    @Test("a name full of XML is escaped rather than written through")
    func namesAreEscaped() throws {
        let xml = try Self.text(Self.timeline([(0, 1_000_000_000, 1)]),
                                name: #"Q&A "draft" <v2> it's"#)
        #expect(throws: Never.self) { _ = try XMLDocument(xmlString: xml, options: []) }
        let document = try XMLDocument(xmlString: xml, options: [])
        let project = try #require(document.nodes(forXPath: "//project").first as? XMLElement)
        // Read back through the parser, so this checks the escaping rather than restating it.
        #expect(project.attribute(forName: "name")?.stringValue == #"Q&A "draft" <v2> it's"#)
    }

    /// **XML 1.0 has no way to write most control characters at all** — not escaped, not as a
    /// character reference. A name pasted from somewhere carrying one made a document Final Cut
    /// could not open. They are left out; tab, newline and return are legal and stay.
    @Test("a name carrying a control character still makes a document that parses")
    func controlCharactersAreLeftOut() throws {
        let name = "Demo\u{0}one\u{8}two\u{B}three\u{1F}four"
        let xml = try Self.text(Self.timeline([(0, 1_000_000_000, 1)]), name: name)
        let document = try XMLDocument(xmlString: xml, options: [])
        let project = try #require(document.nodes(forXPath: "//project").first as? XMLElement)
        #expect(project.attribute(forName: "name")?.stringValue == "Demoonetwothreefour")
        #expect(FinalCutXML.escaped("a\tb\nc\rd") == "a\tb\nc\rd")
    }

    @Test("every character that needs escaping is escaped")
    func escapingCoversAllFive() {
        #expect(FinalCutXML.escaped("&<>\"'") == "&amp;&lt;&gt;&quot;&apos;")
        #expect(FinalCutXML.escaped("plain") == "plain")
    }

    /// **A recording in a folder with a space is the ordinary case**, and a raw path there is a
    /// `src` that resolves to nothing.
    @Test("a path with spaces becomes a percent-encoded file URL")
    func pathsArePercentEncoded() throws {
        let xml = try Self.text(Self.timeline([(0, 1_000_000_000, 1)]))
        #expect(xml.contains("file:///Users/x/Product%20Demo/master-00.mov"))
        #expect(!xml.contains("/Product Demo/"))
    }

    // MARK: - Refusals

    @Test("an edit that keeps nothing is refused by name")
    func anEmptyEditIsRefused() {
        #expect(FinalCutXML.document(timeline: EditTimeline(clips: []), source: Self.source,
                                     projectName: "x")
                == .refused(.theEditKeepsNothing))
    }

    @Test("a recording with no frame rate is refused by name")
    func noFrameRateIsRefused() {
        let broken = FinalCutXML.Source(url: Self.source.url, duration: Self.source.duration,
                                        width: 1920, height: 1080, frameRate: 0, hasAudio: true)
        #expect(FinalCutXML.document(timeline: Self.timeline([(0, 1_000_000_000, 1)]),
                                     source: broken, projectName: "x")
                == .refused(.theFrameRateIsNotAFrameRate))
    }

    @Test("a recording with no size is refused by name")
    func noSizeIsRefused() {
        let broken = FinalCutXML.Source(url: Self.source.url, duration: Self.source.duration,
                                        width: 0, height: 1080, frameRate: 60, hasAudio: true)
        #expect(FinalCutXML.document(timeline: Self.timeline([(0, 1_000_000_000, 1)]),
                                     source: broken, projectName: "x")
                == .refused(.theRecordingHasNoSize))
    }

    /// **`hasAudio` is asked, not assumed.** Claiming an audio track a file does not have makes
    /// an importer look for one, and a silent clip is indistinguishable from a broken one.
    @Test("a recording with no audio does not claim to have any")
    func silentMediaSaysSo() throws {
        let silent = FinalCutXML.Source(url: Self.source.url, duration: Self.source.duration,
                                        width: 1920, height: 1080, frameRate: 60, hasAudio: false)
        let xml = try Self.text(Self.timeline([(0, 1_000_000_000, 1)]), source: silent)
        #expect(!xml.contains("hasAudio"))
        #expect(try Self.text(Self.timeline([(0, 1_000_000_000, 1)])).contains("hasAudio=\"1\""))
    }

    /// The version attribute is the one number that decides whether a file opens at all, so it is
    /// pinned: 1.10 is the broadest, and a default that drifted upward would quietly stop opening
    /// on Resolve 18 through 20.
    @Test("the default version is the one every supported application accepts")
    func theDefaultVersionIsTheBroadest() throws {
        #expect(FinalCutXML.Version.v1_10.rawValue == "1.10")
        let xml = try Self.text(Self.timeline([(0, 1_000_000_000, 1)]))
        #expect(xml.contains(#"<fcpxml version="1.10">"#))
        for version in FinalCutXML.Version.allCases {
            #expect(!version.displayName.isEmpty)
        }
    }
}

/// **The camera on a connected lane, cut exactly as the screen is.**
///
/// An earlier version of `FinalCutXML` said the camera could not be carried because its offset
/// from the screen was unknown. It is not unknown: the recorder measures it from the two
/// recordings' own first-frame instants, and the preview has been compositing with it all along.
///
/// The arithmetic is the part that fails silently. At screen time S the wall instant is
/// `S + screenStart`, so the camera file's time for it is `S - offset` — and a document that got
/// the sign wrong would play a face from the wrong place with nothing to report.
@Suite("Final Cut XML with a camera")
struct FinalCutXMLCameraTests {
    static let rate = 60
    static let screen = FinalCutXMLTests.source
    static let camera = FinalCutXML.Source(
        url: URL(fileURLWithPath: "/Users/x/Product Demo/camera-00.mov"),
        duration: Nanoseconds(58_000_000_000), width: 1280, height: 720,
        frameRate: rate, hasAudio: true)

    static func document(_ clips: [(start: Int64, duration: Int64, speed: Double)],
                         offset: Int64) throws -> XMLDocument {
        let timeline = FinalCutXMLTests.timeline(clips)
        guard case .document(let xml) = FinalCutXML.document(
            timeline: timeline, source: screen, camera: camera,
            cameraOffset: Nanoseconds(offset), projectName: "Demo") else {
            Issue.record("a well-formed timeline with a camera was refused")
            throw CancellationError()
        }
        return try XMLDocument(xmlString: xml, options: [])
    }

    static func frames(_ element: XMLElement, _ name: String) -> Int64? {
        guard let value = element.attribute(forName: name)?.stringValue else { return nil }
        if value == "0s" { return 0 }
        let parts = value.dropLast().split(separator: "/")
        guard parts.count == 2, let count = Int64(parts[0]) else { return nil }
        return count
    }

    @Test("a camera adds its own asset and its own format")
    func theCameraGetsItsOwnResources() throws {
        let document = try Self.document([(0, 4_000_000_000, 1)], offset: 0)
        #expect(throws: Never.self) { _ = try document.nodes(forXPath: "//asset") }
        let assets = try document.nodes(forXPath: "//asset").compactMap { $0 as? XMLElement }
        #expect(assets.count == 2)
        // **Its own format, because a camera is almost never the screen's shape.** One format for
        // both would describe a 16:9 webcam by a 16:10 display and letterbox it.
        let formats = try document.nodes(forXPath: "//format").compactMap { $0 as? XMLElement }
        #expect(formats.count == 2)
        #expect(formats.contains { $0.attribute(forName: "width")?.stringValue == "1280" })
    }

    /// **A connected clip's `offset` is in the parent's timeline**, whose origin is the parent's
    /// own `start` — so a camera beginning at the same instant carries the parent's `start`.
    @Test("the camera clip is connected to its screen clip on lane 1")
    func theCameraIsOnLaneOne() throws {
        let document = try Self.document([(0, 4_000_000_000, 1),
                                          (10_000_000_000, 3_000_000_000, 1)], offset: 0)
        let connected = try document.nodes(forXPath: "//asset-clip[@lane]")
            .compactMap { $0 as? XMLElement }
        #expect(connected.count == 2, "one camera clip per screen clip")
        for clip in connected {
            #expect(clip.attribute(forName: "lane")?.stringValue == "1")
            #expect(clip.attribute(forName: "ref")?.stringValue == "asset-2")
            let parent = clip.parent as? XMLElement
            #expect(parent?.name == "asset-clip", "the camera must be inside its screen clip")
            #expect(Self.frames(clip, "offset") == Self.frames(parent!, "start"),
                    "a connected clip's offset is the parent's start")
            #expect(Self.frames(clip, "duration") == Self.frames(parent!, "duration"))
        }
    }

    /// **The sign is the thing that fails silently.** A camera that began 500 ms LATE has a
    /// positive offset, and the camera's in-point for screen time S is `S - offset`.
    @Test("a camera that started late plays from earlier in its own file")
    func theCameraInPointSubtractsTheOffset() throws {
        // The camera started half a second after the screen.
        let document = try Self.document([(2_000_000_000, 3_000_000_000, 1)],
                                         offset: 500_000_000)
        let clip = try #require(document.nodes(forXPath: "//asset-clip[@lane]")
            .first as? XMLElement)
        // 2.0 s of screen is 1.5 s into the camera: 90 frames at 60.
        #expect(Self.frames(clip, "start") == 90)
    }

    /// **A clip from before the camera existed carries no camera at all.** A camera that woke
    /// 200 ms late has nothing for the recording's first 200 ms, and a negative in-point is how
    /// that becomes a face playing from the wrong place.
    @Test("a clip earlier than the camera carries no camera")
    func aClipBeforeTheCameraHasNone() throws {
        let document = try Self.document([(0, 1_000_000_000, 1),
                                          (5_000_000_000, 2_000_000_000, 1)],
                                         offset: 2_000_000_000)
        let connected = try document.nodes(forXPath: "//asset-clip[@lane]")
        // The first clip starts at 0 and the camera did not exist until 2 s in, so only the
        // second clip carries one.
        #expect(connected.count == 1)
        let clip = try #require(connected.first as? XMLElement)
        // 5.0 s of screen is 3.0 s into the camera: 180 frames.
        #expect(Self.frames(clip, "start") == 180)
    }

    /// A retimed clip closes around both its camera and its ramp, and the document still parses —
    /// which is the check that catches an element left open.
    @Test("a retimed clip with a camera still produces well-formed XML")
    func aRetimedClipWithACameraParses() throws {
        let document = try Self.document([(4_000_000_000, 4_000_000_000, 2)], offset: 0)
        #expect(try document.nodes(forXPath: "//timeMap").count == 1)
        #expect(try document.nodes(forXPath: "//asset-clip[@lane]").count == 1)
        // Both are children of the one screen clip.
        let screen = try #require(document.nodes(forXPath: "//spine/asset-clip")
            .first as? XMLElement)
        #expect((screen.children ?? []).count >= 2)
    }

    /// **Without a camera nothing changes**, which is what keeps the seventeen tests above
    /// meaningful: they were written before the lane existed.
    @Test("no camera means no lane and no second asset")
    func noCameraChangesNothing() throws {
        guard case .document(let xml) = FinalCutXML.document(
            timeline: FinalCutXMLTests.timeline([(0, 2_000_000_000, 1)]),
            source: Self.screen, projectName: "Demo") else {
            Issue.record("refused")
            return
        }
        #expect(!xml.contains("lane="))
        #expect(!xml.contains("asset-2"))
        #expect(!xml.contains("format-2"))
    }
}
