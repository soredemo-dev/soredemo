import AppKit
import Capture
import Compositing
import Foundation
import Overlays
import SwiftUI
import Timeline

/// The cue list: every caption, its measurements, and everything you can do to one.
///
/// **Its own view because the width belongs to whoever hosts it, not to the list.**
/// `InspectorWidth` records the measurement: a 42-character line at the body font is 263pt,
/// and with the timecode, the reading-speed column and the fault label a row needs about
/// 437pt. The inspector opens at 300. So for as long as this was only an inspector section,
/// the row this panel exists to edit was truncated by default — somebody had to know to drag
/// the panel wider before they could read the line they were being asked to fix, and a fault
/// label saying "too long" beside a line you cannot see is an accusation rather than a help.
///
/// Nothing here assumes a width. `CaptionsPanel` puts it in the inspector, where it is narrow
/// and honest about it; `CaptionEditor` gives it the room the measurement asks for.
struct CaptionLines: View {
    let model: CaptionsModel
    /// Rebuild whatever is drawing the captions — the preview, or the editor's own picture.
    let onChange: () -> Void
    /// Where the playhead is, in the RECORDING's own time — the same clock a cue is stamped in,
    /// so no conversion happens here.
    let playhead: Nanoseconds
    /// Move the playhead. **The list is a way of navigating the recording**, not a table of its
    /// contents: a caption is corrected at the pace of playback, and a row that cannot be
    /// listened to is a row somebody has to find in the scrubber first.
    let onSeek: (Nanoseconds) -> Void
    /// Where the RECORDING is silent, from the timeline's own detection.
    let pauses: [SilenceFinder.Span]

    /// Everything this list remembers, owned by whoever hosts it.
    ///
    /// **`@State` here was a defect, and the runtime said so out loud.** These rows are handed
    /// to the host's `List` from a value the host rebuilds on every redraw, so state declared
    /// here was never installed on anything: *"Accessing State's value outside of being
    /// installed on a View. This will result in a constant Binding of the initial value and
    /// will not update."* The search field could be typed in and would never filter; the caret
    /// could move and no row would know. That is what "the caption editing has so many bugs"
    /// was, and it arrived with the extraction that made this file.
    ///
    /// A reference type held by the host with `@State` is what survives the struct being thrown
    /// away — and sharing one deliberately is what makes the inspector and the caption editor
    /// agree about what is selected when both are showing the same recording.
    /// `@Bindable`, not `let`: the search field needs a two-way binding into the class, and a
    /// plain stored property has no `$`.
    @Bindable var state: CaptionListState
    /// Which row has the caret, as a binding from the host. Same reason: focus belongs to a live
    /// view hierarchy, not to a value rebuilt between redraws.
    @FocusState.Binding var focused: Int?

    /// The rows alone, for a host that supplies its own `List` and sections.
    @ViewBuilder var rows: some View {
        listControls
        ForEach(visibleCues, id: \.index) { entry in
            row(index: entry.index, cue: entry.cue).id(entry.index)
        }
        if visibleCues.isEmpty, !state.search.isEmpty {
            Text("No caption contains that.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    /// The list as a whole, for a host that has room for nothing else.
    var body: some View {
        ScrollViewReader { scroller in
            List { rows }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom) { offerBar }
                .onChange(of: focused) { previous, current in
                    if let previous, previous != current {
                        noteCorrection(at: previous)
                        onChange()
                    }
                    if let current, current < model.track.cues.count {
                        state.textOnFocus = (current, model.track.cues[current].text)
                    }
                }
                .onChange(of: currentIndex) {
                    guard let currentIndex, focused == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        scroller.scrollTo(currentIndex, anchor: .center)
                    }
                }
        }
    }

    /// The index of the cue the playhead is inside, or `nil` between cues.
    private var currentIndex: Int? {
        model.track.cues.firstIndex { $0.contains(playhead) }
    }

    /// The cues the search allows through, each with its index into the unfiltered track — which
    /// is what every edit below addresses, so filtering can never retime the wrong line.
    private var visibleCues: [(index: Int, cue: CaptionCue)] {
        let needle = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.track.cues.enumerated()
            .filter { needle.isEmpty || $0.element.text.lowercased().contains(needle) }
            .map { (index: $0.offset, cue: $0.element) }
    }

    /// A field over the list, and the two keys that move between cues.
    ///
    /// **⌥↑ and ⌥↓ rather than bare arrows**, which belong to the list itself, and rather than
    /// Space, `i`, `o` or `s`, which the timeline has already taken. Hidden buttons because
    /// `keyboardShortcut` has to hang on a live view and these are keys rather than controls.
    @ViewBuilder private var listControls: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the captions", text: $state.search)
                .textFieldStyle(.plain)
            if !state.search.isEmpty {
                Text(verbatim: "\(visibleCues.count)/\(model.track.cues.count)")
                    .font(Type.readout).foregroundStyle(.secondary)
                Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
            }
        }
        .font(Type.label)

        Button("Previous caption") { jump(by: -1) }
            .keyboardShortcut(.upArrow, modifiers: [.option])
            .hidden().frame(height: 0)
        Button("Next caption") { jump(by: 1) }
            .keyboardShortcut(.downArrow, modifiers: [.option])
            .hidden().frame(height: 0)
    }

    /// Moves the playhead to the cue before or after wherever it is.
    ///
    /// **Measured from the playhead, not from a selection**, so the keys do the same thing
    /// whether or not a row was clicked. Which cue a step lands on — including from a gap
    /// between two of them, which is most of a recording — is `CaptionTrack`'s decision, where
    /// it can be tested.
    private func jump(by delta: Int) {
        guard let target = model.track.index(steppingFrom: playhead, by: delta) else { return }
        onSeek(model.track.cues[target].start)
        focused = target
    }

    /// **Every row is a live field, and Return goes to the next one.**
    ///
    /// Correcting a transcript is one continuous pass, not a series of little transactions. The
    /// version before this made each cue modal — tap the TEXT to open a field, tap Save to
    /// close, and tap somewhere else in the row for the timing controls — so fixing ten lines
    /// cost thirty gestures and which one you got depended on hitting text or not hitting text,
    /// which is a mode nothing on screen announced.
    ///
    /// Now: the field is always there, typing edits, Return commits and moves to the next cue
    /// AND seeks to it, so the line you are fixing is the line you are hearing.
    ///
    /// **The model is written on every keystroke and the preview is rebuilt only on commit.**
    /// Writing is an array copy and a static assignment, which a playing preview picks up on its
    /// next frame; `onChange` reloads the composition, and doing that per character would make
    /// typing unusable.
    @ViewBuilder private func row(index: Int, cue: CaptionCue) -> some View {
        let isCurrent = currentIndex == index
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Space.snug) {
                // The timecode seeks. A person who wants to HEAR a line before changing it
                // should not have to put the caret in it first.
                Button {
                    onSeek(cue.start)
                } label: {
                    Text(timecode(cue.start))
                        .font(Type.readout)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.primary)
                                                   : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play from this caption")

                CaptionField(
                    text: Binding(
                        get: { index < model.track.cues.count ? model.track.cues[index].text : "" },
                        set: { model.setText($0, at: index) }),
                    onSplit: { offset in
                        noteCorrection(at: index)
                        model.split(at: index, atCharacter: offset)
                        onChange()
                        focused = index + 1
                    },
                    onMergeWithPrevious: {
                        guard index > 0 else { return }
                        noteCorrection(at: index)
                        model.merge(at: index - 1)
                        onChange()
                        focused = index - 1
                    },
                    onStep: { step(from: index, by: $0) },
                    onCommit: { noteCorrection(at: index); onChange() },
                    isFocused: focused == index)
                    .focused($focused, equals: index)
                    .frame(height: 20)

                measurement(of: cue)
            }
            if focused == index {
                reading(of: cue)
                uncertainty(of: cue)
                timingControls(index: index, cue: cue)
            }
        }
        .padding(.vertical, Space.hairline)
        .listRowBackground(isCurrent
            ? AnyView(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                .fill(.quaternary))
            : AnyView(Color.clear))
    }

    /// The offer to apply one correction to the rest of the recording.
    ///
    /// **It says the number.** "Fix everywhere" with no count is a button whose effect is
    /// discovered afterwards; with one it is a decision. Dismissable, and it goes away by itself
    /// the moment another line is edited, because an offer about a line somebody has moved on
    /// from is in the way.
    @ViewBuilder private var offerBar: some View {
        if let offer = state.offer {
            HStack(spacing: Space.snug) {
                Image(systemName: "wand.and.sparkles").foregroundStyle(.secondary)
                Text("The same change fits \(offer.others) other line(s).")
                    .font(Type.detail)
                Spacer()
                Button("Fix them too") {
                    model.applyEverywhere(offer.edit, correctedWord: offer.word)
                    state.offer = nil
                    onChange()
                }
                Button { state.offer = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss this suggestion")
            }
            .padding(Space.snug)
            .background(.thinMaterial)
        }
    }

    /// Commits what was typed and moves on. **Seeks as well as focuses**, so a pass down the
    /// list plays the recording as it goes and a person hears the line they are about to read.
    ///
    /// At the last cue it commits and leaves the field rather than wrapping: a wrap would put
    /// somebody back at the top of a recording they had just finished checking.
    private func step(from index: Int, by delta: Int) {
        let next = index + delta
        guard next >= 0, next < model.track.cues.count else { focused = nil; return }
        onSeek(model.track.cues[next].start)
        focused = next
    }

    /// **The reason correcting a transcript is hard is not one line — it is the same word forty
    /// times.** A demo says a product's name forty times and the recogniser gets it wrong forty
    /// times, and fixing that by hand is what makes people give up on automatic captions.
    ///
    /// So a commit that changed ONE contiguous run of text, in a line whose run appears
    /// elsewhere, becomes an offer with the count on it. Offered rather than done: a silent
    /// sweep across a transcript is a change nobody reviewed, and the count is what lets
    /// somebody predict what pressing it will do.
    private func noteCorrection(at index: Int) {
        defer { state.textOnFocus = nil }
        guard let before = state.textOnFocus, before.index == index,
              index < model.track.cues.count else { return }
        let after = model.track.cues[index].text
        guard let edit = RunEdit(from: before.text, to: after) else { return }
        let others = model.track.cuesContaining(edit.was, excluding: index)
        guard others > 0 else { return }
        // The whole word the run sits in is what gets remembered for next time — a term list of
        // three-letter fragments would match things nobody meant.
        let word = after.split(whereSeparator: \.isWhitespace)
            .first { $0.contains(edit.now) }.map(String.init)
        state.offer = (edit, others, word ?? edit.now)
    }

    /// A cue's own numbers, and the verdict when there is one.
    ///
    /// **The fault is a word, not a colour alone.** A red number tells somebody a line is wrong
    /// without telling them what to do, and the three faults have three different fixes — see
    /// `CaptionFault`. The reading speed is shown whatever the verdict, because the number is
    /// what a person adjusts against.
    /// **On a row: the fault if there is one, and the width. Nothing else.**
    ///
    /// The full reading is 59pt of a row that has 437pt to give a 42-character line, a timecode
    /// and a fault label — measured, and it is why the inspector's maximum moved. A count is
    /// about 20 and says the thing a person scans a column for; the seconds and the rate belong
    /// to the cue being looked at, and they are on its own line below.
    @ViewBuilder private func measurement(of cue: CaptionCue) -> some View {
        let reading = cue.measurement
        HStack(spacing: Space.tight) {
            if let fault = reading.fault {
                Text(LocalizedStringKey(fault.displayName))
                    .font(Type.detail)
                    .foregroundStyle(Signal.record)
            }
            Text(verbatim: "\(reading.charactersToRead)")
                .font(Type.readout)
                .foregroundStyle(.secondary)
        }
    }

    /// The whole reading, for the cue the caret is in: how long it is on screen, how much there
    /// is to read, and how fast that is.
    @ViewBuilder private func reading(of cue: CaptionCue) -> some View {
        let reading = cue.measurement
        Text(verbatim: String(format: "%.2fs · %d · %.1f/s", reading.seconds, reading.charactersToRead,
                              reading.charactersPerSecond.isFinite
                                  ? reading.charactersPerSecond : 0))
            .font(Type.readout)
            .foregroundStyle(.secondary)
    }

    /// The word the recogniser was least sure of, for the cue being looked at.
    ///
    /// **Shown here and nowhere else, which is the whole design.** The measurement says
    /// confidence finds a mangled word — a name heard wrong scored 0.46, the lowest of its cue —
    /// and also that on clean speech most low scores are sentence-initial words that were
    /// recognised correctly. Marking cues by it would mark 8% of them and be wrong about most,
    /// which is how people learn to ignore a marker. In one row, for one cue, it is a place to
    /// look rather than an alarm.
    @ViewBuilder private func uncertainty(of cue: CaptionCue) -> some View {
        if let weakest = cue.leastCertainWord, let confidence = weakest.confidence {
            HStack(spacing: Space.tight) {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text("Least sure of")
                Text(verbatim: "\u{201C}\(weakest.text)\u{201D}").fontWeight(.medium)
                Text(verbatim: String(format: "%.0f%%", confidence * 100))
                    .foregroundStyle(.secondary)
            }
            .font(Type.detail)
        }
    }

    /// Start and end, nudged. **A hundred milliseconds**, which is about three frames: a step
    /// small enough that two of them are a fine adjustment and large enough that a person is not
    /// pressing it thirty times. `CaptionTrack.retiming` clamps, so holding a button at the end
    /// of the room available stops rather than corrupting the neighbour.
    @ViewBuilder private func timingControls(index: Int, cue: CaptionCue) -> some View {
        HStack(spacing: Space.tight) {
            nudge("arrow.left.to.line", "Start earlier") {
                model.retime(at: index, start: shifted(cue.start, by: -Self.nudge.rawValue), end: cue.end)
            }
            nudge("arrow.right.to.line", "Start later") {
                model.retime(at: index, start: shifted(cue.start, by: Self.nudge.rawValue), end: cue.end)
            }
            Divider().frame(height: 12)
            nudge("arrow.left", "End earlier") {
                model.retime(at: index, start: cue.start, end: shifted(cue.end, by: -Self.nudge.rawValue))
            }
            nudge("arrow.right", "End later") {
                model.retime(at: index, start: cue.start, end: shifted(cue.end, by: Self.nudge.rawValue))
            }
            Divider().frame(height: 12)
            // **Both ends at once, because that is the intention.** "Line this up with what was
            // said" is one decision, and a start that snapped while the end did not would leave
            // the cue describing half of something. Disabled when neither end has anywhere
            // better to be, so the control never does nothing quietly.
            nudge("wand.and.rays", "Line up with the speech") {
                model.snap(at: index, to: pauses)
            }
            .disabled(!model.track.canSnap(at: index, to: pauses))
            Spacer()
            nudge("trash", "Delete this line") {
                model.remove(at: index)
                focused = nil
            }
        }
        .font(Type.detail)
    }

    private static let nudge = Nanoseconds(100_000_000)

    private func shifted(_ time: Nanoseconds, by delta: Int64) -> Nanoseconds {
        Nanoseconds(max(0, time.rawValue + delta))
    }

    @ViewBuilder private func nudge(_ symbol: String, _ label: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: { action(); onChange() }) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(LocalizedStringKey(label))
            .accessibilityLabel(LocalizedStringKey(label))
    }

    /// `m:ss.t` — a caption list is scanned for WHERE something was said, and hours of leading
    /// zeroes on every row is noise in a column a person reads down.
    private func timecode(_ time: Nanoseconds) -> String {
        let tenths = max(0, time.rawValue) / 100_000_000
        return "\(tenths / 600):" + String(format: "%02d.%01d", (tenths / 10) % 60, tenths % 10)
    }
}

/// What a cue list remembers between redraws.
///
/// **A class, because the list is a value that gets thrown away.** `CaptionLines` is handed to a
/// host's `List` as rows; SwiftUI rebuilds that struct constantly, and `@State` inside it is
/// never installed, so every binding is a constant of its initial value. The runtime reports
/// exactly that, and the symptom is a search field that filters nothing.
///
/// Held by the host with `@State`, so the host's identity is what keeps it alive.
@Observable
final class CaptionListState {
    /// What the list is filtered to. **A filter, not a jump-to-match**: on a long recording the
    /// question is "where did I say that", and the answer is every line that says it.
    var search = ""
    /// What the focused row said before anybody typed in it, so a commit can tell what changed.
    var textOnFocus: (index: Int, text: String)?
    /// A correction worth offering to apply everywhere, with how many other lines it reaches.
    var offer: (edit: RunEdit, others: Int, word: String)?
}
