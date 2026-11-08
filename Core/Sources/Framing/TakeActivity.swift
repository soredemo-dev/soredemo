import Project
import Timeline

/// Everything that happened in one take, as a cut producer is allowed to see it.
///
/// **Plain values, gathered by the caller**: the steps, the pointer, the buttons and the
/// shortcuts come from the observation log; `speech` from the transcript, converted to the host
/// clock by whoever holds both; `unobserved` from the log's secure-input intervals and any span
/// the tap was off. This module depends on none of the readers that produce them.
///
/// **Every instant is in the recording's boot epoch, or the take is refused** — comparing host
/// instants across boots is a programming error (`HostInstant.<` traps), and a producer handed
/// one would be measuring against a different clock.
public struct TakeActivity: Sendable {
    public enum Refusal: Error, Equatable {
        /// An instant of this kind came from another boot than the recording's.
        case fromAnotherBoot(String)
    }

    public let recording: HostRange
    public let steps: [RecordedStep]
    public let pointer: [PointerSample]
    public let buttons: [ButtonEvent]
    public let shortcuts: [KeySample]
    public let speech: [HostRange]
    public let unobserved: [HostRange]

    public init(recording: HostRange, steps: [RecordedStep], pointer: [PointerSample],
                buttons: [ButtonEvent], shortcuts: [KeySample], speech: [HostRange],
                unobserved: [HostRange]) throws(Refusal) {
        let epoch = recording.epoch
        if steps.contains(where: { $0.origin.epoch != epoch || $0.end.epoch != epoch }) { throw .fromAnotherBoot("step") }
        if pointer.contains(where: { $0.instant.epoch != epoch }) { throw .fromAnotherBoot("pointer") }
        if buttons.contains(where: { $0.instant.epoch != epoch }) { throw .fromAnotherBoot("button") }
        if shortcuts.contains(where: { $0.instant.epoch != epoch }) { throw .fromAnotherBoot("shortcut") }
        if speech.contains(where: { $0.epoch != epoch }) { throw .fromAnotherBoot("speech") }
        if unobserved.contains(where: { $0.epoch != epoch }) { throw .fromAnotherBoot("unobserved") }
        self.recording = recording
        self.steps = steps
        self.pointer = pointer
        self.buttons = buttons
        self.shortcuts = shortcuts
        self.speech = speech
        self.unobserved = unobserved
    }
}
