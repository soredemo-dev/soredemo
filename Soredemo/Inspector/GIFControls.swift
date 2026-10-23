import SwiftUI
import Compositing
import Timeline

/// What a GIF export would be. In the project tab because it is a property of the OUTPUT,
/// like the shape and the look beside it — the format is chosen in the save panel's popup,
/// which is where macOS puts it.
///
/// Moved out of `StageWindow` — step 1 of `docs/design/2026-10-23-splitting-the-stage-window.md`.
struct GIFControls: View {
    @Bindable var editor: EditorViewModel

    var body: some View {
        Picker("Frames", selection: $editor.gifSettings.frameRate) {
            ForEach(GIFSettings.exactRates, id: \.self) { rate in
                Text("\(rate) fps").tag(rate)
            }
        }
        Picker("Longest edge", selection: $editor.gifSettings.maximumLongestEdge) {
            Text("480 px").tag(480)
            Text("640 px").tag(640)
            Text("960 px").tag(960)
            Text("1280 px").tag(1280)
        }
        Toggle("Loop forever", isOn: $editor.gifSettings.loops)

        let size = editor.outputSize
        let gif = editor.gifSettings.size(fitting: size.width, height: size.height)
        // The size is worth stating because it is not the export size beside it, and the
        // "no sound" is worth stating because a person who recorded themselves talking would
        // otherwise find that out from the file.
        LabeledContent("GIF", value: "\(gif.width)\u{00D7}\(gif.height), no sound")
            .font(Type.detail).foregroundStyle(.secondary)
        // **A GIF has no inter-frame compression worth the name**, so its size is frames times
        // pixels and nothing else — a twenty-second 640-wide GIF is tens of megabytes, which is
        // past what most places accept. Warned about here rather than letting somebody find
        // out from the upload.
        // `editForExport`, not `edit`: with a section marked, the file being estimated is
        // the section. A figure for the whole video beside a button that writes ten seconds of
        // it is worse than no figure.
        let seconds = Double(editor.timeline.editForExport.outputDuration.rawValue) / 1_000_000_000
        let gifBytes = Int(Double(gif.width * gif.height) * 0.5 * 0.07
                           * Double(editor.gifSettings.frameRate) * seconds)
        if gifBytes > 20_000_000 {
            Label("About \(StageWindow.fileSize(gifBytes)) \u{2014} fewer frames or a smaller edge",
                  systemImage: "exclamationmark.triangle")
                .font(Type.detail).foregroundStyle(Signal.paused)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
