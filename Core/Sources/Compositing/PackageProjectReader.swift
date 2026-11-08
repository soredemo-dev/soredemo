import AVFoundation
import Foundation
import Framing
import Overlays
import Project
import Surface
import Timeline

/// Reads a `.soredemo` package for the surface's verbs: the manifest for what a person decided,
/// and the observation log — found by its header's join field — for what happened.
///
/// **Read-only by construction.** Nothing here writes; the package is opened the way the editor
/// opens it, through `ProjectPackageIO`, so a link standing in for the media or a log is refused
/// the same way.
public struct PackageProjectReader: ProjectReading {
    public init() {}

    public func open(_ path: String) throws -> OpenedProject {
        let package = URL(fileURLWithPath: path, isDirectory: true)
        let snapshot = try ProjectPackageIO.load(from: package)
        guard let media = snapshot.mediaFilenames.first else {
            throw Failure(code: .cannotOpenProject, message: "\(package.lastPathComponent) names no recording.")
        }
        let dismissed = try EditState.decoding(snapshot.edit.dismissedCutData, as: [CutProposal.Key].self) ?? []
        return OpenedProject(package: package, name: package.lastPathComponent, mediaFilename: media,
                             log: try log(forMedia: media, in: package),
                             edit: snapshot.edit.timeline, dismissed: Set(dismissed))
    }

    public func take(of log: OpenedProject.Log, speech: [Range<Int64>]) throws -> TakeActivity {
        try TakeActivityReader.take(fromObservationLogAt: log.url, anchor: log.anchor,
                                    duration: log.duration, speech: speech)
    }

    public func framing(of log: OpenedProject.Log) throws -> FramingPlan {
        try FramingPlanReader.plan(fromObservationLogAt: log.url)
    }

    /// The log and its length. **A log without a trailer is refused, not guessed at**: the
    /// trailer is the first moment a segment's span is known, and a recording that crashed has
    /// none — any length made up for it would be a plausible wrong number.
    private func log(forMedia media: String, in package: URL) throws -> OpenedProject.Log? {
        guard let url = try ProjectPackageIO.observationLog(forMedia: media, in: package) else { return nil }
        let report = try ObservationLogReadReport.read(logAt: url)
        guard let anchor = report.header?.anchor else {
            throw Failure(code: .unreadableObservationLog, message: "\(url.lastPathComponent) has no readable header.")
        }
        guard let trailer = report.trailer else {
            throw Failure(code: .unreadableObservationLog,
                          message: "\(url.lastPathComponent) has no trailer: the recording did not close cleanly, so its length is not known.")
        }
        guard trailer.hostRange.epoch == anchor.epoch, trailer.hostRange.end.rawValue > anchor.hostTime.rawValue else {
            throw Failure(code: .unreadableObservationLog,
                          message: "\(url.lastPathComponent)'s trailer does not end after its header's anchor, so its length cannot be measured.")
        }
        return OpenedProject.Log(url: url, anchor: anchor,
                                 duration: Nanoseconds(trailer.hostRange.end.rawValue - anchor.hostTime.rawValue))
    }
}

/// What a recording's audio says was heard, through the same function the editor's Cuts tab
/// uses (`SilenceFinder.sounding(peaks:…)`), at its default threshold.
public struct WaveformHearing: Hearing {
    public init() {}

    public func heard(in project: OpenedProject) async -> Heard {
        guard let log = project.log else { return .nothing("no observation log") }
        do {
            let media = try ProjectPackageIO.mediaFile(named: project.mediaFilename, in: project.package)
            let waveform = try await WaveformEnvelope.read(from: AVURLAsset(url: media))
            guard let sounding = SilenceFinder.sounding(peaks: waveform.peaks, sliceSeconds: waveform.sliceDuration,
                                                        duration: log.duration)
            else { return .nothing("the recording has no audio track") }
            return .sound(sounding)
        } catch {
            return .nothing("the audio could not be read: \(error)")
        }
    }
}
