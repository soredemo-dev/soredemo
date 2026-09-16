import AppKit
import SwiftUI

/// Takes the editor's unmodified keys, and only when nothing is being typed.
///
/// **A view that overrides `performKeyEquivalent:`, not zero-opacity `Button`s and not an
/// `NSEvent` monitor.** Three shapes, and the reasons the first two are not here:
///
/// - The `Button`s were what the editor had, under a comment saying a `Button`'s shortcut "is
///   the only thing that respects the responder chain". Driven with synthesised events against
///   a caption field that had the caret, all six of them were taken and none reached the field.
/// - `NSEvent.addLocalMonitorForEvents` cannot be written in a Swift 6 target: its callback is
///   `@Sendable` and `NSEvent`'s `Sendable` conformance is marked unavailable in the SDK, so
///   the event cannot cross into the closure. `@preconcurrency import` does not lift it.
///
/// `performKeyEquivalent:` is the pass AppKit makes down the content view hierarchy BEFORE it
/// sends `keyDown:` to the first responder — the same pass a `Button`'s shortcut rides. The
/// difference is that this one can ask, and answer `false` so the key carries on to the field.
///
/// The decision itself is `BareKeys`, which is pure and tested. This is the shell.
final class BareKeyView: NSView {
    /// What to run. Set by the representable; `nil` until then, which answers no key.
    var perform: ((BareKeys.Action) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = BareKeys.Modifiers(
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control))
        // **Asked at the moment the key arrives, which is the only moment the answer exists.**
        // A guard on the ACTION — which is what `unlessTyping` was — stops the playhead moving
        // and still swallows the key, so the caret does not move either. That is the half of
        // this defect that reads as "the arrow keys sometimes stop working".
        // **`keyCode`, never the event's text.** `noAppSourceReadsKeystrokeText` bans every
        // route from an event to characters in this target, and the first version of this line
        // read `charactersIgnoringModifiers` — the gate caught it. A key's POSITION is what the
        // rest of this app matches shortcuts on; see `BareKeys.Code` for what that costs on a
        // layout that is not ANSI.
        guard let action = BareKeys.action(
            keyCode: Int(event.keyCode),
            modifiers: modifiers,
            isTyping: KeyboardFocus.aTextFieldIsEditing)
        else { return false }
        perform?(action)
        return true
    }
}

/// Puts a `BareKeyView` in the editor's view hierarchy for as long as the timeline is on screen.
struct BareKeyHandling: NSViewRepresentable {
    let perform: (BareKeys.Action) -> Void

    func makeNSView(context: Context) -> BareKeyView {
        let view = BareKeyView()
        view.perform = perform
        return view
    }

    func updateNSView(_ view: BareKeyView, context: Context) {
        // Re-assigned on every update, because the closure captures the timeline's current
        // duration and model: one captured at `makeNSView` would answer keys against the
        // recording that was open when the editor first appeared.
        view.perform = perform
    }
}

extension View {
    /// The editor's unmodified keys, answered only when nothing is being typed.
    ///
    /// Zero-sized and hidden from accessibility: it is a place in the responder chain, not a
    /// control. Placed in the background so it takes no space and no hit test.
    func bareKeys(_ perform: @escaping (BareKeys.Action) -> Void) -> some View {
        background {
            BareKeyHandling(perform: perform)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
