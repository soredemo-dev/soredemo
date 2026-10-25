import Overlays
import Compositing
import Foundation
import Observation
import Render
import SwiftUI
import Timeline

/// The text overlays on one recording: adding one, editing it, placing it.
///
/// **Authored, all of it.** Nothing here is derived from the recording, so unlike the caption
/// track this is exactly what the producer-value rule says a project file should hold.
@Observable
final class TextOverlaysModel {
    private(set) var track = TextTrack()
    /// Which item the panel is editing, or `nil`. An id rather than an index, for `EditClip`'s
    /// reason: delete an earlier item and an index silently selects a different one.
    var selection: Int?

    /// How long a new overlay lasts when nothing says otherwise. Three seconds is about as long
    /// as a person reads a short title before it starts feeling stuck.
    static let defaultDuration = Nanoseconds(3_000_000_000)

    init() { publish() }

    var selected: TextItem? {
        selection.flatMap { id in track.items.first { $0.id == id } }
    }

    /// Adds one at the playhead and selects it, so a person can type immediately rather than
    /// hunting for the thing they just made.
    func add(at playhead: Nanoseconds) {
        track = track.adding(text: "Text",
                             start: playhead,
                             end: Nanoseconds(playhead.rawValue + Self.defaultDuration.rawValue))
        selection = track.items.map(\.id).max()
        publish()
    }

    func update(_ item: TextItem) {
        track = track.replacing(item)
        publish()
    }

    func remove(_ id: Int) {
        track = track.removing(id)
        if selection == id { selection = nil }
        publish()
    }

    func restore(_ saved: TextTrack) {
        track = saved
        selection = nil
        publish()
    }

    /// The one place the model and the compositor's static are connected — `StageStyleModel`'s
    /// arrangement, for the same reason.
    private func publish() {
        StageCompositor.texts = track
    }
}

/// The text tab: a list of what is on screen, and the controls for whichever one is selected.
///
/// **A list plus an editor for the selection**, which is the inspector shape that works — the
/// tabs change with what is selected rather than showing every control for every object at once.
struct TextPanel: View {
    let model: TextOverlaysModel
    let playhead: Nanoseconds
    let onChange: () -> Void

    var body: some View {
        List {
            Section {
                Button("Add text at the playhead") {
                    model.add(at: playhead)
                    onChange()
                }
            }
            if model.track.isEmpty {
                Section {
                    Text("Nothing on screen yet.")
                        .font(Type.detail).foregroundStyle(.secondary)
                }
            } else {
                Section("On screen") { items }
            }
            if let item = model.selected {
                Section("Content") { content(item) }
                Section("Place") { placement(item) }
                Section("Look") { look(item) }
                Section {
                    Button("Delete", role: .destructive) {
                        model.remove(item.id)
                        onChange()
                    }
                }
            }
        }
        .inspectorList()
    }

    @ViewBuilder private var items: some View {
        ForEach(model.track.items) { item in
            HStack {
                (item.text.isEmpty ? Text("(empty)") : Text(verbatim: firstLine(of: item.text)))
                    .font(Type.label)
                    .lineLimit(1)
                Spacer()
                Text(verbatim: timecode(item.start)).font(Type.readout).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection = item.id }
            .listRowBackground(model.selection == item.id
                               ? Theme.accent.opacity(0.15) : Color.clear)
        }
    }

    @ViewBuilder private func content(_ item: TextItem) -> some View {
        // `axis: .vertical` so a two-line title can be typed as two lines — `TextArt` splits on
        // newlines and nothing else, which makes the break a decision rather than a computation.
        TextField("Text", text: binding(item, \.text), axis: .vertical)
            .lineLimit(1...4)

        LabeledContent("From", value: timecode(item.start))
            .font(Type.detail).foregroundStyle(.secondary)
        Stepper("Seconds on screen: \(seconds(item.duration))",
                value: durationBinding(item), in: 0.5...30, step: 0.5)
    }

    @ViewBuilder private func placement(_ item: TextItem) -> some View {
        Picker("Align", selection: styleBinding(item, \.anchor, { $0.changing(anchor: $1) })) {
            ForEach(TextAnchor.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
        }
        Slider(value: styleBinding(item, \.x, { $0.changing(x: $1) }), in: 0...1) {
            Text("Across")
        }
        // Labelled "Up from the bottom" rather than "Y": the value IS measured from the bottom,
        // and a person dragging a slider labelled Y reasonably expects the opposite.
        Slider(value: styleBinding(item, \.y, { $0.changing(y: $1) }), in: 0...1) {
            Text("Up from the bottom")
        }
    }

    @ViewBuilder private func look(_ item: TextItem) -> some View {
        Picker("Animation", selection: binding(item, \.animation)) {
            ForEach(TextAnimation.allCases, id: \.self) {
                Text(LocalizedStringKey($0.displayName)).tag($0)
            }
        }
        Slider(value: styleBinding(item, \.heightFraction, { $0.changing(heightFraction: $1) }),
               in: 0.02...0.25) { Text("Size") }
        Toggle("Bold", isOn: styleBinding(item, \.isBold, { $0.changing(isBold: $1) }))
        Slider(value: styleBinding(item, \.alpha, { $0.changing(alpha: $1) }), in: 0...1) {
            Text("Opacity")
        }
        Slider(value: styleBinding(item, \.plateOpacity, { $0.changing(plateOpacity: $1) }),
               in: 0...1) { Text("Plate") }
        Slider(value: styleBinding(item, \.shadowOpacity, { $0.changing(shadowOpacity: $1) }),
               in: 0...1) { Text("Shadow") }
    }

    // MARK: - bindings

    /// One writer for every control: read the field, write the whole item back through
    /// `replacing`. The item is a value, so a binding that mutated a copy would change nothing —
    /// which is the failure mode this shape exists to make impossible.
    private func binding<Value>(_ item: TextItem,
                                _ keyPath: WritableKeyPath<TextItem, Value>) -> Binding<Value> {
        Binding(get: { item[keyPath: keyPath] },
                set: { value in
                    var updated = item
                    updated[keyPath: keyPath] = value
                    model.update(updated)
                    onChange()
                })
    }

    /// The same for a style field, through `TextOverlayStyle.changing` — its eighteen-argument
    /// initialiser is why that method exists.
    private func styleBinding<Value>(
        _ item: TextItem, _ read: KeyPath<TextOverlayStyle, Value>,
        _ write: @escaping (TextOverlayStyle, Value) -> TextOverlayStyle) -> Binding<Value> {
        Binding(get: { item.style[keyPath: read] },
                set: { value in
                    var updated = item
                    updated.style = write(item.style, value)
                    model.update(updated)
                    onChange()
                })
    }

    private func durationBinding(_ item: TextItem) -> Binding<Double> {
        Binding(get: { Double(item.duration.rawValue) / 1_000_000_000 },
                set: { value in
                    var updated = item
                    updated.end = Nanoseconds(
                        item.start.rawValue + Int64(value * 1_000_000_000))
                    model.update(updated)
                    onChange()
                })
    }

    // MARK: - formatting

    private func firstLine(of text: String) -> String {
        text.components(separatedBy: "\n").first ?? text
    }

    private func seconds(_ duration: Nanoseconds) -> String {
        String(format: "%.1f", Double(duration.rawValue) / 1_000_000_000)
    }

    /// `m:ss.t`, as the caption list uses — a column read down for WHERE something is.
    private func timecode(_ time: Nanoseconds) -> String {
        let tenths = max(0, time.rawValue) / 100_000_000
        return "\(tenths / 600):" + String(format: "%02d.%01d", (tenths / 10) % 60, tenths % 10)
    }
}
