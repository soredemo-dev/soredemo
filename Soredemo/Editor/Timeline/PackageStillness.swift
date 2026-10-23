import Capture
import Compositing
import Foundation
import Overlays
import Project

/// What a recording says about its own stillness, with the segment table it has to be read
/// against.
///
/// `StillnessReader` answers by decoding every frame of the recording and differencing it —
/// minutes of work on a long demo, and the reason the control has a progress bar at all.
/// `StillInterval` is the same answer written down at capture time, where ScreenCaptureKit was
/// already reporting that it had drawn nothing; reading it back is a scan of one small text file.
///
/// **Its own type because it is file work**: it opens the recording's package and its
/// observation logs, and `TimelineEditorModel` is the editing state, which reads no files.
enum PackageStillness {
    enum Answer {
        case recorded([StillInterval], SegmentTable)
        case nothingWasEverStill
        case theRecordingDoesNotCarryIt
    }

    /// Any failure to read the package is `theRecordingDoesNotCarryIt`, not an error shown to a
    /// person: the fallback is the decode, which answers the same question correctly and only
    /// costs time. A recording whose package cannot be opened has bigger problems than this
    /// control, and they surface where the package is opened.
    ///
    /// Nothing is threaded through the UI for this: the package and its logs are derived from
    /// the media URL the toolbar already has.
    static func answer(forMediaAt url: URL) -> Answer {
        let packageURL = ProjectStore.packageURL(forMediaAt: url)
        guard let snapshot = try? ProjectPackageIO.load(from: packageURL),
              !snapshot.segments.segments.isEmpty else {
            return .theRecordingDoesNotCarryIt
        }
        let logs = snapshot.segments.segments.map {
            ObservationWriter.logURL(forSegment: $0.index, in: packageURL)
        }
        guard let outcome = try? RecordedStillnessReader.intervals(fromObservationLogsAt: logs) else {
            return .theRecordingDoesNotCarryIt
        }
        switch outcome {
        case .recorded(let intervals):    return .recorded(intervals, snapshot.segments)
        case .nothingWasEverStill:        return .nothingWasEverStill
        case .theRecordingDoesNotCarryIt: return .theRecordingDoesNotCarryIt
        }
    }
}
