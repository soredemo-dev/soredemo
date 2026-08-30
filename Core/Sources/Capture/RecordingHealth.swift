import AVFoundation
import Timeline
import Foundation

/// Whether the file a recording just produced is actually a recording.
///
/// The worst failure this app can have is not a crash. It is a person who talks for eleven
/// minutes, presses stop, and finds out later that the file is four seconds long or will not
/// open. A crash costs a restart; this costs the eleven minutes, unrepeatably.
///
/// Five checks in the order that makes each mean something the one before it cannot: does the
/// file exist, is it non-empty, does the container open, does the video **decode**, and is it
/// as long as the session was. The decode check is the one people leave out — `AVAsset` reports
/// a duration for a file whose frames are unreadable, and only pulling a frame proves there is
/// a picture in there.
///
/// The length check is deliberately loose (`shortnessThreshold` = **half**, and nothing at all
/// below `shortestWorthChecking`), because an alarm that is usually wrong is one people learn to
/// dismiss — including on the day it is right. What each check catches, and why the threshold is
/// where it is: `docs/design/is-the-file-a-recording.md`.
public enum RecordingHealth: Sendable, Equatable {
    /// The file is there, it opens, it decodes, and it is as long as the session was.
    case sound(duration: Nanoseconds)
    /// The file is not a usable recording, and the reason is named.
    case damaged(Damage)

    /// **Named values, never a bare `false`.** Five things go wrong and they have five different
    /// answers: a missing file may be a permissions problem, an unopenable one is usually a
    /// crash mid-write, and a short one means the writer stopped early. A person told only that
    /// something is wrong can act on none of them.
    public enum Damage: String, Sendable, Equatable, Hashable {
        /// Nothing at that path.
        case theFileIsNotThere
        /// The file exists and has no bytes — a writer killed before its first flush.
        case theFileIsEmpty
        /// The container will not open. What a power cut during a `.mov` leaves behind: the
        /// samples are on disk and the index that describes them never was.
        case theContainerWillNotOpen
        /// It opens and there is no picture in it. What a capture that never received a frame
        /// produces.
        case thereIsNoVideoTrack
        /// There is a video track and no frame can be pulled through the decoder.
        case theVideoWillNotDecode
        /// It decodes, and it is less than half as long as the session that recorded it.
        case itIsShorterThanTheSession
    }

    /// How short a file has to be, against the session that produced it, to count as damaged.
    public static let shortnessThreshold = 0.5

    /// Below this, the ratio means nothing and nothing is claimed.
    public static let shortestWorthChecking = Nanoseconds(1_000_000_000)

    /// Whether this is a verdict a person should be interrupted for.
    public var needsSaying: Bool {
        if case .damaged = self { return true }
        return false
    }
}

public enum RecordingCheck {
    /// Checks the file a recording produced, in the order that makes each check mean something.
    ///
    /// `session` is how long the recording ran, by the clock. Pass zero when that is not known
    /// — the length check is then skipped and everything else still runs, which is the honest
    /// behaviour rather than comparing against a number nobody supplied.
    ///
    /// **Reads one frame, not the whole file.** A ten-minute 4K recording cannot be decoded end
    /// to end to answer a question about whether it decodes at all, and the first frame is where
    /// a broken file breaks.
    public static func health(of url: URL, session: Nanoseconds) async -> RecordingHealth {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .damaged(.theFileIsNotThere)
        }
        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard (size ?? 0) > 0 else { return .damaged(.theFileIsEmpty) }

        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else {
            return .damaged(.theContainerWillNotOpen)
        }
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else {
            return .damaged(.thereIsNoVideoTrack)
        }
        guard await decodesAFrame(asset: asset, track: track) else {
            return .damaged(.theVideoWillNotDecode)
        }

        let recorded = Nanoseconds(Int64((duration.seconds * 1_000_000_000).rounded()))
        if session.rawValue >= RecordingHealth.shortestWorthChecking.rawValue,
           Double(recorded.rawValue) / Double(session.rawValue)
            < RecordingHealth.shortnessThreshold {
            return .damaged(.itIsShorterThanTheSession)
        }
        return .sound(duration: recorded)
    }

    /// Whether one frame can be pulled through the decoder.
    ///
    /// **`AVAssetReader` rather than `AVAssetImageGenerator`**: the generator seeks, and a seek
    /// on a file with a broken index fails for a reason that is not "the video will not decode".
    /// Reading from the start is the same thing playback does.
    private static func decodesAFrame(asset: sending AVURLAsset,
                                      track: sending AVAssetTrack) async -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer() else { return false }
        // A sample with no image buffer is a sample that carried no picture — which is a
        // different failure from no sample at all, and both mean the same thing to a viewer.
        return CMSampleBufferGetImageBuffer(sample) != nil
    }
}
