import AVFoundation
import Foundation
import ScreenCaptureKit
import Testing
@testable import Capture

/// **Internal and external audio are two captures with two failure modes**, and the recorder
/// used to acknowledge one. It set `captureMicrophone = true` unconditionally, named no
/// device, and had no answer for a system that cannot capture one. System audio is a tap on
/// what the machine plays and either works or is denied; a microphone can be absent, chosen
/// wrongly, muted at the OS, or held by another application.
///
/// Every comparable recorder names the device. `a Swift recorder` does not use ScreenCaptureKit for
/// the microphone at all, on the stated grounds that "SCK does not support microphone device
/// selection" — measured on this machine that is no longer true, which is why this stays one
/// capture rather than a second `AVCaptureSession`.
@Suite struct MicrophoneSourceTests {
    @Test func theSystemDefaultNamesNoDevice() {
        #expect(MicrophoneSource.systemDefault.deviceID == nil,
                "a named device would pin the recording to it and stop following System Settings")
        #expect(MicrophoneSource.systemDefault.displayName == "System default")
    }

    @Test func aChosenDeviceCarriesItsNameAsWellAsItsID() {
        let source = MicrophoneSource.device(uniqueID: "BuiltInMicrophoneDevice",
                                             name: "MacBook Pro Microphone")
        #expect(source.deviceID == "BuiltInMicrophoneDevice")
        // The name travels so a project can say what it recorded from after the device is gone.
        #expect(source.displayName == "MacBook Pro Microphone")
    }

    /// **The probe asks for the three things the capture actually needs**, rather than for an
    /// OS version that only approximates them. Measured on this machine: both setters respond
    /// and output type 2 exists.
    @Test func theCapabilityProbeChecksWhatTheCaptureUses() {
        let configuration = SCStreamConfiguration()
        let supported = MicrophoneInventory.captureIsSupported(by: configuration)
        // Both selectors are what `CaptureSession` sets; the probe must agree with reality
        // rather than with a version table.
        let setters = configuration.responds(to: Selector(("setCaptureMicrophone:")))
            && configuration.responds(to: Selector(("setMicrophoneCaptureDeviceID:")))
        #expect(supported == (setters
                              && SCStreamOutputType(rawValue: MicrophoneInventory
                                  .microphoneOutputTypeRawValue) != nil))
    }

    /// The probe's constant must be the SAME one the session registers an output for. A probe
    /// that checked a different number would pass while the capture produced nothing.
    @Test func theProbedOutputTypeIsTheOneTheStreamRegisters() {
        #expect(MicrophoneInventory.microphoneOutputTypeRawValue == 2)
        #expect(SCStreamOutputType(rawValue: MicrophoneInventory.microphoneOutputTypeRawValue)
                == SCStreamOutputType.microphone)
    }

    /// **A device that is gone falls back rather than failing.** A USB interface unplugged
    /// between recordings should not stop the next one; the fallback is visible because the
    /// resolved source no longer carries the name that was asked for.
    @Test func aMissingDeviceFallsBackToTheSystemDefault() {
        let absent = MicrophoneSource.device(uniqueID: "no-such-device-\(UUID().uuidString)",
                                             name: "Unplugged Interface")
        #expect(MicrophoneInventory.resolve(absent) == .systemDefault)
    }

    /// A device that IS present is kept exactly, name included.
    @Test func aPresentDeviceIsResolvedToItself() throws {
        let available = MicrophoneInventory.available()
        let first = try #require(available.first,
                                 "no audio input on this machine — this case cannot be checked")
        #expect(MicrophoneInventory.resolve(first) == first)
    }

    /// Enumeration includes EXTERNAL inputs, not only built-in ones: a USB interface is
    /// exactly the device a person recording real narration is using, and a built-in-only
    /// query would omit it.
    @Test func enumerationCoversExternalInputsAndNamesEveryOne() {
        let sources = MicrophoneInventory.available()
        for source in sources {
            #expect(source.deviceID?.isEmpty == false, "a device was enumerated without an ID")
            #expect(!source.displayName.isEmpty, "a device was enumerated without a name")
        }
        // Against the discovery session directly, so the mapping cannot silently drop one.
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        #expect(sources.count == session.devices.count)
    }

    /// The resolution of `.systemDefault` is itself — it names nothing, so there is nothing
    /// to find missing.
    @Test func theSystemDefaultAlwaysResolvesToItself() {
        #expect(MicrophoneInventory.resolve(.systemDefault) == .systemDefault)
    }
}
