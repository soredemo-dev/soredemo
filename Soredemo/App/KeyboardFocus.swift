import AppKit
import SwiftUI

/// Whether the keyboard currently belongs to a text field.
///
/// **A shortcut with no modifier is a key somebody is also trying to type.** The timeline binds
/// bare `←`, `→` and `S`; the caption list is a column of live text fields. AppKit offers a key
/// event to `performKeyEquivalent:` down the view hierarchy *before* it sends `keyDown:` to the
/// first responder, so a bare-key shortcut can be taken before the field editor ever sees it.
/// Whether SwiftUI's `.keyboardShortcut` exempts an editing text field is not documented either
/// way, and `TimelineEditor.playheadKeys` used to carry a comment asserting that it does — an
/// assertion with no measurement behind it. This is the measurement's replacement: ask, and let
/// the field win.
///
/// **Not an exemption for every shortcut.** ⌘Z, ⌘S and the rest keep working while typing,
/// because a modifier is what tells the two apart. Only the bare keys defer.
enum KeyboardFocus {
    /// Whether the key window's first responder is a text field with the caret in it.
    @MainActor static var aTextFieldIsEditing: Bool {
        isEditing(NSApp.keyWindow?.firstResponder)
    }

    /// The decision, taken apart from the window so it can be tested.
    ///
    /// **`NSTextView`, because that is what a first responder in a text field IS.** An
    /// `NSTextField` never becomes first responder itself: it hands the window a shared *field
    /// editor* — an `NSTextView` whose `isFieldEditor` is true — and that is what the window
    /// reports. Checking for `NSTextField` here would be a check that never matches, which is
    /// the same as no check at all.
    ///
    /// A non-editable `NSTextView` is a label that happens to be selectable, and a key typed at
    /// one is not text going anywhere; it does not hold the keyboard.
    static func isEditing(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSTextView else { return false }
        return view.isEditable
    }
}

/// Runs `action` unless a text field has the keyboard.
///
/// Free function rather than a method, so it reads the same at a `Button`'s call site whatever
/// the surrounding type is.
@MainActor func unlessTyping(_ action: @escaping () -> Void) -> () -> Void {
    { if !KeyboardFocus.aTextFieldIsEditing { action() } }
}
