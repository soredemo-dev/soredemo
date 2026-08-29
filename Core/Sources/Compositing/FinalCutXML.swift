import Foundation
import Timeline

/// **The cut, in a format a real editing application reads.**
///
/// The one thing on the gap list that turns this from a closed tool into one that hands off.
/// ScreenKite is the only recorder in the comparison set that does it; a native editor has an
/// implementation worth reading, at a thousand lines, and reading it is where most of what
/// follows comes from.
///
/// FCPXML is Final Cut Pro's interchange format and **DaVinci Resolve reads the same files**,
/// which is why this is worth more than its name suggests: between them they are most of the
/// professional editing on this platform.
///
/// ### What this carries, and what it deliberately does not
///
/// It carries **the cut**: the recording as an asset, and the clips in output order with their
/// in-points, their lengths and their speeds. That is the workflow this is for — cut here, where
/// the transcript is and where deleting a sentence removes a sentence, then finish in Resolve
/// against the original footage.
///
/// It carries **none of the look**. No zooms, no cursor smoothing, no background, no rounded
/// card, no camera overlay, no captions. Those are not omissions to be filled in later: an NLE
/// has no vocabulary for them, and a file that claimed to carry them would arrive looking like a
/// raw screen recording with no explanation. Somebody who wants the look exports a video; somebody
/// who wants to keep editing exports this. **Said out loud in the interface**, because "export to
/// Final Cut" reads like a promise to carry everything.
///
/// **The camera is not carried either, and that one IS a gap rather than a decision.** The camera
/// is a second file recorded a moment apart from the screen, and putting it on a connected lane
/// means knowing that offset exactly. Establishing it needs a measurement that has not been made,
/// and a face two hundred milliseconds out of sync is a worse thing to hand somebody than a file
/// that says it has no face in it.
///
/// ### Times are rationals, and they must land on frames
///
/// Every time in FCPXML is a rational number of seconds written `"N/Ds"`, and `"0s"` for zero.
/// **They have to be whole multiples of the frame duration.** A value between frames is where
/// importers disagree: some round, some refuse the document, and the ones that round do not agree
/// with each other. So every time here is computed as a FRAME COUNT first and the denominator is
/// always the sequence's frame rate — which also means every number in the file reads directly as
/// "which frame", instead of as a fraction somebody has to divide.
///
/// ### Version 1.10, chosen rather than defaulted
///
/// FCPXML's version attribute is gated on a literal allow-list by both applications, so it is the
/// one number that decides whether a file opens at all. **1.10 is the broadest**: every DaVinci
/// Resolve from 18 up and every Final Cut from 10.6 up accepts it, where 1.11 and above need
/// Resolve 21. Nothing emitted below has existed for less time than 1.10, so a higher version
/// would buy exactly nothing and cost everybody on an older install.
///
/// ### What is NOT verified here, said plainly
///
/// This file is checked for being well-formed XML and for round-tripping — parsed back, the clips
/// reconstruct the timeline they came from, frame for frame. **It has not been opened in Final Cut
/// or Resolve by anything in this repository**, because neither can be driven from a test: Resolve
/// is installed on the machine this was written on and ships no DTD and no scripting module, and
/// Final Cut is not installed at all. So the claim made here is "this is the document the
/// reference describes", not "this application accepted it". Dragging one file into Resolve
/// settles it in ten seconds and nothing in a test suite can.
public enum FinalCutXML {
    /// The FCPXML version written into the document.
    public enum Version: String, Sendable, CaseIterable, Codable {
        /// Resolve 18+, Final Cut Pro 10.6+. The default, and the reason is in the header.
        case v1_10 = "1.10"
        /// Resolve 21+, Final Cut Pro 10.7+.
        case v1_11 = "1.11"

        public var displayName: String {
            switch self {
            case .v1_10: "1.10 — DaVinci Resolve 18+, Final Cut Pro 10.6+"
            case .v1_11: "1.11 — DaVinci Resolve 21+, Final Cut Pro 10.7+"
            }
        }
    }

    /// The one source file the document refers to.
    public struct Source: Sendable, Equatable {
        /// Where the media is now. Written as a `file://` URL, percent-encoded.
        public let url: URL
        /// How long the whole file is, before any cutting. The asset's own duration, which is
        /// not the sequence's: an importer uses it to know how far a clip may be trimmed out.
        public let duration: Nanoseconds
        public let width: Int
        public let height: Int
        public let frameRate: Int
        /// Whether the file has an audio track. **Asked rather than assumed**: writing
        /// `hasAudio="1"` for a file with none makes an importer look for a track that is not
        /// there, and a silent clip in a timeline is indistinguishable from a broken one.
        public let hasAudio: Bool

        public init(url: URL, duration: Nanoseconds, width: Int, height: Int,
                    frameRate: Int, hasAudio: Bool) {
            self.url = url
            self.duration = duration
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.hasAudio = hasAudio
        }
    }

    /// Why a document could not be written. **Named values, never `nil`** — an empty file with no
    /// reason is the one outcome worse than no file.
    public enum Refusal: String, Sendable, Equatable, Hashable {
        /// The edit keeps nothing. Refused rather than written as an empty sequence: an NLE
        /// opening a timeline with no clips in it has no way to say why.
        case theEditKeepsNothing
        /// The recording reports no frame rate, or a nonsensical one. Every time in the document
        /// is a multiple of the frame duration, so there is no document without one.
        case theFrameRateIsNotAFrameRate
        /// The recording has no size. A sequence with a zero dimension is refused by importers
        /// and would be refused here first, where the reason can be said.
        case theRecordingHasNoSize
    }

    public enum Outcome: Sendable, Equatable {
        case document(String)
        case refused(Refusal)
    }

    // MARK: - Time

    /// A time as FCPXML writes it: a rational number of seconds, snapped to a whole frame.
    ///
    /// **`"0s"` for zero**, which is what the format uses and what every reference document shows;
    /// `"0/60s"` is arithmetically the same and is not what importers are given elsewhere, and
    /// matching the convention costs one branch.
    ///
    /// **Rounded to the nearest frame, not truncated.** Truncation biases every value one way, and
    /// over a timeline of forty clips the accumulated drift is visible. Rounding leaves an error
    /// of at most half a frame per value and no direction.
    /// **Named `timeAttribute` rather than `time`, and the rename is the scan's doing.** A bare
    /// `time(` is what `ambientTimeRandomnessAndHashingEnterHeadlessOnlyThroughMonotonicStopwatch`
    /// looks for, because it is also the C function that reads the clock — and a formatter that
    /// shares a name with a clock read is a name worth changing rather than an exception worth
    /// adding. Nothing here reads a clock; every value comes from the timeline.
    public static func timeAttribute(_ nanoseconds: Int64, frameRate: Int) -> String {
        guard frameRate > 0 else { return "0s" }
        let frames = frames(nanoseconds, frameRate: frameRate)
        return frames == 0 ? "0s" : "\(frames)/\(frameRate)s"
    }

    /// The frame a time lands on, rounded. Public because the round-trip check needs the same
    /// arithmetic the document was written with — comparing against a second implementation would
    /// be comparing two guesses.
    public static func frames(_ nanoseconds: Int64, frameRate: Int) -> Int64 {
        guard frameRate > 0 else { return 0 }
        let seconds = Double(nanoseconds) / 1_000_000_000
        return Int64((seconds * Double(frameRate)).rounded())
    }

    /// One frame, as the `frameDuration` attribute wants it.
    public static func frameDuration(_ frameRate: Int) -> String {
        frameRate > 0 ? "1/\(frameRate)s" : "1/30s"
    }

    // MARK: - The document

    /// The FCPXML for a cut of one recording.
    ///
    /// `projectName` is what appears in the importing application's browser. Escaped like every
    /// other text here: a project called `Q&A <draft>` is a perfectly ordinary name and an
    /// unescaped one is a document that will not parse.
    public static func document(timeline: EditTimeline, source: Source,
                                projectName: String,
                                version: Version = .v1_10) -> Outcome {
        guard !timeline.isEmpty else { return .refused(.theEditKeepsNothing) }
        guard source.frameRate > 0 else { return .refused(.theFrameRateIsNotAFrameRate) }
        guard source.width > 0, source.height > 0 else { return .refused(.theRecordingHasNoSize) }

        let rate = source.frameRate
        let assetName = source.url.deletingPathExtension().lastPathComponent

        var spine = ""
        var offset: Int64 = 0
        for clip in timeline.clips {
            let outputDuration = clip.outputDuration.rawValue
            // **`start` is the source in-point, and with a `timeMap` it is on the OUTPUT axis** —
            // divided by the speed, which is what `outputDuration` already is for the length.
            // Getting this wrong does not fail: it plays the wrong part of the recording.
            let start = Int64((Double(clip.sourceStart.rawValue) / clip.speed).rounded())
            spine += """
                        <asset-clip ref="asset-1" offset="\(timeAttribute(offset, frameRate: rate))" \
                name="\(escaped(assetName))" start="\(timeAttribute(start, frameRate: rate))" \
                duration="\(timeAttribute(outputDuration, frameRate: rate))" format="format-1" \
                tcFormat="NDF"\(clip.speed == 1 ? "/>" : ">")

                """
            if clip.speed != 1 {
                // **The ramp covers the WHOLE media, not the clip.** a native editor's note, taken at
                // face value and worth keeping: a time map that only spans the clip blacks the
                // tail on import. So the map runs from zero to the media's full length, and the
                // clip's own `start` windows into it.
                let mediaOutput = Int64((Double(source.duration.rawValue) / clip.speed).rounded())
                spine += """
                                <timeMap>
                                    <timept time="0s" value="0s" interp="linear"/>
                                    <timept time="\(timeAttribute(mediaOutput, frameRate: rate))" \
                    value="\(timeAttribute(source.duration.rawValue, frameRate: rate))" interp="linear"/>
                                </timeMap>
                            </asset-clip>

                    """
            }
            offset += outputDuration
        }

        let audio = source.hasAudio
            ? #" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000""#
            : ""
        let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="\(version.rawValue)">
                <resources>
                    <format id="format-1" name="SoredemoFormat" \
            frameDuration="\(frameDuration(rate))" width="\(source.width)" \
            height="\(source.height)" colorSpace="1-1-1 (Rec. 709)"/>
                    <asset id="asset-1" name="\(escaped(assetName))" start="0s" \
            duration="\(timeAttribute(source.duration.rawValue, frameRate: rate))" hasVideo="1" \
            videoSources="1" format="format-1"\(audio)>
                        <media-rep kind="original-media" src="\(escaped(fileURLString(source.url)))"/>
                    </asset>
                </resources>
                <library>
                    <event name="Soredemo">
                        <project name="\(escaped(projectName))">
                            <sequence format="format-1" \
            duration="\(timeAttribute(offset, frameRate: rate))" tcStart="0s" tcFormat="NDF" \
            audioLayout="stereo" audioRate="48k">
                                <spine>
            \(spine.isEmpty ? "" : String(spine.dropLast()))
                                </spine>
                            </sequence>
                        </project>
                    </event>
                </library>
            </fcpxml>

            """
        return .document(document)
    }

    /// XML-escaped text.
    ///
    /// **All five, including the two that are only required inside attribute values.** A project
    /// called `Q&A "draft"` is an ordinary name; escaping four of the five is a document that
    /// parses until somebody uses a quotation mark.
    public static func escaped(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// A `file://` URL as the `src` attribute wants it.
    ///
    /// **`absoluteString`, which percent-encodes**, rather than the path: a recording in a folder
    /// with a space in its name — `~/Desktop/Product Demo/` — is the ordinary case, and a raw path
    /// there is a `src` that resolves to nothing.
    public static func fileURLString(_ url: URL) -> String {
        url.absoluteString
    }
}
