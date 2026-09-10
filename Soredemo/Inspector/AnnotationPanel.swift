import Compositing
import Foundation
import Observation
import Overlays
import Render
import SwiftUI
import Timeline

/// The arrows, lines, boxes and ellipses drawn over a recording.
///
/// **Published to the compositor on every change**, like every other model here. An annotation
/// is placed by looking at it — a person drags a slider and checks the arrow is on the button —
/// so a change that reached the preview only on the next play would be a change they could not
/// judge.
@Observable
final class AnnotationsModel {
    private(set) var track = AnnotationTrack()
    var selection: Int?
    /// The shape the next annotation gets. Held on the model rather than passed in, so a person
    /// drawing three arrows in a row picks "arrow" once.
    var nextShape: AnnotationShape = .arrow

    /// Three seconds. Long enough to read an arrow and notice what it points at, short enough
    /// that leaving one on by accident is obvious — `TextPanel` uses the same reasoning for its
    /// own default and this deliberately matches it, so a title and an arrow added at the same
    /// playhead leave together.
    static let defaultDuration = Nanoseconds(3_000_000_000)

    init() { publish() }

    var selected: AnnotationItem? {
        selection.flatMap { id in track.items.first { $0.id == id } }
    }

    /// A new annotation across the middle of the frame, big enough to see and to grab.
    ///
    /// **Not a zero-length one waiting to be dragged.** There is no draw-on-the-preview surface
    /// yet, and an annotation with no length draws nothing at all — so offering one would be
    /// offering a row in a list and an empty picture, which reads as the feature being broken.
    /// The numbers put it clear of the frame's edges in the recording's own coordinates, where
    /// `y` runs from the bottom.
    func add(at playhead: Nanoseconds) {
        track = track.adding(shape: nextShape,
                             startX: 0.3, startY: 0.35, endX: 0.62, endY: 0.6,
                             start: playhead,
                             end: Nanoseconds(playhead.rawValue + Self.defaultDuration.rawValue))
        selection = track.items.map(\.id).max()
        publish()
    }

    func update(_ item: AnnotationItem) {
        track = track.replacing(item)
        publish()
    }

    func remove(_ id: Int) {
        track = track.removing(id)
        if selection == id { selection = nil }
        publish()
    }

    func restore(_ saved: AnnotationTrack) {
        track = saved
        selection = nil
        publish()
    }

    private func publish() {
        StageCompositor.annotations = track
    }
}

/// The annotation tab.
struct AnnotationPanel: View {
    let model: AnnotationsModel
    let playhead: Nanoseconds
    let onChange: () -> Void

    var body: some View {
        List {
            Section {
                Picker("Shape", selection: Binding(
                    get: { model.nextShape },
                    set: { model.nextShape = $0 })) {
                    ForEach(AnnotationShape.allCases, id: \.self) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                Button("Add a \(model.nextShape.displayName.lowercased())") {
                    model.add(at: playhead)
                    onChange()
                }
                Text("An annotation is anchored to the recording, not to the frame — it moves with the picture when the camera zooms in on what it points at.")
                    .font(Type.detail).foregroundStyle(.secondary)
            }
            if model.track.isEmpty {
                Section {
                    Text("Nothing is marked.").font(Type.detail).foregroundStyle(.secondary)
                }
            } else {
                Section("Marks") { rows }
            }
            if let item = model.selected { editor(for: item) }
        }
        .listStyle(.inset)
    }

    private var rows: some View {
        ForEach(model.track.items) { item in
            HStack {
                Image(systemName: icon(for: item.shape))
                    .foregroundStyle(colour(of: item))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.shape.displayName)
                    Text(span(of: item)).font(Type.detail).foregroundStyle(.secondary)
                }
                Spacer()
                if model.selection == item.id {
                    Image(systemName: "checkmark").foregroundStyle(Theme.Lane.mark)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection = item.id }
            .swipeActions {
                Button("Delete", role: .destructive) {
                    model.remove(item.id)
                    onChange()
                }
            }
        }
    }

    @ViewBuilder
    private func editor(for item: AnnotationItem) -> some View {
        Section("Shape") {
            Picker("Shape", selection: binding(item, \.shape)) {
                ForEach(AnnotationShape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            Picker("Colour", selection: Binding(
                get: { AnnotationInk.nearest(to: item.style) },
                set: { ink in
                    var changed = item
                    changed.style = item.style.changing(red: ink.red, green: ink.green,
                                                        blue: ink.blue)
                    model.update(changed)
                    onChange()
                })) {
                ForEach(AnnotationInk.allCases, id: \.self) { ink in
                    Text(ink.displayName).tag(ink)
                }
            }
            slider("Weight", value: styleBinding(item) { $0.changing(strokeWidthFraction: $1) },
                   read: item.style.strokeWidthFraction, range: 0.001...0.03)
            // **Shown only for the shapes that have an interior.** A fill control on an arrow
            // is a control a person moves and sees nothing happen, which teaches them the panel
            // is broken rather than that the option does not apply.
            if item.shape.canBeFilled {
                slider("Fill", value: styleBinding(item) { $0.changing(fillOpacity: $1) },
                       read: item.style.fillOpacity, range: 0...1)
            }
            slider("Halo", value: styleBinding(item) { $0.changing(shadowOpacity: $1) },
                   read: item.style.shadowOpacity, range: 0...1)
        }
        Section("Where") {
            slider("From across", value: binding(item, \.startX), range: 0...1)
            slider("From up", value: binding(item, \.startY), range: 0...1)
            slider("To across", value: binding(item, \.endX), range: 0...1)
            slider("To up", value: binding(item, \.endY), range: 0...1)
        }
        Section("When") {
            Picker("Arrives", selection: binding(item, \.animation)) {
                ForEach(TextAnimation.allCases, id: \.self) { animation in
                    Text(animation.displayName).tag(animation)
                }
            }
            Button("Start here") {
                var changed = item
                let length = item.duration.rawValue
                changed.start = playhead
                changed.end = Nanoseconds(playhead.rawValue + length)
                model.update(changed)
                onChange()
            }
            Button("End here") {
                // Refused rather than silently reordered: an end before its start is a
                // zero-length annotation that draws nothing, and a button that quietly did
                // something else would be worse than one that does nothing.
                if playhead.rawValue > item.start.rawValue {
                    var changed = item
                    changed.end = playhead
                    model.update(changed)
                    onChange()
                }
            }
            .disabled(playhead.rawValue <= item.start.rawValue)
            Text(span(of: item)).font(Type.detail).foregroundStyle(.secondary)
        }
        Section {
            Button("Delete", role: .destructive) {
                model.remove(item.id)
                onChange()
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 92, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    /// A slider whose getter and setter are supplied separately.
    ///
    /// `AnnotationStyle`'s fields are `let` — they are clamped on the way in, and a `var` would
    /// let a caller assign past the clamp — so there is no writable key path into them and the
    /// setter has to go through `changing(...)`. The read is passed alongside rather than
    /// derived, because a key path that could read it is exactly the one that does not exist.
    private func slider(_ label: String, value: @escaping (Double) -> Void,
                        read: Double, range: ClosedRange<Double>) -> some View {
        slider(label, value: Binding(get: { read }, set: value), range: range)
    }

    /// Writes one style field back through `AnnotationStyle.changing`, which is the only way in
    /// past its clamps.
    private func styleBinding(_ item: AnnotationItem,
                              _ change: @escaping (AnnotationStyle, Double) -> AnnotationStyle)
    -> (Double) -> Void {
        { newValue in
            var changed = item
            changed.style = change(item.style, newValue)
            model.update(changed)
            onChange()
        }
    }

    /// One field of the selected annotation, written back through the model so the compositor
    /// hears about it. Written once as a key path rather than per control, for the reason
    /// `TextOverlayStyle.changing` gives: a dozen hand-written closures is a dozen chances to
    /// write one field into another.
    private func binding<Value>(_ item: AnnotationItem,
                                _ keyPath: WritableKeyPath<AnnotationItem, Value>)
    -> Binding<Value> {
        Binding(get: { item[keyPath: keyPath] },
                set: { newValue in
                    var changed = item
                    changed[keyPath: keyPath] = newValue
                    model.update(changed)
                    onChange()
                })
    }

    private func colour(of item: AnnotationItem) -> Color {
        Color(red: item.style.red, green: item.style.green, blue: item.style.blue)
    }

    private func icon(for shape: AnnotationShape) -> String {
        switch shape {
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        }
    }

    private func span(of item: AnnotationItem) -> String {
        let start = Double(item.start.rawValue) / 1_000_000_000
        let end = Double(item.end.rawValue) / 1_000_000_000
        return String(format: "%.1fs – %.1fs", start, end)
    }
}

/// The colours an annotation can be.
///
/// **A named few, not a colour well**, and the restraint is the same one `TextOverlayStyle`'s
/// header argues for: every control is something a person has to understand before they can put
/// a mark on the screen. These five are picked to stay legible over a screen recording — a
/// screenshot is mostly white and mostly grey — and to be tellable apart from each other by
/// someone who is colourblind, which a free colour well cannot promise.
///
/// **In the app, not in `Render`.** `AnnotationStyle` takes the three components and does not
/// need to know that a person chose from a list; a palette in the render tier would be a public
/// option with nothing exercising it, which is the shape `CameraOverlayStyle.borderOpacity` had.
enum AnnotationInk: String, CaseIterable, Hashable {
    case red, amber, green, blue, ink

    var displayName: String {
        switch self {
        case .red: "Red"
        case .amber: "Amber"
        case .green: "Green"
        case .blue: "Blue"
        case .ink: "Ink"
        }
    }

    var red: Double {
        switch self {
        case .red: 0.93
        case .amber: 0.98
        case .green: 0.16
        case .blue: 0.16
        case .ink: 0.08
        }
    }

    var green: Double {
        switch self {
        case .red: 0.16
        case .amber: 0.72
        case .green: 0.72
        case .blue: 0.45
        case .ink: 0.08
        }
    }

    var blue: Double {
        switch self {
        case .red: 0.16
        case .amber: 0.10
        case .green: 0.32
        case .blue: 0.93
        case .ink: 0.10
        }
    }

    /// Which entry a stored style is closest to.
    ///
    /// **Nearest rather than exact, and a `Picker` is why.** A style decoded from a project
    /// saved by a build with a different palette — or hand-edited — would match nothing, and a
    /// `Picker` with a selection outside its options shows a blank row and quietly rewrites the
    /// value on the next interaction. Answering with the closest entry keeps the control honest
    /// about what it is going to do.
    static func nearest(to style: AnnotationStyle) -> AnnotationInk {
        allCases.min { a, b in a.distance(to: style) < b.distance(to: style) } ?? .red
    }

    private func distance(to style: AnnotationStyle) -> Double {
        pow(red - style.red, 2) + pow(green - style.green, 2) + pow(blue - style.blue, 2)
    }
}
