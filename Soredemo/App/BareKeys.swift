/// What an unmodified key means in the editor, and when it means nothing.
///
/// **A `Button`'s `.keyboardShortcut` does not respect the responder chain, and the comment in
/// `TimelineEditor` that said it does was never measured.** Driven with synthesised events
/// against a SwiftUI `TextField` that had the caret, every bare key the editor binds — `←`,
/// `→`, `Delete`, `s`, `i`, `o` — was taken by the shortcut and never reached the field. So a
/// caption could not take the letter `s`, its caret could not be moved, and backspace deleted
/// nothing. `unlessTyping` did not fix that: it stopped the ACTION, so the key did nothing at
/// all instead of the wrong thing, which is the half of the defect that reads as "the arrow
/// keys sometimes stop working".
///
/// **The mapping is here, pure, and the monitor is a shell around it.** Deciding at the moment
/// the key arrives is the whole repair — it is the only moment the answer is knowable — and a
/// decision made inside an `NSEvent` handler is a decision no test can reach.
struct BareKeys {
    /// The modifier keys, as the decision needs them.
    struct Modifiers: Equatable {
        let command: Bool
        let shift: Bool
        let option: Bool
        let control: Bool

        init(command: Bool = false, shift: Bool = false,
             option: Bool = false, control: Bool = false) {
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
        }

        static let none = Modifiers()
        /// Anything that is not shift. **Shift is not a modifier here**: ⇧← is the editor's
        /// coarse nudge and it is also a text field's extend-selection, so it belongs to the
        /// same decision as the bare arrow rather than being handed straight to SwiftUI.
        var beyondShift: Bool { command || option || control }
    }

    /// What the editor does with a key. `RawRepresentable` so a test can assert that no two
    /// share a spelling.
    enum Action: String, Equatable, CaseIterable, Hashable {
        case nudgeLeft, nudgeRight, coarseLeft, coarseRight
        case split, deleteClip, markIn, markOut
        /// Play or pause. **Not the timeline's** — the player lives with the transport bar, which
        /// is why a handler says which actions it answers.
        case togglePlay
        /// Pin a note on the preview: the next click there places it. The preview's, not the
        /// timeline's.
        case pinNote
    }

    /// The keys, as Carbon's layout-independent `kVK_*` POSITIONS.
    ///
    /// **Key codes, because reading what a key spells is banned in this app and the ban is
    /// absolute.** `noAppSourceReadsKeystrokeText` refuses `.charactersIgnoringModifiers`
    /// everywhere in the app target — the first version of this file used it and the gate
    /// caught it — and the rule's own words are that nothing here may learn what was typed
    /// *including in order to discard it*, because a value that existed can be logged. Key
    /// codes and modifier flags are what stays legal; it is the same table `InputObserver`
    /// matches its approved shortcuts on, for the same reason.
    ///
    /// **What that costs, stated rather than discovered.** A `kVK_ANSI_*` constant is a
    /// POSITION on the keyboard, not a letter. On a Dvorak or AZERTY layout the key this calls
    /// "split" is not the one labelled S. Every other editor's unmodified `S`, `I` and `O` are
    /// positions too — the shortcut is the place your finger goes — and this app already pays
    /// the same price for ⌘C through `approvedShortcuts`. It is a real cost and it buys the
    /// stronger claim: an app that cannot name the API cannot read the text by another route.
    enum Code: Int, CaseIterable {
        case leftArrow = 123
        case rightArrow = 124
        /// The key above Return. `kVK_Delete`, which macOS calls delete and everyone else
        /// calls backspace. **Not `kVK_ForwardDelete` (117)**, which this does not bind:
        /// deleting a clip with it would be a destructive act on a key nobody aimed here.
        case backspace = 51
        case s = 1
        case i = 34
        case o = 31
        /// **Space, and it is the key this whole mechanism was most needed for.** It was a
        /// `.keyboardShortcut(.space)` on the play button with the typing guard inside the
        /// button's ACTION — so a caption field with the caret made the button dead to the
        /// MOUSE as well, and pressing play after editing a line did nothing. Guarding an
        /// action cannot distinguish a key from a click; declining a key can.
        case space = 49
        /// `kVK_ANSI_N`: N for note, as a POSITION — see above.
        case n = 45
    }

    /// What to do with a key, or `nil` for "this is not ours".
    ///
    /// **`isTyping` refuses everything, including the shift pairs.** A text field's own uses
    /// for these keys are the whole point: ⇧← extends a selection, backspace removes a
    /// character, the `s` position is a letter somebody is spelling a word with. Returning
    /// `nil` is what lets the event carry on down to the field.
    static func action(keyCode: Int, modifiers: Modifiers, isTyping: Bool) -> Action? {
        guard !isTyping, !modifiers.beyondShift, let code = Code(rawValue: keyCode) else {
            return nil
        }
        switch code {
        case .leftArrow: return modifiers.shift ? .coarseLeft : .nudgeLeft
        case .rightArrow: return modifiers.shift ? .coarseRight : .nudgeRight
        // Shift does not change what the letters and backspace mean, and binding ⇧S to split
        // as well would take a key a text field wants for its own.
        case .backspace: return modifiers.shift ? nil : .deleteClip
        case .s: return modifiers.shift ? nil : .split
        case .i: return modifiers.shift ? nil : .markIn
        case .o: return modifiers.shift ? nil : .markOut
        case .space: return modifiers.shift ? nil : .togglePlay
        case .n: return modifiers.shift ? nil : .pinNote
        }
    }
}
