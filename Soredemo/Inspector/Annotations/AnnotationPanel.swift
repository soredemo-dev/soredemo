import AppKit
import Overlays
import Render
import SwiftUI
import Timeline
import UniformTypeIdentifiers

/// The annotation tab.
struct AnnotationPanel: View {
    let model: AnnotationsModel
    let playhead: Nanoseconds
    /// The project package, where a picture annotation's file is copied.
    let packageURL: URL
    let onChange: () -> Void

    var body: some View {
        List {
            Section {
                Picker("Shape", selection: Binding(
                    get: { model.nextShape },
                    set: { model.nextShape = $0 })) {
                    ForEach(AnnotationShape.allCases, id: \.self) { shape in
                        Text(LocalizedStringKey(shape.displayName)).tag(shape)
                    }
                }
                // The picker above names the shape. "Add a \(name)" put an English noun into a
                // sentence no other language's grammar survives.
                Button("Add at the playhead") {
                    if model.nextShape == .image {
                        guard let name = choosePicture() else { return }
                        model.add(at: playhead, imageName: name)
                    } else {
                        model.add(at: playhead)
                    }
                    onChange()
                }
                if let pictureFailure = model.pictureFailure {
                    Text(verbatim: pictureFailure).font(Type.detail).foregroundStyle(Signal.paused)
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
                    Text(LocalizedStringKey(item.shape.displayName))
                    Text(verbatim: span(of: item)).font(Type.detail).foregroundStyle(.secondary)
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
                    Text(LocalizedStringKey(shape.displayName)).tag(shape)
                }
            }
            if item.shape == .image {
                LabeledContent("Picture") { Text(verbatim: item.imageName) }
                Button("Replace Picture…") {
                    guard let name = choosePicture() else { return }
                    var changed = item
                    changed.imageName = name
                    model.update(changed)
                    onChange()
                }
            }
            // Ink, weight and halo draw a shape; a picture is drawn in its own colours.
            if item.shape.drawsWithInk {
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
                        Text(LocalizedStringKey(ink.displayName)).tag(ink)
                    }
                }
                slider("Weight", value: styleBinding(item) { $0.changing(strokeWidthFraction: $1) },
                       read: item.style.strokeWidthFraction, range: 0.001...0.03)
            }
            // **Shown only for the shapes that have an interior.** A fill control on an arrow
            // is a control a person moves and sees nothing happen, which teaches them the panel
            // is broken rather than that the option does not apply.
            //
            // **Not for a callout**, whose bubble is solid whatever `fillOpacity` says — the same
            // control-that-does-nothing this comment is about, arriving through the one fillable
            // shape that ignores its fill.
            if item.shape.canBeFilled && item.shape != .callout {
                slider("Fill", value: styleBinding(item) { $0.changing(fillOpacity: $1) },
                       read: item.style.fillOpacity, range: 0...1)
            }
            // The words and their size, only where they are drawn. `text` is kept on every shape
            // so switching away and back does not lose it, but offering to edit it on an arrow
            // would be offering to edit something nobody can see.
            if item.shape == .callout {
                TextField("Text", text: binding(item, \.text))
                slider("Size", value: styleBinding(item) { $0.changing(textSizeFraction: $1) },
                       read: item.style.textSizeFraction,
                       range: AnnotationStyle.smallestTextFraction...AnnotationStyle.largestTextFraction)
            }
            if item.shape.drawsWithInk {
                slider("Halo", value: styleBinding(item) { $0.changing(shadowOpacity: $1) },
                       read: item.style.shadowOpacity, range: 0...1)
            }
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
                    Text(LocalizedStringKey(animation.displayName)).tag(animation)
                }
            }
            Button("Start here") {
                model.startHere(item, at: playhead)
                onChange()
            }
            // Refused by the model when the end would not be after the start; see `endHere`.
            Button("End here") {
                if model.endHere(item, at: playhead) { onChange() }
            }
            .disabled(!AnnotationsModel.canEndHere(item, at: playhead))
            Text(verbatim: span(of: item)).font(Type.detail).foregroundStyle(.secondary)
        }
        Section {
            Button("Delete", role: .destructive) {
                model.remove(item.id)
                onChange()
            }
        }
    }

    private func slider(_ label: LocalizedStringKey, value: Binding<Double>,
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
    /// **`@Sendable`, which `Binding(get:set:)` began requiring in the macOS 27 SDK.** The
    /// closure is called from SwiftUI on the main actor either way; the annotation is the
    /// compiler being told what was already true rather than a change in behaviour.
    private func slider(_ label: LocalizedStringKey, value: @escaping @Sendable (Double) -> Void,
                        read: Double, range: ClosedRange<Double>) -> some View {
        slider(label, value: Binding(get: { read }, set: value), range: range)
    }

    /// Writes one style field back through `AnnotationStyle.changing`, which is the only way in
    /// past its clamps.
    private func styleBinding(_ item: AnnotationItem,
                              _ change: @escaping @Sendable (AnnotationStyle, Double)
                                  -> AnnotationStyle)
    -> @Sendable (Double) -> Void {
        // **Checked, not assumed.** The macOS 27 SDK marks `Binding(get:set:)`'s setter
        // `@Sendable`, which says the closure MAY cross actors — so the compiler can no longer
        // see what SwiftUI does in practice, and neither can this code. `MainActor.assumeIsolated`
        // was the first fix and it is the wrong one: `GlobalHotkey` records that asserting an
        // unproven main-thread guarantee that way "is the exact shape that produced an
        // EXC_BREAKPOINT earlier in this project", and a setter that reaches
        // `WindowConfigurator.configure()` through `onChange` would raise AppKit's own
        // "NSWindow geometry should only be modified on the main thread".
        //
        // Marking the closure `@MainActor` does not type-check — a global-actor function cannot
        // convert to the `@Sendable` one the initialiser takes — so the thread is asked.
        // Synchronous when it is already the main one, which is every observed call; a hop when
        // it is not, which is correctness rather than a slower path.
        { newValue in
            let apply = { @MainActor in
                var changed = item
                changed.style = change(item.style, newValue)
                model.update(changed)
                onChange()
            }
            if Thread.isMainThread { MainActor.assumeIsolated { apply() } }
            else { Task { @MainActor in apply() } }
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
        // A bubble WITH words in it, since the words are the whole difference between a callout
        // and a rectangle — checked to exist, like every symbol this panel names.
        case .callout: "text.bubble"
        case .image: "photo"
        case .step: "1.circle.fill"
        case .highlight: "highlighter"
        }
    }

    private func span(of item: AnnotationItem) -> String {
        let start = Double(item.start.rawValue) / 1_000_000_000
        let end = Double(item.end.rawValue) / 1_000_000_000
        return String(format: "%.1fs – %.1fs", start, end)
    }
}

extension AnnotationPanel {
    /// Asks for a picture and hands it to the model, which copies it into the project.
    ///
    /// **The panel stays in the view; the file work does not.** `NSOpenPanel` cannot run in a
    /// test, and the copy — and the name it is refused for — is what is worth testing
    /// (`AnnotationsModelTests`).
    fileprivate func choosePicture() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return nil }
        return model.adoptPicture(source, packageURL: packageURL)
    }
}
