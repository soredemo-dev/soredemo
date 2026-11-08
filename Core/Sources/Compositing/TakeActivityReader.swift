import Foundation
import Framing
import Project
import Timeline

/// Reads one observation log into a `TakeActivity`: everything that happened, as a cut producer
/// is allowed to see it.
///
/// **One pass over the lines, beside `FramingPlanReader`**, for that reader's reason: the steps a
/// cut is proposed between and the steps the timeline's lane draws must come from the same lines,
/// and decoding the log belongs to one place.
///
/// **Speech arrives from the caller**, as offsets into the recording, because what was said lives
/// in the transcript or the waveform, not in this log; this converts it onto the host clock with
/// the same anchor everything else is placed by.
///
/// **What the observer could not see is read as well as what it saw**: secure input and a tap the
/// system switched off both emit nothing, and a producer handed only the events would read those
/// spans as stillness.
public enum TakeActivityReader {
    public static func take(fromObservationLogAt url: URL, anchor: EpochAnchor, duration: Nanoseconds,
                            speech: [Range<Int64>]) throws -> TakeActivity {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var chains: [AXChainRecord] = []
        var pointer: [PointerSample] = []
        var buttons: [ButtonEvent] = []
        var keys: [KeySample] = []
        var unobserved: [HostRange] = []
        for line in lines {
            switch try ObservationLog.kind(of: line) {
            case "axChain": chains.append(try ObservationLog.decode(line) as AXChainRecord)
            case "pointer": pointer.append(try ObservationLog.decode(line) as PointerSample)
            case "button": buttons.append(try ObservationLog.decode(line) as ButtonEvent)
            case "key": keys.append(try ObservationLog.decode(line) as KeySample)
            case "secureInput": unobserved.append((try ObservationLog.decode(line) as SecureInputInterval).interval)
            case "tapDisabled": unobserved.append((try ObservationLog.decode(line) as TapDisabledInterval).interval)
            default: break
            }
        }
        let recording = HostRange(epoch: anchor.epoch, start: anchor.hostTime, duration: duration)
        return try TakeActivity(
            recording: recording,
            // Closed by the recording's end, as `RecordedStepsModel` closes them, so a step here
            // and a step on the lane are the same step.
            steps: RecordedSteps.steps(from: chains, recordingEnd: recording.endInstant),
            pointer: pointer, buttons: buttons, shortcuts: keys,
            speech: speech.compactMap { span in
                // An empty span says nothing was said; it is not an instant of speech.
                guard span.upperBound > span.lowerBound else { return nil }
                return HostRange(epoch: anchor.epoch, start: anchor.hostTime + Nanoseconds(span.lowerBound),
                                 duration: Nanoseconds(span.upperBound - span.lowerBound))
            },
            unobserved: unobserved)
    }
}

private extension HostRange {
    var endInstant: HostInstant { HostInstant(epoch: epoch, hostTime: end) }
}
