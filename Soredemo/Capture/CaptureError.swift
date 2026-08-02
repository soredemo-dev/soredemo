import Foundation

/// Failures the capture path raises that are **not** "nothing happened".
///
/// Every case here names a state a recording can be *in*, which is the point:
/// each one has a downstream consequence the log has to record (Task 11), and
/// each one is otherwise indistinguishable from a quiet, working session. A
/// tap that was never created delivers no events; so does a person who did not
/// move the mouse. One of those is a five-minute recording with no pointer
/// track and nothing anywhere saying why.
///
/// `CaptureSession.SessionError` is a separate type and stays that way: those
/// are writer- and stream-lifecycle failures with a segment to attach to.
/// These are about whether observation could start at all.
public enum CaptureError: Error, Equatable {
    /// `CGEvent.tapCreate` returned `nil`.
    ///
    /// **Read this as "Input Monitoring is not granted", never as "no events
    /// happened".** `tapCreate` has exactly one documented failure signal —
    /// a null return — and TCC denial is by far its most common cause;
    /// `CapturePermissions.status(of: .inputMonitoring)` is the way to
    /// confirm which, and `CapturePermissions.degradation(for:)` already
    /// names the consequence: `.observationBlind`. The recording may still
    /// proceed — the master is unaffected — but it proceeds with no pointer
    /// track, no clicks and no shortcuts, and that fact belongs in the log
    /// rather than being inferred later from an empty file.
    case inputMonitoringUnavailable

    /// `CFMachPortCreateRunLoopSource` returned `nil` for a port that
    /// `tapCreate` had already handed back.
    ///
    /// Distinct from the case above, deliberately, even though a caller will
    /// usually treat them the same: this one means the grant *is* held and
    /// the failure is in this process's own run-loop plumbing, which is a
    /// different thing to go and look at. Collapsing them would send the
    /// next person to System Settings for a bug that is not there.
    case eventTapRunLoopSourceUnavailable

    /// `start(onObservation:)` was called on an observer that is already
    /// running. Two taps on one observer would double every sample.
    case alreadyObserving
}
