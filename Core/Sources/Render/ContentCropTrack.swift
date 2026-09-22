import Foundation
import Geometry
import Project
import Timeline

/// Where the source drew inside the capture buffer, as a function of time.
///
/// **The read half of the window-resize repair.** ScreenCaptureKit keeps a stream's output
/// dimension fixed — Apple's guidance is explicit that changing it while the stream runs is
/// "not recommended" — so a window resized mid-recording is fitted into the buffer it started
/// with and the remainder is left as background. `ContentCropSample` is written at capture
/// time because that boundary is unrecoverable afterwards: a black band and a black window are
/// the same pixels. This turns those records back into an answer per frame.
///
/// A separate type from `PointerTrack` and `ClickTrack` for their own reason: this answers a
/// question about the RECORDING's geometry, not about anything a person did, and the three come
/// from three record streams that can each be absent on their own.
public struct ContentCropTrack: Sendable {
    /// Sorted by host time. Not thinned and not interpolated — a resize is a step, and a crop
    /// eased between two window sizes would show a sliver of background on every frame of the
    /// ease, which is the artefact this whole mechanism exists to remove.
    private let samples: [ContentCropSample]

    public init(samples: [ContentCropSample]) {
        self.samples = samples.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
    }

    /// Nothing to say — an imported recording, a log from before this record existed, or a
    /// segment whose every frame had an unreadable content rect.
    public static let unknown = ContentCropTrack(samples: [])

    public var isEmpty: Bool { samples.isEmpty }

    /// The crop in force at `instant`.
    ///
    /// **`.whole` is the refusal, and it is a named value rather than `nil`** — every frame has
    /// a crop, and a caller that had to branch on absence would write the same `.whole` at each
    /// site. It is returned only when the track is empty, which is the honest reading of a log
    /// that never said: an uncropped buffer is what every recording before this record was
    /// treated as, so nothing about an existing project changes.
    ///
    /// Before the FIRST sample the first sample's own crop is returned, not `.whole`. The first
    /// record is written at the first complete frame of its segment, so the only instants that
    /// fall earlier are ones no frame was delivered for; snapping them to `.whole` would put a
    /// single frame of background at the head of every window recording.
    ///
    /// Epoch-matched for `ClickTrack.ripplePhase`'s reason: two boot sessions' host times
    /// overlap, and a crop from another boot is not a fact about this one.
    public func crop(at instant: HostInstant) -> CropRect {
        guard let first = samples.first else { return .whole }
        var answer = first.content
        for sample in samples
        where sample.instant.epoch == instant.epoch
            && sample.instant.hostTime.rawValue <= instant.hostTime.rawValue {
            answer = sample.content
        }
        return answer
    }

    /// The smallest `contentScale` anywhere in the track, or `nil` when it is empty.
    ///
    /// **This is the number that states what cropping cannot do.** Below 1 the window was
    /// larger than the buffer and ScreenCaptureKit downsampled it to fit; those pixels were
    /// never written and no crop brings them back. Above 1 the window was smaller and its
    /// pixels were magnified into the buffer, which costs nothing but sharpness. A reader that
    /// wants to tell somebody their recording lost detail has only this to go on.
    public var softestScale: Double? {
        samples.map(\.contentScale).min()
    }
}
