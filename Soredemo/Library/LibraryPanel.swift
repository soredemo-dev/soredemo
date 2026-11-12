import Project
import SwiftUI
import UniformTypeIdentifiers

/// The project's library, in the inspector: what is in it, and adding to it — a button and a drop
/// target, because a person brings things in and the agent finds them
/// (`docs/design/2026-11-13-the-library.md`).
struct LibraryPanel: View {
    let model: LibraryModel
    @State private var isChoosing = false
    @State private var isDropTargeted = false

    var body: some View {
        Form {
            Section {
                Text("Takes, clips, screenshots, logos and music for this project. The agent searches them — the recording's steps and words, and the text on each picture.")
                    .font(Type.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add to Library…") { isChoosing = true }
                if let problem = model.problem {
                    Text(verbatim: problem).font(Type.detail).foregroundStyle(Theme.Ink.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("In this project") {
                if model.library.items.isEmpty {
                    Text("Nothing added yet. Drop files here.").font(Type.detail).foregroundStyle(.secondary)
                }
                ForEach(model.library.items) { item in
                    row(item)
                        .contextMenu {
                            Button("Remove from Library", role: .destructive) { model.remove(item.id) }
                        }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, lineWidth: 2).padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importFiles(urls) }
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.movie, .image, .audio],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let granted = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { granted.forEach { $0.stopAccessingSecurityScopedResource() } }
                await model.importFiles(urls)
            }
        }
    }

    private func row(_ item: Library.Item) -> some View {
        HStack(spacing: Space.snug) {
            Image(systemName: Self.icon(item.kind)).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name).font(Type.label).lineLimit(1)
                Text(verbatim: Self.detail(item)).font(Type.detail).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    static func icon(_ kind: Library.Kind) -> String {
        switch kind {
        case .recording: "record.circle"
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        }
    }

    /// Size or length, and where it came from — the facts, not translated, as a file's are.
    static func detail(_ item: Library.Item) -> String {
        var parts: [String] = []
        if let w = item.width, let h = item.height { parts.append("\(w)×\(h)") }
        if let d = item.durationNanos { parts.append(String(format: "%.1f s", Double(d) / 1e9)) }
        switch item.origin {
        case .recorded: break
        case .imported(let original): parts.append(original)
        case .web(let host): parts.append(host)
        }
        return parts.joined(separator: " · ")
    }
}
