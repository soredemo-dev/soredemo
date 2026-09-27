import Compositing
import Foundation
import Observation
import Overlays
import Render
import SwiftUI
import Timeline

/// The regions of a recording that are hidden.
///
/// **Published to the compositor on every change, like every other model here** — and with one
/// extra reason: a region a person just drew must cover its target in the preview immediately,
/// because the preview is how they check it covers the right thing.
@Observable
final class RedactionsModel {
    private(set) var track = RedactionTrack()
    var selection: Int?

    init() { publish() }

    var selected: RedactionItem? {
        selection.flatMap { id in track.items.first { $0.id == id } }
    }

    /// A new region in the middle of the frame, big enough to see and to grab. A person then
    /// moves it with the sliders; there is no drag-on-the-preview surface yet, and offering a
    /// zero-sized region to drag would be offering nothing.
    func add() {
        track = track.adding(x: 0.35, y: 0.4, width: 0.3, height: 0.2)
        selection = track.items.map(\.id).max()
        publish()
    }

    func update(_ item: RedactionItem) {
        track = track.replacing(item)
        publish()
    }

    func remove(_ id: Int) {
        track = track.removing(id)
        if selection == id { selection = nil }
        publish()
    }

    func restore(_ saved: RedactionTrack) {
        track = saved
        selection = nil
        publish()
    }

    private func publish() {
        StageCompositor.redactions = track
    }
}

/// The redaction tab.
struct RedactionPanel: View {
    let model: RedactionsModel
    let playhead: Nanoseconds
    let onChange: () -> Void

    var body: some View {
        List {
            Section {
                Button("Hide a region") {
                    model.add()
                    onChange()
                }
                Text("A mosaic averages away what it covers; a solid fill leaves nothing at all. Neither is a blur — a blur can be undone.")
                    .font(Type.detail).foregroundStyle(.secondary)
            }
            if model.track.isEmpty {
                Section {
                    Text("Nothing is hidden.").font(Type.detail).foregroundStyle(.secondary)
                }
            } else {
                Section("Hidden") { rows }
            }
            if let item = model.selected {
                Section("Area") { area(item) }
                Section("Cover") { cover(item) }
                Section("When") { when(item) }
                Section {
                    Button("Stop hiding this", role: .destructive) {
                        model.remove(item.id)
                        onChange()
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var rows: some View {
        ForEach(model.track.items) { item in
            HStack {
                Image(systemName: item.region.isOval ? "oval" : "rectangle")
                Text(verbatim: describe(item))
                    .font(Type.label)
                Spacer()
                if item.region.isEmpty {
                    // A region with no area covers nothing, and saying so beats a row that
                    // looks like protection and is not.
                    Text("covers nothing").font(Type.detail).foregroundStyle(Theme.Ink.caution)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection = item.id }
            .listRowBackground(model.selection == item.id
                               ? Theme.accent.opacity(0.15) : Color.clear)
        }
    }

    @ViewBuilder private func area(_ item: RedactionItem) -> some View {
        Slider(value: regionBinding(item, \.x, { $0.x = $1 }), in: 0...1) { Text("From the left") }
        Slider(value: regionBinding(item, \.y, { $0.y = $1 }), in: 0...1) { Text("From the top") }
        Slider(value: regionBinding(item, \.width, { $0.width = $1 }), in: 0...1) { Text("Width") }
        Slider(value: regionBinding(item, \.height, { $0.height = $1 }), in: 0...1) { Text("Height") }
        Toggle("Oval", isOn: Binding(
            get: { item.region.isOval },
            set: { value in
                var updated = item
                updated.region.isOval = value
                model.update(updated)
                onChange()
            }))
    }

    @ViewBuilder private func cover(_ item: RedactionItem) -> some View {
        Picker("Cover with", selection: Binding(
            get: { isSolid(item) },
            set: { solid in
                var updated = item
                updated.region.style = solid ? .black : .defaultMosaic
                model.update(updated)
                onChange()
            })) {
            Text("Mosaic").tag(false)
            Text("Solid").tag(true)
        }
        if case .mosaic(let blockFraction) = item.region.style {
            Slider(value: Binding(
                get: { blockFraction },
                set: { value in
                    var updated = item
                    updated.region.style = .mosaic(blockFraction: value)
                    model.update(updated)
                    onChange()
                }), in: 0.005...0.15) { Text("Block size") }
        }
    }

    @ViewBuilder private func when(_ item: RedactionItem) -> some View {
        Toggle("The whole recording", isOn: Binding(
            get: { item.coversEverything },
            set: { value in
                var updated = item
                updated.coversEverything = value
                // Turning it off with no span set would hide nothing at all, so the span
                // starts at the playhead — which is where a person is looking.
                if !value, updated.end.rawValue <= updated.start.rawValue {
                    updated.start = playhead
                    updated.end = Nanoseconds(playhead.rawValue + 5_000_000_000)
                }
                model.update(updated)
                onChange()
            }))
        if !item.coversEverything {
            LabeledContent("From", value: timecode(item.start))
                .font(Type.detail).foregroundStyle(.secondary)
            Button("Start here") {
                var updated = item
                updated.start = playhead
                if updated.end.rawValue <= playhead.rawValue {
                    updated.end = Nanoseconds(playhead.rawValue + 1_000_000_000)
                }
                model.update(updated)
                onChange()
            }
            LabeledContent("Until", value: timecode(item.end))
                .font(Type.detail).foregroundStyle(.secondary)
            Button("End here") {
                var updated = item
                updated.end = max(playhead, Nanoseconds(item.start.rawValue + 100_000_000))
                model.update(updated)
                onChange()
            }
        }
    }

    // MARK: - bindings

    /// `RedactionRegion`'s initialiser clamps, so every write goes through it rather than
    /// assigning a stored property — a width set past the right edge has to become the width
    /// that reaches the edge, not a number that silently covers nothing.
    private func regionBinding(_ item: RedactionItem, _ read: KeyPath<RedactionRegion, Double>,
                               _ write: @escaping (inout RedactionRegion, Double) -> Void
    ) -> Binding<Double> {
        Binding(get: { item.region[keyPath: read] },
                set: { value in
                    var region = item.region
                    write(&region, value)
                    var updated = item
                    updated.region = RedactionRegion(
                        id: region.id, x: region.x, y: region.y,
                        width: region.width, height: region.height,
                        style: region.style, isOval: region.isOval)
                    model.update(updated)
                    onChange()
                })
    }

    private func isSolid(_ item: RedactionItem) -> Bool {
        if case .solid = item.region.style { return true }
        return false
    }

    private func describe(_ item: RedactionItem) -> String {
        let percent = { (value: Double) in "\(Int((value * 100).rounded()))%" }
        let size = "\(percent(item.region.width))\u{00D7}\(percent(item.region.height))"
        return item.coversEverything ? size
            : String(localized: "\(size) from \(timecode(item.start))")
    }

    private func timecode(_ time: Nanoseconds) -> String {
        let tenths = max(0, time.rawValue) / 100_000_000
        return "\(tenths / 600):" + String(format: "%02d.%01d", (tenths / 10) % 60, tenths % 10)
    }
}
