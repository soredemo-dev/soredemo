import AVFoundation
import Capture
import CoreAudio

/// Whether what the Mac plays will be picked up by the microphone recording the take.
///
/// **Only a hint, and only when it is true.** With the built-in microphone and the built-in
/// speakers, the demo's own audio reaches the take twice. The notch says so and suggests
/// headphones — not muting: whether system audio is captured before or after the output volume is
/// unmeasured, and if after, muting would silence that track too.
///
/// The decision is pure over what Core Audio reported; the two reads are at the bottom. Measured
/// on a MacBook Pro, macOS 27, 2026-09-28: speakers `bltn`/`ispk`, microphone `bltn`. Headphones
/// were not measured, so anything unread is `.unknown` and gets no hint. `ARCHITECTURE.md` D6b.
nonisolated enum AudioRoute {
    enum Output: Equatable { case builtInSpeakers, other, unknown }
    enum Input: Equatable { case builtIn, other, unknown }

    private static let builtIn = fourCC("bltn")
    private static let internalSpeaker = fourCC("ispk")

    /// The built-in transport AND the internal speaker as its source. A built-in device with no
    /// readable source is `unknown`, not speakers: it might be the headphone jack.
    static func output(transport: UInt32?, dataSource: UInt32?) -> Output {
        guard let transport else { return .unknown }
        guard transport == builtIn else { return .other }
        guard let dataSource else { return .unknown }
        return dataSource == internalSpeaker ? .builtInSpeakers : .other
    }

    static func input(transport: UInt32?) -> Input {
        guard let transport else { return .unknown }
        return transport == builtIn ? .builtIn : .other
    }

    static func speakersReachTheMicrophone(input: Input, output: Output) -> Bool {
        input == .builtIn && output == .builtInSpeakers
    }

    /// Reads this Mac's current route for `microphone`. `false` for `.off` — nothing is listening.
    static func speakersReachTheMicrophone(for microphone: MicrophoneSource) -> Bool {
        let transport: UInt32?
        switch microphone {
        case .off:
            return false
        case .systemDefault:
            transport = defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap {
                property($0, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
            }
        case .device(let uniqueID, _):
            transport = AVCaptureDevice(uniqueID: uniqueID).map { UInt32(bitPattern: $0.transportType) }
        }
        let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        return speakersReachTheMicrophone(
            input: input(transport: transport),
            output: Self.output(
                transport: output.flatMap {
                    property($0, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
                },
                dataSource: output.flatMap {
                    property($0, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
                }))
    }

    // MARK: - Core Audio

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        let device: AudioObjectID? = property(AudioObjectID(kAudioObjectSystemObject), selector,
                                              kAudioObjectPropertyScopeGlobal)
        return device == kAudioObjectUnknown ? nil : device
    }

    /// One fixed-size property, or `nil` when the object does not have it — which is an answer
    /// (`.unknown`), never a zero.
    private static func property<Value: FixedWidthInteger>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = Value.zero
        var size = UInt32(MemoryLayout<Value>.size)
        let status = unsafe AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
