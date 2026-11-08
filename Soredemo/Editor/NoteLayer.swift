import Framing
import SwiftUI
import Timeline

/// Notes on the preview: placing one with a click while N is on, writing it where it was pinned,
/// and drawing the pins the playhead is near.
///
/// **A point on the picture as it plays**, the output frame: what the person was looking at when
/// they wrote it. The time is the playhead's position on the recording's clock, so the note stays
/// on the moment it was about when cuts move everything after it.
struct NoteLayer: View {
    let notes: NotesModel
    let timeline: TimelineEditorModel
    let outputWidth: Int
    let outputHeight: Int

    var body: some View {
        GeometryReader { geometry in
            let video = PreviewOverlay.videoRect(in: geometry.size.width, geometry.size.height,
                                                 outputWidth: outputWidth, outputHeight: outputHeight)
            ZStack(alignment: .topLeading) {
                AtPlayhead(model: timeline) { playhead in
                    let source = timeline.edit.sourceTime(atOutput: playhead) ?? Nanoseconds(0)
                    ForEach(notes.board.near(source, within: NotesModel.visibleWithin)) { note in
                        if let x = note.x, let y = note.y {
                            NotePin(note: note, number: number(of: note))
                                .position(x: video.x + x * video.width, y: video.y + y * video.height)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                if notes.isPlacing {
                    placing(video)
                }
                if let draft = notes.draft {
                    NoteComposer(notes: notes)
                        .frame(width: 260)
                        .position(x: clamp(video.x + draft.x * video.width + 130 + 12, 130, geometry.size.width - 130),
                                  y: clamp(video.y + draft.y * video.height, 60, geometry.size.height - 60))
                        .transition(.opacity)
                }
            }
            .animation(.snappy, value: notes.board)
            .animation(.snappy, value: notes.draft)
        }
    }

    /// While N is on: the whole picture takes the click, with a hint saying what it will do.
    private func placing(_ video: (x: Double, y: Double, width: Double, height: Double)) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.black.opacity(0.15))
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let x = (location.x - video.x) / video.width
                    let y = (location.y - video.y) / video.height
                    guard (0...1).contains(x), (0...1).contains(y) else { return }
                    let at = timeline.edit.sourceTime(atOutput: timeline.playhead) ?? Nanoseconds(0)
                    notes.begin(at: at, x: x, y: y)
                }
            Text("Click where the note goes. Esc to cancel.")
                .font(Type.detail.weight(.semibold))
                .padding(.horizontal, Space.regular).padding(.vertical, Space.tight + 2)
                .background(Theme.Surface.raised, in: Capsule())
                .padding(.top, Space.regular)
                .allowsHitTesting(false)
        }
        .onExitCommand { notes.cancel() }
    }

    /// Notes are numbered by time, the way a person refers to them: "note 2".
    private func number(of note: PinnedNote) -> Int {
        (notes.board.notes.firstIndex { $0.id == note.id } ?? 0) + 1
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), max(low, high))
    }
}

/// One pin: a numbered disc, ink while open and faded once addressed, with its words on hover.
private struct NotePin: View {
    let note: PinnedNote
    let number: Int
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .leading) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.Ink.onAccent)
                .frame(width: 22, height: 22)
                .background(note.isOpen ? Theme.accent : Theme.Ink.tertiary, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            if hovering {
                Text(verbatim: note.text)
                    .font(Type.detail)
                    .lineLimit(3)
                    .frame(maxWidth: 220, alignment: .leading)
                    .padding(Space.snug)
                    .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: Radius.panel))
                    .offset(x: 28)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}

/// The note being written, beside where it was pinned.
private struct NoteComposer: View {
    let notes: NotesModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            TextField("What should change here?", text: Binding(
                get: { notes.draft?.text ?? "" },
                set: { notes.draft?.text = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Type.label)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { notes.pin() }
            if let refusal = notes.refusal {
                Text(verbatim: refusal).font(Type.detail).foregroundStyle(Theme.Ink.caution)
            }
            HStack {
                Spacer()
                Button("Cancel") { notes.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Pin note") { notes.pin() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(Space.regular)
        .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Line.divider))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .onAppear { focused = true }
    }
}
