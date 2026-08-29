import AVFoundation
import Timeline
import Foundation

/// **Whether the file a recording just produced is actually a recording.**
///
/// The worst failure this app can have is not a crash. It is a person who talks for eleven
/// minutes, presses stop, and finds out later — in the editor, or on the day they meant to
/// publish — that the file is four seconds long or will not open. A crash costs a restart;
/// this costs the eleven minutes, and they cannot be recorded again.
///
/// Nothing here checked for it. The sequence below is the one that makes each check mean
/// something: does the file exist, is it non-empty, does the container open, does the video
/// actually decode, and is it as long as the recording was.
///
/// ### Each check catches something the one before it cannot
///
/// They look redundant and they are not. A file can exist and be empty — a writer that was
/// killed before its first flush. It can be non-empty and not open — an `.mov` whose `moov`
/// atom was never written, which is exactly what a power cut leaves behind, and which is the
/// most common way a recording dies. It can open and have no video track — an audio-only
/// asset, which is what a screen capture that never received a frame produces. It can have a
/// video track that will not decode. And it can decode perfectly and be four seconds long.
///
/// **The decode check is the one worth having and the one people leave out.** `AVAsset` will
/// happily report a duration for a file whose frames are unreadable; only pulling a frame
/// through the decoder proves there is a picture in there.
///
/// ### Why the length check is loose, and why loose is right
///
/// A recording's expected length is wall-clock from start to stop, and the file is legitimately
/// a little shorter: the last partial frame is not written, and a segment boundary can land
/// just before the stop. So an exact comparison would cry damage on every healthy recording,
/// which is worse than not checking — an alarm that is usually wrong is an alarm people learn
/// to dismiss, including on the day it is right.
///
/// `shortnessThreshold` is therefore set where only a catastrophe reaches it: **half**. A file
/// that is 49% of the length of the session it recorded did not lose a frame at the end; it
/// stopped writing.
///
/// And nothing is checked at all below `shortestWorthChecking`. A one-second recording is
/// within rounding of every threshold, and the ratio is meaningless there.
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
