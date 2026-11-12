import Overlays
import SwiftUI

/// Corrections the recording's own screen proposes: a run the recogniser heard, the spelling of a
/// label or application that was on screen and sounds or reads close to it, where it was and which
/// lines it is in. **Nothing changes until the person chooses**
/// (`docs/design/2026-11-12-captions-that-know-what-was-on-screen.md`).
struct CaptionSuggestionList: View {
    let model: CaptionsModel
    let onChange: () -> Void

    var body: some View {
        Section("From the screen") {
            Text("Words that were on screen while you recorded, close to something the recogniser heard. Nothing changes until you choose.")
                .font(Type.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.suggestions) { suggestion in
                row(suggestion)
            }
        }
    }

    private func row(_ suggestion: CaptionSuggestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.snug) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(suggestion.was) → \(suggestion.now)")
                    .font(Type.label)
                (origin(suggestion.origin) + Text(verbatim: " · ") + lines(suggestion.lines))
                    .font(Type.detail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.tight)
            Button("Use") {
                model.accept(suggestion)
                onChange()
            }
            .help("Replace it in every line it is in, and add it to Names")
            Button {
                model.dismiss(suggestion)
            } label: {
                Image(systemName: "xmark").font(Type.barIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Not this one")
            .accessibilityLabel(Text("Not this one"))
        }
    }

    private func origin(_ origin: VocabularyEvidence.Origin) -> Text {
        switch origin {
        case .pressedLabel(let step): Text("Pressed in step \(step)")
        case .application(let step): Text("The app in step \(step)")
        }
    }

    /// Lines are numbered from one, as the caption list numbers them.
    private func lines(_ indices: [Int]) -> Text {
        if indices.count == 1 { return Text("In line \(indices[0] + 1)") }
        return Text("In lines \(indices.map { String($0 + 1) }.joined(separator: ", "))")
    }
}
