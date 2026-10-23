import SwiftUI
import Compositing
import Timeline
import Variants

/// The export's shape, size, format and quality, with an estimate of the file.
///
/// Moved out of `StageWindow` — step 1 of `docs/design/2026-10-23-splitting-the-stage-window.md`.
struct OutputControls: View {
    @Bindable var editor: EditorViewModel
    let onExportFinalCutXML: () -> Void

    var body: some View {
        // The recording's own shape first when it is not already one of the three — see
        // `AspectVariant.available(recordingWidth:recordingHeight:)`.
        Picker("Shape", selection: Binding(
            get: { editor.variant },
            set: { editor.variant = $0; editor.chosenShapeDeliberately = true })) {
            ForEach(AspectVariant.available(recordingWidth: editor.recordingSize.width,
                                            recordingHeight: editor.recordingSize.height),
                    id: \.self) { shape in
                Text(LocalizedStringKey(shape.name)).tag(shape)
            }
        }
        let size = editor.outputSize
        LabeledContent("Size", value: "\(size.width)\u{00D7}\(size.height)")
            .font(Type.detail).foregroundStyle(.secondary)

        // **A destination, as the four settings below it.** Choosing one sets them and then gets
        // out of the way — the four stay live, and changing any of them puts this back to
        // Custom rather than silently claiming an export is still "Web" when it is not. See
        // `ExportPreset`.
        Picker("For", selection: $editor.preset) {
            // Not selectable: "Custom" is a description of where the four controls are, not a
            // thing to choose. Choosing it would have to mean "put them back", and there is no
            // back to put them to.
            Text("Custom").tag(ExportPreset?.none)
            ForEach(ExportPreset.all, id: \.self) { preset in
                Text(LocalizedStringKey(preset.name)).tag(ExportPreset?.some(preset))
            }
        }
        if let preset = editor.preset {
            Text(LocalizedStringKey(preset.detail))
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // **How large, by SHORT side.** A ladder written as 1920×1080 cannot describe a portrait
        // output, and this app exports portrait and square for the places people post them.
        Picker("Resolution", selection: Binding(
            get: { editor.resolution }, set: { editor.resolution = $0 })) {
            ForEach(ExportResolution.available(recordingShortSide: editor.recordingShortSide),
                    id: \.self) { choice in
                Text(LocalizedStringKey(choice.displayName)).tag(choice)
            }
        }
        Picker("Frame rate", selection: Binding(
            get: { editor.frameRate }, set: { editor.frameRate = $0 })) {
            ForEach(ExportFrameRate.available(recording: editor.recordingFrameRate),
                    id: \.self) { choice in
                Text(LocalizedStringKey(choice.displayName)).tag(choice)
            }
        }
        // **Codecs that are not ranked.** HEVC is the same picture at about half the file and
        // every Mac this runs on encodes it in hardware; ProRes is enormous and meant for handing
        // to an editor; H.264 plays everywhere without a question being asked.
        //
        // **Narrowed to two when the stage has no background**, because only two of them carry an
        // alpha channel and the other three do not fail when handed one — they encode the
        // transparency away and hand back a black rectangle. `MP4Exporter` refuses that pairing
        // by name, but a list somebody cannot choose wrongly from is better than a refusal they
        // have to read. See `TransparentExport`.
        Picker("Format", selection: Binding(get: { editor.codec }, set: { editor.codec = $0 })) {
            ForEach(editor.stageStyle.isTransparent
                    ? TransparentExport.codecsThatCarryIt
                    : ExportCodec.allCases, id: \.self) { choice in
                Text(LocalizedStringKey(choice.displayName)).tag(choice)
            }
        }
        // **Snapped rather than left dangling.** Somebody who had chosen H.264 and then made the
        // background transparent has a selection that is no longer in the list; SwiftUI would
        // show an empty picker and the export would refuse. Moving it to the smallest format that
        // works is visible — the picker changes in front of them — which is the difference
        // between this and a silent correction at export time.
        .task(id: editor.stageStyle.isTransparent) { editor.keepCodecAbleToCarryTransparency() }
        if editor.stageStyle.isTransparent {
            Text("The background is transparent, so only formats that keep an alpha channel are offered. HEVC with Alpha is around a hundred times smaller than ProRes 4444 for the same picture.")
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // **What this Mac's encoder actually does with a coloured edge**, asked rather than
        // tabulated — see `CodecVerdicts`. Silent when the probe could not run: "we could not
        // ask" and "the answer is no" are different things.
        if let note = CodecVerdicts.shared.note(for: editor.codec) {
            Text(LocalizedStringKey(note))
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // **How many bits the picture gets.** Nothing was choosing before, so AVFoundation did —
        // at a rate tuned for camera footage, which is the wrong content. See `ExportQuality`.
        if editor.codec.takesBitRate {
            Picker("Quality", selection: Binding(
                get: { editor.quality }, set: { editor.quality = $0 })) {
                ForEach(ExportQuality.choices, id: \.self) { choice in
                    Text(LocalizedStringKey(choice.displayName)).tag(choice)
                }
            }
        }
        // **The estimate is why the picker is usable.** A quality control with no consequence
        // attached is three words to guess between.
        if let range = editor.timeline.exportRange {
            // **Named in the sheet, because the button says "Export" either way.** Somebody who
            // marked a section an hour ago and came back to export has no other way to find out
            // that the file will be ten seconds long.
            let seconds = Double(range.upperBound - range.lowerBound) / 1_000_000_000
            let whole = TransportBar.timecode(Double(editor.timeline.edit.outputDuration.rawValue) / 1e9)
            LabeledContent("Range") { Text("\(TransportBar.timecode(seconds)) of \(whole)") }
                .font(Type.detail).foregroundStyle(Theme.Ink.accent)
        }
        LabeledContent("About", value: StageWindow.fileSize(editor.estimatedExportBytes))
            .font(Type.detail).foregroundStyle(.secondary)

        Divider()

        // **A separate button, not a third entry in the save panel's format popup.** Every
        // control above this — resolution, codec, quality, the size estimate — describes a
        // rendered picture, and none of them applies to a cut list. Folding it into the same
        // panel would offer somebody a bit rate for a text file.
        //
        // It also runs instantly rather than through `ExportQueue`: there is nothing to render.
        Button("Export Final Cut XML\u{2026}") { onExportFinalCutXML() }
            .disabled(editor.timeline.editForExport.isEmpty)
        // **What it carries and what it does not, before the click rather than after it.**
        // "Export to Final Cut" reads like a promise to carry everything, and the honest answer
        // is that it carries the cut and none of the look — which is exactly what somebody
        // finishing in another application wants, and nothing like what they would expect if
        // nobody said so.
        Text("The cut only — your clips and their in-points, against the original recording, with the camera on its own lane. None of the look travels: no zooms, no cursor, no background. DaVinci Resolve reads the same file.")
            .font(Type.detail).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
