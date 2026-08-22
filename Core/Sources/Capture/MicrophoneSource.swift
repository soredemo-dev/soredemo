import AVFoundation
import Foundation
import ScreenCaptureKit

/// Which microphone a recording captures, and whether this system can capture one at all.
///
/// **Internal and external audio are two different captures with two different failure
/// modes**, and until this existed the recorder acknowledged only one of them: it set
/// `captureMicrophone = true` unconditionally, named no device, and had no answer for a
/// system that cannot do it. System audio is a tap on what the machine is playing and either
/// works or is denied; a microphone is a physical device that can be absent, chosen wrongly,
/// muted at the OS, or held exclusively by another application.
///
/// **Every comparable recorder names the device, and two of them probe for the capability
/// first.** `../opensource/Screen Record Opensource/an Electron recorder-main` and `an Electron recorder-main` both
/// set `microphoneCaptureDeviceID`; an Electron recorder checks `responds(to:)` for the two selectors
/// and emits a `microphone-unavailable` warning rather than failing the recording.
/// `a Swift recorder` does not use ScreenCaptureKit for the microphone at all, and says why:
/// *"Uses AVCaptureSession instead of ScreenCaptureKit because SCK does not support
/// microphone device selection."* That was true when written and is not now — measured on
/// this machine, `SCStreamConfiguration` responds to both selectors — which is why this uses
/// ScreenCaptureKit and keeps one capture rather than running a second session.
public enum MicrophoneSource: Hashable, Sendable {
    /// Whatever the system considers the default input. Follows the user changing it in
    /// System Settings, which a pinned device does not.
    case systemDefault
    /// A specific device by its `AVCaptureDevice.uniqueID`. The name is carried alongside so
    /// a project can say which microphone it recorded from after the device is gone.
    case device(uniqueID: String, name: String)

    /// The `microphoneCaptureDeviceID` this selection asks for, or `nil` for the default.
    public var deviceID: String? {
        switch self {
        case .systemDefault: return nil
        case .device(let uniqueID, _): return uniqueID
        }
    }

    public var displayName: String {
        switch self {
        case .systemDefault: return "System default"
        case .device(_, let name): return name
        }
    }
}

/// The microphones this machine offers, and what ScreenCaptureKit can do with them.
public enum MicrophoneInventory {
    /// Every audio input, in the order the discovery session reports them.
    ///
    /// `AVCaptureDevice.DiscoverySession` rather than `devices(for:)`, which is deprecated at
    /// macOS 10.15 — both comparable recorders still call the old one, and it is the kind of
    /// thing that survives in a shipping app precisely because it keeps working.
    ///
    /// **`.microphone` and `.external`**: a USB interface or a capture card is not a built-in
    /// microphone and would be missing from a built-in-only query, which is exactly the
    /// device a person recording a demo with real narration is using.
    public nonisolated static func available() -> [MicrophoneSource] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified)
        return session.devices.map { .device(uniqueID: $0.uniqueID, name: $0.localizedName) }
    }

    /// Whether ScreenCaptureKit on this system can capture a microphone into the stream.
    ///
    /// Probed rather than gated on an OS version: the two setters and the third output type
    /// are what the capture actually needs, and asking for them directly answers the question
    /// a version check only approximates. an Electron recorder probes the same three.
    ///
    /// **A `false` here is not an error.** It means system audio still records and the
    /// microphone does not, which the caller reports as blindness rather than a failure —
    /// the same shape as every other permission this module degrades through.
    public nonisolated static func captureIsSupported(
        by configuration: SCStreamConfiguration = SCStreamConfiguration()
    ) -> Bool {
        configuration.responds(to: Selector(("setCaptureMicrophone:")))
            && configuration.responds(to: Selector(("setMicrophoneCaptureDeviceID:")))
            && SCStreamOutputType(rawValue: microphoneOutputTypeRawValue) != nil
    }

    /// ScreenCaptureKit's microphone output type as a raw value. Named rather than written
    /// inline at the probe: it is the same constant `CaptureSession` registers an output for,
    /// and a probe that checked a different number from the one used would pass while the
    /// capture failed.
    public nonisolated static let microphoneOutputTypeRawValue = 2

    /// The selection to use when a project asks for one that is no longer present — a USB
    /// interface unplugged between recordings. Falls back rather than failing: a recording
    /// with the built-in microphone is a better answer than no recording, and the fallback is
    /// visible because `MicrophoneSource.displayName` will not be the name that was asked for.
    public nonisolated static func resolve(_ requested: MicrophoneSource) -> MicrophoneSource {
        guard case .device(let uniqueID, _) = requested else { return .systemDefault }
        let present = available().contains { $0.deviceID == uniqueID }
        return present ? requested : .systemDefault
    }
}
