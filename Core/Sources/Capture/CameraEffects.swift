import AVFoundation
import Foundation

/// The camera and microphone effects macOS applies for every app, and the way in to them.
///
/// **An app cannot turn these on. That is deliberate and it is Apple's decision, not an
/// oversight.** `portraitEffectEnabled`, `studioLightEnabled`, `backgroundReplacementEnabled`
/// and `reactionEffectsEnabled` are all `readonly` class properties: they report what the person
/// chose in Control Center and nothing else. Only Center Stage can be taken over, by setting
/// `centerStageControlMode` to `.app` — which greys the control out for the person using the
/// Mac, and is the wrong thing for a recorder to do to somebody's camera.
///
/// **So the supported way in is the system's own panel**, which is what
/// `showSystemUserInterface` opens — the same one that drops out of the green camera item in the
/// menu bar. The effects apply to the camera stream every client receives, so what a person
/// turns on there is what lands in the recording; there is no second copy of it to keep in sync.
///
/// The microphone panel is worth as much: Voice Isolation is the noise removal this project has
/// on its list, done by the system, on the input, before anything is written.
public enum CameraEffects {
    /// Opens the system's video effects panel — Portrait, Studio Light, Centre Stage,
    /// Reactions, Background.
    public nonisolated static func showVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    /// Opens the system's microphone mode panel — Standard, Voice Isolation, Wide Spectrum.
    public nonisolated static func showMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    /// One effect the system is currently applying.
    ///
    /// The English name is the value, because it is also the key the app's strings table is
    /// written against — the same arrangement `MicrophoneSource.displayName` uses.
    public enum Effect: String, Sendable, CaseIterable {
        case portrait = "Portrait"
        case studioLight = "Studio Light"
        case centerStage = "Center Stage"
        case reactions = "Reactions"
        case background = "Background"
    }

    /// What is switched on right now, in the order the system's own panel lists them.
    ///
    /// Read rather than cached: these change from a panel this app does not own, and a
    /// remembered answer would be wrong the moment somebody used it.
    public nonisolated static func active() -> [Effect] {
        var on: [Effect] = []
        if AVCaptureDevice.isPortraitEffectEnabled { on.append(.portrait) }
        if AVCaptureDevice.isStudioLightEnabled { on.append(.studioLight) }
        if AVCaptureDevice.isCenterStageEnabled { on.append(.centerStage) }
        if AVCaptureDevice.reactionEffectsEnabled { on.append(.reactions) }
        if AVCaptureDevice.isBackgroundReplacementEnabled { on.append(.background) }
        return on
    }
}
