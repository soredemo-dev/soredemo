import AppKit
import SwiftUI

/// A caption's text, with the four keys a subtitle editor is actually driven by.
///
/// **`NSTextField` rather than SwiftUI's, because the caret is the argument to two of them.**
/// Return splits a cue AT THE CARET and Backspace merges with the previous cue only WHEN THE
/// CARET IS AT THE START — and SwiftUI's `TextField` publishes neither its selection nor a way
/// to see a key before the field consumes it. The alternative was to keep split and merge as
/// buttons, which is what this replaced.
///
/// The keymap is not invented here. Two shipping subtitle tools read as references
/// (`docs/design/what-a-caption-editor-is.md`) use exactly this one, and it is the keymap of
/// every text editor: Return makes a new line, Backspace at the start of a line joins it to the
/// one above, Tab moves on.
///
/// | key | what it does |
/// |---|---|
/// | Return, caret inside the text | split into two cues there |
/// | Return, caret at either end | move to the next cue |
/// | Backspace, caret at 0, nothing selected | merge into the previous cue |
/// | Tab / Shift-Tab | next cue / previous cue |
///
/// Return at an END is a move rather than a split because a split there would make an empty
/// cue, and `CaptionTrack.splitting` refuses those — a key that silently does nothing is worse
/// than one that does the obvious thing.
struct CaptionField: NSViewRepresentable {
    @Binding var text: String
    /// Split this cue at a character offset into its text.
    let onSplit: (Int) -> Void
    /// Join this cue into the one before it.
    let onMergeWithPrevious: () -> Void
    /// Move on, by one cue in either direction.
    let onStep: (Int) -> Void
    /// The text is finished with — a rebuild of the preview is worth paying for now.
    let onCommit: () -> Void
    /// Whether this row should hold the caret.
    ///
    /// **Driven explicitly rather than through `@FocusState` alone.** Whether SwiftUI's focus
    /// reaches an `NSViewRepresentable`'s first responder is undocumented, and every key below
    /// depends on the caret actually being in this field. Making it first responder here is
    /// deterministic; the `.focused` modifier stays on the call site so the rest of the panel
    /// still knows which row is live.
    let isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = .preferredFont(forTextStyle: .body)
        // A caption is one line here; `CaptionBuilder` breaks the lines and a newline typed into
        // this field would be a second line nothing downstream expects.
        field.usesSingleLineMode = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // **Only when it actually differs.** Assigning `stringValue` moves the caret to the end,
        // so writing back the value this field just produced would jump the caret on every
        // keystroke.
        if field.stringValue != text { field.stringValue = text }

        guard let window = field.window else { return }
        let holdsCaret = window.firstResponder === field.currentEditor()
            && field.currentEditor() != nil
        if isFocused, !holdsCaret {
            // Deferred: `updateNSView` can run inside a layout pass, and changing the first
            // responder there is a change to the hierarchy while it is being read.
            DispatchQueue.main.async { window.makeFirstResponder(field) }
        } else if !isFocused, holdsCaret {
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaptionField

        init(_ parent: CaptionField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onCommit()
        }

        /// Where the caret is, in CHARACTERS of the text — not in UTF-16 units, which is what
        /// AppKit reports. The difference is every emoji and every combining mark, and a split
        /// offset counted in the wrong unit lands mid-character.
        private func caret(in field: NSTextField) -> (offset: Int, hasSelection: Bool)? {
            guard let editor = field.currentEditor() else { return nil }
            let range = editor.selectedRange
            let utf16 = field.stringValue.utf16
            guard let index = utf16.index(utf16.startIndex, offsetBy: range.location,
                                          limitedBy: utf16.endIndex),
                  let scalarIndex = index.samePosition(in: field.stringValue)
            else { return nil }
            return (field.stringValue.distance(from: field.stringValue.startIndex,
                                               to: scalarIndex),
                    range.length > 0)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = field.stringValue
                guard let caret = caret(in: field), !caret.hasSelection,
                      caret.offset > 0, caret.offset < field.stringValue.count else {
                    parent.onCommit()
                    parent.onStep(1)
                    return true
                }
                parent.onSplit(caret.offset)
                return true

            case #selector(NSResponder.deleteBackward(_:)):
                // Only at the very start, and only with nothing selected. Anywhere else this is
                // an ordinary delete and must stay one, or a person cannot correct a typo.
                guard let caret = caret(in: field), caret.offset == 0, !caret.hasSelection
                else { return false }
                parent.text = field.stringValue
                parent.onMergeWithPrevious()
                return true

            case #selector(NSResponder.insertTab(_:)):
                parent.onCommit()
                parent.onStep(1)
                return true

            case #selector(NSResponder.insertBacktab(_:)):
                parent.onCommit()
                parent.onStep(-1)
                return true

            default:
                return false
            }
        }
    }
}
