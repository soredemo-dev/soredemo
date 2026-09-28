import Foundation

/// **The name a person sees for a recording** — in the window's title, and as the starting name
/// in every save panel.
///
/// Every one of those read the media file's own name, and for a fresh recording that is
/// `master-00`: the capture's internal segment name, which the observation log is matched to
/// (`ObservationWriter.expectedLogURL`) and which therefore cannot change. So the name is decided
/// here instead, once, for every place that shows it (reported 2026-09-28).
///
/// - a saved project: the project's own name — the person chose it;
/// - a video that was opened: its filename — somebody else, or they, chose it;
/// - a fresh recording: "Recording" and when it was made, the shape macOS gives its own screen
///   recordings, with no colons — a colon is a path separator to Finder.
///
/// **When it was made is read off the file, not off a clock**: this target reads no ambient time
/// (architecture rule 3), and the file's creation date is a fact about the recording anyway.
enum RecordingName {
    static func display(for mediaURL: URL, savedPackage: URL?, recordedAt: Date?) -> String {
        if let savedPackage { return savedPackage.deletingPathExtension().lastPathComponent }
        let own = mediaURL.deletingPathExtension().lastPathComponent
        guard isInternalSegmentName(own) else { return own }
        guard let recordedAt else { return String(localized: "Recording") }
        let stamp = recordedAt.formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        return String(localized: "Recording \(stamp)")
    }

    /// `master-NN` — what `CaptureSession` names a segment, and never a name a person gave.
    static func isInternalSegmentName(_ name: String) -> Bool {
        name.wholeMatch(of: /master-\d{2,}/) != nil
    }

    /// When the file was made, or `nil` when the file system does not say.
    static func creationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }
}
