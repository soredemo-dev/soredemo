import Foundation

/// Failures the capture path raises that are not "nothing happened": each is
/// indistinguishable from a quiet, working session unless logged. Writer- and
/// stream-lifecycle failures are `CaptureSession.SessionError` instead.
public enum CaptureError: Error, Equatable {
    /// `CGEvent.tapCreate` returned `nil`. Read as "Input Monitoring is not
    /// granted", never as "no events happened"; confirm with
    /// `CapturePermissions.status(of: .inputMonitoring)`.
    case inputMonitoringUnavailable

    /// `CFMachPortCreateRunLoopSource` returned `nil` for a port `tapCreate`
    /// already handed back: the grant is held and the failure is in this
    /// process's own run-loop plumbing.
    case eventTapRunLoopSourceUnavailable

    /// `start(onObservation:)` was called on an observer that is already
    /// running. Two taps on one observer would double every sample.
    case alreadyObserving
}
