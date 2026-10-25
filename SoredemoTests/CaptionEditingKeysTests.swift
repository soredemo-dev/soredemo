import AppKit
import Foundation
import Overlays
import Render
import Testing
import Timeline
@testable import Soredemo

/// The four things a person does to a transcript with the keyboard, and the model behind them.
///
/// All four were reported as broken from a real editing session: clicking a line selected the
/// whole line, ↑/↓ did nothing although the key legend advertised them, typing a space paused
/// the preview, and there was no undo at all. Three of those are AppKit behaviour reached
/// through an `NSViewRepresentable`; what is tested here is the DECISION each one rests on,
/// extracted so it can fail somewhere other than in a person's hands.

@MainActor private func track(_ cues: [(String, Int64, Int64)]) -> CaptionTrack {
    CaptionTrack(cues: cues.map {
        CaptionCue(text: $0.0, start: Nanoseconds($0.1), end: Nanoseconds($0.2))
    })
}

@MainActor private func model(_ cues: [(String, Int64, Int64)]) -> CaptionsModel {
    let model = CaptionsModel()
    model.restore(track: track(cues), style: CaptionStyle.presets[0].style, burnsIn: false)
    return model
}

// MARK: - the caret, after a key moves focus

/// **AppKit selects the whole value when a field becomes first responder, and that was the bug.**
/// Stepping into a line to fix a word is not stepping into it to replace it.
@Test @MainActor func focusingALinePutsTheCaretAtTheEndRatherThanSelectingIt() {
    let range = CaptionFieldCaret.range(afterFocusing: "hello there")
    #expect(range.length == 0, "a selection of \(range.length) is select-all coming back")
    #expect(range.location == 11)
}

/// `NSRange` counts UTF-16 units and `String.count` counts characters. For the END of a string
/// the two agree only if the arithmetic is done in the right one — an emoji is two UTF-16 units
/// and one character, so a caret placed at `count` lands mid-emoji.
@Test @MainActor func theCaretLandsPastTheLastCharacterEvenWhenItIsTwoUnitsWide() {
    let text = "ok 👍"
    let range = CaptionFieldCaret.range(afterFocusing: text)
    #expect(range.location == (text as NSString).length)
    #expect(range.location == 5, "\"\(text)\" is 5 UTF-16 units; \(text.count) characters")
    #expect(range.location != text.count, "counting characters would land inside the emoji")
}

@Test @MainActor func anEmptyLineTakesACaretAtZero() {
    #expect(CaptionFieldCaret.range(afterFocusing: "") == NSRange(location: 0, length: 0))
}

// MARK: - who owns the keyboard

/// **An `NSTextField` never becomes first responder; its field editor does.** A guard written
/// against `NSTextField` would never match, which is the same as no guard — so the type this
/// asks about is the one the window actually reports.
@Test @MainActor func anEditableFieldEditorHoldsTheKeyboard() {
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    editor.isEditable = true
    #expect(KeyboardFocus.isEditing(editor))
}

/// A selectable label is not somewhere text is going.
@Test @MainActor func aReadOnlyTextViewDoesNotHoldTheKeyboard() {
    let label = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    label.isEditable = false
    #expect(!KeyboardFocus.isEditing(label))
}

@Test @MainActor func nothingFocusedIsNotTyping() {
    #expect(!KeyboardFocus.isEditing(nil))
    #expect(!KeyboardFocus.isEditing(NSButton()))
}


// MARK: - undo

/// An undo stack with nothing of Foundation's in it.
///
/// **A plain object, because `UndoManager` cannot be used here** — see `UndoRecording`'s header
/// for the two failures that established that. This records what was registered and can run the
/// last step, which is the whole of what the model asks for.
@MainActor private final class Recorder: UndoRecording {
    private(set) var names: [String] = []
    private var steps: [@MainActor () -> Void] = []
    var canUndo: Bool { !steps.isEmpty }

    func register(_ name: String, undo: @escaping @MainActor () -> Void) {
        names.append(name)
        steps.append(undo)
    }

    /// Runs the most recent step. **The step is taken off first**, so a step that registers its
    /// own redo — which is how the model spells symmetry — lands on top rather than being
    /// popped off again by this call.
    func undo() {
        guard let step = steps.popLast() else { return }
        names.removeLast()
        step()
    }
}

@MainActor private func undoable(_ cues: [(String, Int64, Int64)])
-> (model: CaptionsModel, undo: Recorder) {
    let model = model(cues)
    let recorder = Recorder()
    model.undoRecorder = recorder
    return (model, recorder)
}

@Test @MainActor func aTextEditIsUndoneAndRedone() {
    let (model, undo) = undoable([("hello there", 0, 2_000_000_000)])
    model.setText("hello world", at: 0)
    #expect(model.track.cues[0].text == "hello world")

    undo.undo()
    #expect(model.track.cues[0].text == "hello there")

    // Symmetric by construction: undoing registered its own redo.
    #expect(undo.canUndo, "undo left nothing to redo")
    undo.undo()
    #expect(model.track.cues[0].text == "hello world")
}

/// **A whole run of typing is one step.** Registering per keystroke means ⌘Z walks back one
/// character at a time, which is not what undo means to anybody. This is the assertion that
/// fails if the coalescing is removed.
@Test @MainActor func typingIntoOneLineCollapsesIntoASingleStep() {
    let (model, undo) = undoable([("", 0, 2_000_000_000)])
    for text in ["h", "he", "hel", "hell", "hello"] { model.setText(text, at: 0) }
    #expect(model.track.cues[0].text == "hello")
    #expect(undo.names.count == 1, "five keystrokes registered \(undo.names.count) steps")

    undo.undo()
    #expect(model.track.cues[0].text == "", "one undo must take the whole run, not one letter")
}

/// The run ends when the caret leaves the line, or every correction in a session would collapse
/// into one step and ⌘Z would undo the lot.
@Test @MainActor func leavingTheLineEndsTheRun() {
    let (model, undo) = undoable([("", 0, 1_000_000_000)])
    // **Two keystrokes each side of the commit, not one.** With one, four keystrokes and two
    // steps are the same count whether the run coalesces or not, and the test cannot see the
    // difference it exists for — which is what the first version of it did.
    model.setText("a", at: 0)
    model.setText("ab", at: 0)
    model.endTypingRun()
    model.setText("abc", at: 0)
    model.setText("abcd", at: 0)
    #expect(undo.names.count == 2, "four keystrokes in two runs registered \(undo.names.count)")

    undo.undo()
    #expect(model.track.cues[0].text == "ab", "the second run did not stop at the commit")
}

/// Typing in a different cue starts a new step even without a commit, because the caret moved.
@Test @MainActor func typingInAnotherLineStartsANewStep() {
    let (model, undo) = undoable([("", 0, 1_000_000_000), ("", 1_000_000_000, 2_000_000_000)])
    // Two keystrokes per line, for `leavingTheLineEndsTheRun`'s reason.
    model.setText("a", at: 0)
    model.setText("ab", at: 0)
    model.setText("c", at: 1)
    model.setText("cd", at: 1)
    #expect(undo.names.count == 2, "two lines of typing registered \(undo.names.count) steps")

    undo.undo()
    #expect(model.track.cues[1].text == "", "the second line's run did not undo as one")
    #expect(model.track.cues[0].text == "ab", "the first line's edit was taken with it")
}

/// **An edit that changed nothing is not a step.** `setText` runs on every keystroke, including
/// the ones that retype the same character; a no-op on the stack is a ⌘Z that appears to do
/// nothing, which is how people stop trusting undo.
@Test @MainActor func anEditThatChangesNothingIsNotAStep() {
    let (model, undo) = undoable([("hello", 0, 1_000_000_000)])
    model.setText("hello", at: 0)
    #expect(!undo.canUndo)
}

/// Structural edits are undoable too, and each carries the name the Edit menu shows.
@Test @MainActor func splittingAndMergingAreUndoable() {
    let (model, undo) = undoable([("one two", 0, 2_000_000_000)])
    model.split(at: 0, atCharacter: 3)
    #expect(model.track.cues.count == 2)
    // **The localised name, not the English key.** These are Edit-menu wording and they
    // are translated into ten languages; asserting the literal made this test pass in
    // English and fail on a Mac set to anything else — which is the machine it first ran
    // on. What is being checked is that the step carries the SPLIT name, not which
    // language the machine is in.
    #expect(undo.names == [String(localized: "Split Caption")])

    undo.undo()
    #expect(model.track.cues.count == 1)
    #expect(model.track.cues[0].text == "one two")
}

@Test @MainActor func deletingALineIsUndoable() {
    let (model, undo) = undoable([("a", 0, 1_000_000_000), ("b", 1_000_000_000, 2_000_000_000)])
    model.remove(at: 0)
    #expect(model.track.cues.map(\.text) == ["b"])

    undo.undo()
    #expect(model.track.cues.map(\.text) == ["a", "b"], "a deleted caption is unrecoverable")
}

/// A model with no undo stack still edits. The stack is the host's to supply, and a panel shown
/// outside a window has none.
@Test @MainActor func editingWorksWithNoRecorderAttached() {
    let model = model([("a", 0, 1_000_000_000)])
    model.setText("b", at: 0)
    #expect(model.track.cues[0].text == "b")
}

// MARK: - the countdown

/// **What the countdown names is the application, never the window's title.** A title is the
/// contents of somebody's work — the document open, the message being read — and this panel is
/// on screen for three seconds before every recording and in every screenshot of this app.
@Test @MainActor func aWindowIsNamedByItsApplicationAndNotItsTitle() {
    // `SCWindow` cannot be constructed in a test, so the case that CAN be checked here is the
    // one with no application: it must fall back to a phrase, never to a title.
    #expect(!CountdownState(total: 3, subject: String(localized: "A window")).subject.isEmpty)
}

/// The count starts where it was told to. (The ring is a second's, not the whole count's, so
/// nothing divides by the total any more and it is not kept.)
@Test @MainActor func theCountStartsAtItsTotal() {
    let state = CountdownState(total: 5, subject: "Whole display")
    #expect(state.remaining == 5)
    #expect(state.ringRemaining == 1, "a second not yet begun has its whole ring")
}

/// **Nothing is cancelled until somebody cancels it.** The presenter reads this between slices
/// of its wait; a `true` here by default would mean no recording ever started.
@Test @MainActor func aFreshCountdownIsNotCancelled() {
    #expect(!CountdownState(total: 3, subject: "Whole display").isCancelled)
}

/// Zero seconds is "off", and off is not a cancellation: the recording starts immediately.
@Test @MainActor func turningTheCountdownOffIsNotCancelling() async {
    let finished = await CountdownPresenter.shared.run(seconds: 0, subject: "Whole display")
    #expect(finished, "a countdown of zero reported a cancellation")
}

// MARK: - the two edits that skipped the undo stack

/// **"Fix them too" is one step, and undoing it takes the name back as well.** It wrote the
/// track directly, so it could not be undone at all; and an undo that restored the lines but
/// left the corrected word in the names list would put the correction back on the next
/// Transcribe. `docs/design/2026-10-24-every-caption-edit-is-undoable.md`.
@Test @MainActor func fixingEverywhereIsOneStepThatTakesTheNameBackToo() throws {
    let (model, undo) = undoable([("open Sore Demo", 0, 1_000_000_000),
                                  ("Sore Demo records", 1_000_000_000, 2_000_000_000),
                                  ("and Sore Demo edits", 2_000_000_000, 3_000_000_000)])
    let edit = try #require(RunEdit(from: "open Sore Demo", to: "open Soredemo"))
    model.applyEverywhere(edit, correctedWord: "Soredemo")
    #expect(model.track.cues.map(\.text) == ["open Soredemo", "Soredemo records", "and Soredemo edits"])
    #expect(model.spokenTerms == ["Soredemo"])
    #expect(undo.names == [String(localized: "Fix Captions Everywhere")])

    undo.undo()
    #expect(model.track.cues.map(\.text) == ["open Sore Demo", "Sore Demo records", "and Sore Demo edits"])
    #expect(model.spokenTerms.isEmpty, "the name went in with the fix and goes out with its undo")

    undo.undo()
    #expect(model.track.cues[1].text == "Soredemo records", "and the redo puts both back")
    #expect(model.spokenTerms == ["Soredemo"])
}

/// **An import over corrected captions can be taken back.** It replaces the track by design;
/// before this it did so with no step, and the corrections it replaced were gone.
@Test @MainActor func importingSubtitlesIsUndoable() throws {
    let (model, undo) = undoable([("corrected by hand", 0, 1_000_000_000)])
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "soredemo-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "edited.srt")
    try "1\n00:00:00,500 --> 00:00:01,500\nfrom the file\n".write(to: file, atomically: true, encoding: .utf8)

    model.importSidecar(from: file, edit: nil)
    #expect(model.track.cues.map(\.text) == ["from the file"])
    #expect(undo.names == [String(localized: "Import Subtitles")])

    undo.undo()
    #expect(model.track.cues.map(\.text) == ["corrected by hand"])
}
