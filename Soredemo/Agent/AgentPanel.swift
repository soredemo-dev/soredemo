import Framing
import Overlays
import Surface
import SwiftUI
import Timeline

/// The agent's column: the person's own Claude Code, editing the open recording while they watch.
///
/// **Laid out the way the chat surfaces people already know are**: the person's words in a bubble
/// on the right, the agent's in full width on the left; what it is doing now as one shimmering
/// line with a seconds count; its tool calls gathered into one quiet group that opens on a click;
/// every edit drawn as an edit card; and one control under each turn that takes the whole turn back.
/// The composer holds the model and the send button, as a chat composer does. Standard SwiftUI
/// chrome, the app's own ink and paper (D7). See the design document's "The agent panel".
struct AgentPanel: View {
    let model: AgentPanelModel
    let editor: EditorViewModel
    @State private var draft = ""
    @State private var revertNote: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Line.hairline)
            ScrollView {
                AgentTranscript(model: model, editor: editor, draft: $draft, revertNote: $revertNote)
                    .padding(.horizontal, Space.roomy)
                    .padding(.vertical, Space.roomy)
            }
            // Pinned to the newest line while it grows, and left alone when the person scrolls up
            // to read — the sticky-bottom behaviour every chat has.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            NotesBar(notes: editor.notes, timeline: editor.timeline, agentName: model.providerName,
                     canAddress: !model.isRunning && model.availability != .checking) {
                draft = String(localized: "Address my open notes.")
                send()
            }
            AgentComposer(model: model, editor: editor, draft: $draft, onSend: send)
        }
        .background(Theme.Surface.panel)
        .task { if case .checking = model.availability { await model.checkAvailability() } }
    }

    private var header: some View {
        HStack(spacing: Space.snug) {
            AgentMark(mark: model.providerMark, isTemplate: model.providerMarkIsTemplate, running: model.isRunning)
            Menu {
                Picker("Agent", selection: Binding(get: { model.providerIndex }, set: { model.choose($0) })) {
                    ForEach(model.choices) { choice in
                        Label { Text(verbatim: choice.name) } icon: { Image(choice.mark) }.tag(choice.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Space.tight) {
                        Text(verbatim: model.providerName).font(Type.label.weight(.semibold))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.Ink.tertiary)
                    }
                    Text(statusText).font(Type.detail).foregroundStyle(Theme.Ink.tertiary)
                }
                .foregroundStyle(Theme.Ink.primary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isRunning)
            .help("Which agent this panel drives. Switching starts a new conversation; cuts already made stay.")
            Spacer()
            Button {
                model.startOver()
                revertNote = nil
            } label: {
                Image(systemName: "square.and.pencil").font(Type.barIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Ink.secondary)
            .disabled(model.isRunning || model.turns.isEmpty)
            .help("New conversation. Cuts already made stay.")
        }
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.snug + 2)
    }

    private var statusText: LocalizedStringKey {
        switch model.availability {
        case .checking: "Looking for \(model.providerName)…"
        case .ready(let version): model.isRunning ? "Working · \(model.elapsed)s" : "Ready · \(version)"
        case .notInstalled: "Not found on this Mac"
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        revertNote = nil
        withAnimation(.snappy) {
            model.send(text, editor: editor, context: AgentContextReader.context(of: editor))
        }
    }
}

/// The agent's mark beside its name, breathing while it works.
private struct AgentMark: View {
    let mark: String
    /// A one-colour mark is drawn in the text colour, so it reads on both themes.
    let isTemplate: Bool
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        // The agent's own mark, so the person sees whose agent this is (see
        // docs/third-party-marks.md for where it came from and what it is used for).
        Image(mark)
            .renderingMode(isTemplate ? .template : .original)
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
            .foregroundStyle(Theme.Ink.primary)
            .scaleEffect(running && breathe && !reduceMotion ? 1.08 : 1)
            .animation(running && !reduceMotion ? .easeInOut(duration: 0.9).repeatForever() : .default, value: breathe)
            .onAppear { breathe = true }
            .accessibilityHidden(true)
    }
}

// MARK: - the transcript

/// The conversation itself: the empty state, then each turn. **Its own view, apart from the
/// panel's chrome**, so it lays out the same wherever it is drawn.
struct AgentTranscript: View {
    let model: AgentPanelModel
    let editor: EditorViewModel
    @Binding var draft: String
    @Binding var revertNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            if model.turns.isEmpty { AgentWelcome(model: model, draft: $draft) }
            ForEach(model.turns) { turn in
                TurnView(turn: turn, model: model, editor: editor, revertNote: $revertNote,
                         isLast: turn.id == model.turns.last?.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: model.turns.count)
    }
}

/// Before the first message: what it is, what it can and cannot do, and three ways to start.
private struct AgentWelcome: View {
    let model: AgentPanelModel
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.regular) {
            switch model.availability {
            case .notInstalled:
                Text("\(model.providerName) isn't installed on this Mac.").font(Type.heading)
                Text("Install it, sign in once in Terminal, then check again. Soredemo uses your own login and holds no key.")
                    .font(Type.label).foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check again") { Task { await model.checkAvailability() } }
            default:
                Text("Edit with \(model.providerName)").font(.title3.weight(.semibold))
                Text("It runs on this Mac under your own login and can read this recording's steps, cut its timeline and fix its captions while you watch. Every edit is one undo step, and a whole turn reverts at once. It cannot publish anything.")
                    .font(Type.label).foregroundStyle(Theme.Ink.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Space.snug) {
                    suggestion("Tighten the pauses between steps", icon: "scissors")
                    suggestion("Cut this to about 45 seconds", icon: "timer")
                    suggestion("Which steps could go, and why?", icon: "list.bullet")
                    suggestion("Fix the names the captions misheard", icon: "captions.bubble")
                }
                .padding(.top, Space.tight)
            }
        }
        .padding(.top, Space.section)
    }

    private func suggestion(_ text: LocalizedStringResource, icon: String) -> some View {
        Button {
            draft = String(localized: text)
        } label: {
            HStack(spacing: Space.snug) {
                Image(systemName: icon).font(Type.barIcon).foregroundStyle(Theme.Ink.tertiary).frame(width: 16)
                Text(text).font(Type.label).foregroundStyle(Theme.Ink.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.regular).padding(.vertical, Space.snug + 2)
            .background(Theme.Fill.rest, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Line.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HoverLift())
        .disabled(model.availability == .checking)
    }
}

/// One turn: the request, what happened, and how it ended.
private struct TurnView: View {
    let turn: AgentPanelModel.Turn
    let model: AgentPanelModel
    let editor: EditorViewModel
    @Binding var revertNote: String?
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.regular) {
            HStack {
                Spacer(minLength: Space.section * 2)
                Text(verbatim: turn.request).font(Type.label)
                    .lineSpacing(2)
                    .padding(.horizontal, Space.regular).padding(.vertical, Space.snug + 1)
                    .background(Theme.Fill.hover, in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
            }
            ForEach(blocks) { block in
                switch block.content {
                case .tools(let tools): ActivityGroup(tools: tools, running: turn.running && block.id == blocks.last?.id)
                case .item(let item): itemView(item)
                }
            }
            .transition(.opacity)
            // The live line only when no tool row is already saying what is happening — one
            // indicator of "now", never two.
            if turn.running, !Self.isUsingATool(model.activity) { LiveStatus(activity: model.activity, agent: model.providerName) }
            if let failure = turn.failure {
                Label { Text(verbatim: failure).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(Type.detail).foregroundStyle(Theme.Ink.caution)
            }
            if !turn.running { footer }
        }
        .animation(.snappy(duration: 0.25), value: turn.items)
    }

    @ViewBuilder private func itemView(_ item: AgentPanelModel.Item) -> some View {
        switch item {
        case .text(_, let text):
            // Verbatim: the agent's own words. Plain text, because `AgentPrompt.systemPrompt`
            // asks for no Markdown.
            Text(verbatim: text).font(Type.label).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .thinking(_, let text, let done):
            ThinkingBlock(text: text, done: done)
        case .edit(let record):
            // Only to a moment that still plays: one a later cut removed has nothing to show.
            EditCard(record: record) {
                if editor.timeline.edit.outputTime(atSource: record.at) != nil { editor.timeline.movePlayhead(to: record.at) }
            }
        case .note(let note):
            NoteCard(note: note)
        case .tool:
            EmptyView()
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: Space.snug) {
            if !turn.edits.isEmpty {
                Button {
                    withAnimation(.snappy) { revertNote = model.revert(turn, editor: editor) }
                } label: {
                    Label("Revert this turn (\(turn.edits.count))", systemImage: "arrow.uturn.backward")
                        .font(Type.detail)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Ink.secondary)
                .help("Undo every edit this turn made")
            }
            Spacer()
            if let seconds = turn.seconds {
                Text("Done in \(EditorToolbar.seconds(Nanoseconds(Int64(seconds * 1_000_000_000))))")
                    .font(Type.readout).foregroundStyle(Theme.Ink.tertiary)
            }
        }
        if let revertNote, isLast {
            Text(verbatim: revertNote).font(Type.detail).foregroundStyle(Theme.Ink.caution)
        }
    }

    private static func isUsingATool(_ activity: AgentPanelModel.Activity?) -> Bool {
        if case .tool? = activity { true } else { false }
    }

    /// Consecutive tool calls folded into one group, the way a long turn stays readable.
    private var blocks: [Block] {
        var blocks: [Block] = []
        for item in turn.items {
            if case .tool = item {
                if case .tools(let tools)? = blocks.last?.content {
                    blocks[blocks.count - 1] = Block(id: blocks[blocks.count - 1].id, content: .tools(tools + [item]))
                } else {
                    blocks.append(Block(id: item.id, content: .tools([item])))
                }
            } else {
                blocks.append(Block(id: item.id, content: .item(item)))
            }
        }
        return blocks
    }

    private struct Block: Identifiable {
        enum Content { case tools([AgentPanelModel.Item]), item(AgentPanelModel.Item) }
        let id: String
        let content: Content
    }
}

// MARK: - what the agent is doing

/// The running turn's live line while it thinks or writes: what it is doing now, shimmering.
private struct LiveStatus: View {
    let activity: AgentPanelModel.Activity?
    let agent: String

    var body: some View {
        HStack(spacing: Space.snug) {
            PulseDot()
            Shimmer { Text(phrase).font(Type.label) }
        }
        .accessibilityElement(children: .combine)
    }

    private var phrase: LocalizedStringKey { AgentPhrase.activity(activity, agent: agent) }
}

/// The reasoning, shown while the model thinks and folded to one line when it is done.
private struct ThinkingBlock: View {
    let text: String
    let done: Bool
    @State private var open = false

    private var label: LocalizedStringKey { done ? "Thought it through" : "Thinking" }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: Space.tight) {
                    Image(systemName: "brain").font(Type.barIcon)
                    Text(label).font(Type.detail)
                    if done {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .foregroundStyle(Theme.Ink.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!done)
            if !done || open {
                Text(verbatim: text).font(Type.detail).foregroundStyle(Theme.Ink.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Space.snug)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.Line.divider).frame(width: 2) }
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
    }
}

/// A run of tool calls: one line while it works or when it is a single call, a folded group of
/// steps otherwise — opening to every step, each with its own state.
private struct ActivityGroup: View {
    let tools: [AgentPanelModel.Item]
    let running: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight + 2) {
            if tools.count > 1 && !running {
                Button {
                    withAnimation(.snappy) { open.toggle() }
                } label: {
                    HStack(spacing: Space.tight) {
                        Image(systemName: "wrench.and.screwdriver").font(Type.barIcon)
                        Text("Used \(tools.count) tools").font(Type.detail)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .foregroundStyle(Theme.Ink.tertiary)
                }
                .buttonStyle(.plain)
            }
            if tools.count == 1 || running || open {
                ForEach(tools) { tool in
                    if case .tool(_, let name, let input, let state, let output) = tool {
                        ToolStep(name: name, input: input, state: state, output: output)
                    }
                }
                .padding(.leading, tools.count > 1 && !running ? Space.snug : 0)
            }
        }
    }
}

/// One tool call: a state dot, what it did, and — on a click — what was asked and answered.
private struct ToolStep: View {
    let name: String
    let input: String?
    let state: AgentPanelModel.ToolState
    let output: String?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: Space.snug) {
                    switch state {
                    case .running: PulseDot()
                    case .done: Circle().fill(Theme.Ink.tertiary.opacity(0.5)).frame(width: 5, height: 5)
                    case .failed: Circle().fill(Theme.Ink.caution).frame(width: 5, height: 5)
                    }
                    if state == .running {
                        Shimmer { Text(AgentPhrase.present(name)).font(Type.detail) }
                    } else {
                        Text(AgentPhrase.past(name)).font(Type.detail)
                            .foregroundStyle(state == .failed ? Theme.Ink.caution : Theme.Ink.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(input == nil && output == nil)
            if open {
                VStack(alignment: .leading, spacing: Space.tight) {
                    if let input, input != "{}" { Text(verbatim: input).font(Type.readout) }
                    if let output { Text(verbatim: String(output.prefix(800))).font(Type.readout).foregroundStyle(Theme.Ink.tertiary) }
                }
                .textSelection(.enabled)
                .padding(Space.snug)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Fill.rest, in: RoundedRectangle(cornerRadius: Radius.panel))
                .transition(.opacity)
            }
        }
    }
}

/// One edit the agent made — a cut and what it removed, or the caption lines it fixed — why, and
/// a jump to where it is.
private struct EditCard: View {
    let record: AgentEditRecord
    let onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(alignment: .top, spacing: Space.regular) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Ink.onAccent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    title.font(Type.label.weight(.semibold))
                    Text(verbatim: record.reason).font(Type.detail).foregroundStyle(Theme.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle").font(Type.barIcon).foregroundStyle(Theme.Ink.tertiary)
            }
            .padding(Space.regular)
            .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Line.divider))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(HoverLift())
        .help(help)
    }

    private var title: Text {
        switch record.kind {
        case .cut(let removed): Text("Cut \(EditorToolbar.seconds(removed))")
        case .caption(let lines, _, _) where lines.count == 1: Text("Fixed caption line \(lines[0])")
        case .caption(let lines, _, _): Text("Fixed \(lines.count) caption lines")
        case .look(let changed, _, _) where changed.count == 1: Text("Changed \(changed[0])")
        case .look(let changed, _, _): Text("Changed \(changed.count) settings")
        }
    }

    private var help: Text {
        switch record.kind {
        case .cut: Text("Move the playhead to where this cut is")
        case .caption: Text("Move the playhead to the first line this changed")
        case .look: Text("Move the playhead to where this was changed")
        }
    }

    private var icon: String {
        switch record.kind {
        case .cut: "scissors"
        case .caption: "captions.bubble"
        case .look: "paintbrush"
        }
    }
}

/// A note the agent addressed or left open, with what it said — the answer beside the question.
private struct NoteCard: View {
    let note: PinnedNote

    var body: some View {
        HStack(alignment: .top, spacing: Space.regular) {
            Image(systemName: addressed ? "checkmark.circle.fill" : "pin.slash")
                .font(.system(size: 14))
                .foregroundStyle(addressed ? Theme.Ink.primary : Theme.Ink.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(heading).font(Type.detail.weight(.semibold))
                Text(verbatim: "“\(note.text)”").font(Type.detail).foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: how).font(Type.detail).foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.regular)
        .background(Theme.Fill.rest, in: RoundedRectangle(cornerRadius: 12))
    }

    private var addressed: Bool { if case .addressed = note.state { true } else { false } }

    private var heading: LocalizedStringKey { addressed ? "Addressed your note" : "Left your note open" }

    private var how: String {
        switch note.state {
        case .addressed(let text), .skipped(let text): text
        case .open: ""
        }
    }
}

/// The notes pinned on this recording, above the message box: how many are open, the list, and
/// the one button that hands them to the agent.
private struct NotesBar: View {
    let notes: NotesModel
    let timeline: TimelineEditorModel
    let agentName: String
    let canAddress: Bool
    let onAddress: () -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            if notes.board.notes.isEmpty {
                Button {
                    notes.isPlacing = true
                } label: {
                    Label("Pin a note on the preview (N)", systemImage: "pin")
                        .font(Type.detail)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Ink.tertiary)
                .help("Press N, click where something should change, and write what. Then ask \(agentName) to address your notes.")
            } else {
                HStack(spacing: Space.snug) {
                    Button {
                        withAnimation(.snappy) { open.toggle() }
                    } label: {
                        HStack(spacing: Space.tight) {
                            Image(systemName: "pin.fill").font(Type.barIcon)
                            Text("Open notes: \(notes.open.count)").font(Type.detail.weight(.semibold))
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                        .foregroundStyle(Theme.Ink.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        notes.isPlacing = true
                    } label: {
                        Image(systemName: "plus").font(Type.barIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Ink.secondary)
                    .help("Pin another note (N)")
                    Button("Address them", action: onAddress)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Theme.accent)
                        .disabled(!canAddress || notes.open.isEmpty)
                        .help("Ask \(agentName) to make the change each open note asks for")
                }
                if open {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        ForEach(Array(notes.board.notes.enumerated()), id: \.element.id) { index, note in
                            NoteRow(note: note, number: index + 1, notes: notes, timeline: timeline)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, Space.roomy)
        .padding(.top, Space.snug)
    }
}

/// One note in the list: its number, words, time and state; a click shows the moment.
private struct NoteRow: View {
    let note: PinnedNote
    let number: Int
    let notes: NotesModel
    let timeline: TimelineEditorModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.snug) {
            Text(verbatim: "\(number)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.Ink.onAccent)
                .frame(width: 18, height: 18)
                .background(note.isOpen ? Theme.accent : Theme.Ink.tertiary, in: Circle())
            Button {
                let at = SourceTime(note.at)
                if timeline.edit.outputTime(atSource: at) != nil { timeline.movePlayhead(to: at) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: note.text).font(Type.detail)
                        .foregroundStyle(note.isOpen ? Theme.Ink.primary : Theme.Ink.tertiary)
                        .strikethrough(!note.isOpen, color: Theme.Ink.tertiary)
                        .lineLimit(2)
                    Text(verbatim: ChapterList.timestamp(note.at, withHours: false))
                        .font(Type.readout).foregroundStyle(Theme.Ink.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Move the playhead to this note")
            if note.isOpen {
                Button { notes.remove(note.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.Ink.tertiary)
                    .help("Delete this note")
            } else {
                Button { notes.reopen(note.id) } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.Ink.tertiary)
                    .help("Reopen this note")
            }
        }
    }
}

// MARK: - the composer

/// The message box: the words, what is on screen, the model, and send or stop.
private struct AgentComposer: View {
    let model: AgentPanelModel
    let editor: EditorViewModel
    @Binding var draft: String
    let onSend: () -> Void
    @FocusState private var focused: Bool

    private var isReady: Bool { if case .ready = model.availability { true } else { false } }
    private var canSend: Bool { isReady && !model.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            VStack(alignment: .leading, spacing: Space.snug) {
                TextField("Ask \(model.providerName) to edit this recording…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Type.label)
                    .lineLimit(1...8)
                    .focused($focused)
                    .disabled(!isReady)
                    .onSubmit { if canSend { onSend() } }
                HStack(spacing: Space.snug) {
                    ContextChip(model: model, editor: editor)
                    Spacer(minLength: Space.tight)
                    Menu {
                        Picker("Model", selection: Binding(get: { model.model ?? "" }, set: { model.model = $0.isEmpty ? nil : $0 })) {
                            Text("Your default").tag("")
                            ForEach(model.models, id: \.id) { choice in
                                Text(verbatim: choice.label).tag(choice.id)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(verbatim: modelName).font(Type.detail)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.isRunning)
                    .help("Which model your \(model.providerName) uses for this panel")
                    sendButton
                }
            }
            .padding(Space.regular)
            .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? Theme.Ink.tertiary : Theme.Line.divider))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            AgentUsageStrip(model: model)
        }
        .padding(.horizontal, Space.regular)
        .padding(.bottom, Space.regular)
        .padding(.top, Space.tight)
    }

    private var modelName: String {
        model.models.first { $0.id == model.model }?.label ?? String(localized: "Your default")
    }

    @ViewBuilder private var sendButton: some View {
        if model.isRunning {
            Button(action: model.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Ink.onAccent)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop. Cuts already made stay, and the turn can be reverted.")
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canSend ? Theme.Ink.onAccent : Theme.Ink.tertiary)
                    .frame(width: 28, height: 28)
                    .background(canSend ? Theme.accent : Theme.Fill.hover, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
        }
    }
}

/// What is on screen, as it goes with the next message. **Its own view, so only it redraws as the
/// playhead moves** — the panel around it does not follow the playhead at all.
private struct ContextChip: View {
    let model: AgentPanelModel
    let editor: EditorViewModel

    var body: some View {
        if let context = AgentContextReader.context(of: editor) {
            Button {
                model.includesContext.toggle()
            } label: {
                HStack(spacing: Space.tight) {
                    Image(systemName: model.includesContext ? "scope" : "eye.slash").font(.system(size: 10))
                    if model.includesContext {
                        Text(verbatim: AgentContextReader.summary(of: context)).lineLimit(1)
                    } else {
                        Text("Not sending what is on screen").lineLimit(1)
                    }
                }
                .font(Type.detail)
                .foregroundStyle(model.includesContext ? Theme.Ink.secondary : Theme.Ink.tertiary)
                .padding(.horizontal, Space.snug).padding(.vertical, 3)
                .background(Theme.Fill.rest, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("What goes with your message: the playhead and its step. Click to leave it out.")
        }
    }
}

// MARK: - small pieces

/// A dot that breathes while something runs. Still when motion is reduced.
struct PulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle().fill(Theme.Ink.primary)
            .frame(width: 6, height: 6)
            .opacity(dim && !reduceMotion ? 0.25 : 0.9)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(), value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// Text with a band of light passing across it — the cue every agent surface uses for "working
/// on this now". Plain tertiary ink when motion is reduced.
struct Shimmer<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = -0.6

    var body: some View {
        content
            .foregroundStyle(Theme.Ink.tertiary)
            .overlay {
                if !reduceMotion {
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: Theme.Ink.primary, location: 0.5),
                                           .init(color: .clear, location: 1)],
                                   startPoint: UnitPoint(x: phase, y: 0.5),
                                   endPoint: UnitPoint(x: phase + 0.6, y: 0.5))
                        .mask(content)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.0 }
            }
    }
}

/// A button that brightens under the pointer — the hover a chat suggestion and a card share.
struct HoverLift: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLiftBody(configuration: configuration)
    }

    private struct HoverLiftBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .opacity(enabled ? 1 : 0.5)
                .brightness(hovering && enabled ? 0.03 : 0)
                .scaleEffect(configuration.isPressed ? 0.99 : 1)
                .animation(.snappy(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// What is on screen, as the agent is told it.
@MainActor
enum AgentContextReader {
    static func context(of editor: EditorViewModel) -> AgentPrompt.Context? {
        guard let duration = editor.timeline.duration, let anchor = editor.steps.anchor else { return nil }
        return context(playhead: editor.timeline.playhead, steps: editor.steps.steps, anchor: anchor,
                       duration: duration, plays: editor.timeline.edit.outputDuration)
    }

    /// **Everything here is on the recording's clock** — the playhead already is
    /// (`TimelineEditorModel.playhead`), and so are the steps, so nothing is converted.
    static func context(playhead: SourceTime, steps: [RecordedStep], anchor: EpochAnchor,
                        duration: Nanoseconds, plays: Nanoseconds) -> AgentPrompt.Context {
        let at = playhead.rawValue
        let step = steps.last { $0.origin.hostTime.rawValue - anchor.hostTime.rawValue <= at }
        return AgentPrompt.Context(playheadNanos: at, step: step.map { ($0.number, $0.label) },
                                   selectedProposal: nil, recordingNanos: duration.rawValue,
                                   playsNanos: plays.rawValue)
    }

    static func summary(of context: AgentPrompt.Context) -> String {
        let at = ChapterList.timestamp(Nanoseconds(context.playheadNanos), withHours: false)
        guard let step = context.step else { return at }
        return String(localized: "\(at) · step \(step.number) “\(step.label)”")
    }
}

/// What the agent is doing or did, in words — **one table for the panel and the preview pill**,
/// so the two cannot describe one tool call differently.
enum AgentPhrase {
    static func activity(_ activity: AgentPanelModel.Activity?, agent: String) -> LocalizedStringKey {
        switch activity {
        case .tool(let name)?: present(name)
        case .writing?: "Writing"
        case .thinking?: "Thinking"
        case .starting?, nil: "Starting \(agent)"
        }
    }

    /// What it is doing, while it does it.
    static func present(_ name: String) -> LocalizedStringKey {
        switch name {
        case AgentTools.status: "Reading the recording"
        case AgentTools.steps: "Reading the steps"
        case AgentTools.proposeCut: "Looking for pauses to cut"
        case AgentTools.cutSpan, AgentTools.cutStep, AgentTools.acceptProposal: "Cutting"
        case AgentTools.seek: "Moving the playhead"
        case AgentTools.undoLastAgentEdit: "Undoing its last cut"
        default: "Using \(name)"
        }
    }

    /// What it did, once done.
    static func past(_ name: String) -> LocalizedStringKey {
        switch name {
        case AgentTools.status: "Read the recording's status"
        case AgentTools.steps: "Read the steps"
        case AgentTools.proposeCut: "Read the proposed cuts"
        case AgentTools.cutSpan: "Cut a span"
        case AgentTools.cutStep: "Cut a step"
        case AgentTools.acceptProposal: "Accepted a proposed cut"
        case AgentTools.seek: "Moved the playhead"
        case AgentTools.undoLastAgentEdit: "Undid its last cut"
        default: "Used \(name)"
        }
    }
}
