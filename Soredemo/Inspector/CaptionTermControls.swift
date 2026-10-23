import Foundation
import SwiftUI

/// A list of names the recogniser has never heard, and what it can and cannot do about them.
///
/// **The sentence under it is the feature.** Every surveyed recorder offers a list like this
/// and the ones built on a downloaded Whisper-class model really do bias recognition with it.
/// This one cannot — measured, twice, in `docs/design/teaching-the-recogniser-a-word.md` —
/// so it corrects the spelling of what came back, and says that rather than letting somebody
/// read the control as accuracy and blame the recording when a name is still wrong.
struct CaptionTermControls: View {
    let model: CaptionsModel
    /// Re-break the cues and refresh the preview: a corrected word is a different width.
    let onTermsChanged: () -> Void
    /// The name being typed. Cleared on add, so the field is ready for the next one.
    @State private var newTerm = ""

    var body: some View {
        HStack {
            TextField("A name, spelled your way", text: $newTerm)
                .onSubmit(addTerm)
            Button("Add") { addTerm() }
                .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        ForEach(Array(model.spokenTerms.enumerated()), id: \.offset) { index, term in
            HStack {
                Text(verbatim: term)
                Spacer()
                Button {
                    model.removeTerm(at: index)
                    onTermsChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this name")
            }
        }
        Text("These correct the SPELLING of what was recognised. They cannot make the recogniser hear a name it does not know — a name it heard as something else entirely stays that way.")
            .font(Type.detail).foregroundStyle(.secondary)
    }

    private func addTerm() {
        guard model.addTerm(newTerm) else { return }
        newTerm = ""
        onTermsChanged()
    }
}
