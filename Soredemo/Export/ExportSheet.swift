import Compositing
import SwiftUI
import Timeline

/// The export's settings, in front of the Export button — the file's shape, size, format and
/// quality, what it will weigh and how long it will take.
///
/// **Here, not at the top of the inspector.** They stood above the picture's own settings in the
/// inspector's first tab, so a person adjusting the background scrolled past a codec to reach it;
/// they are read at the moment they matter, which is the moment of exporting
/// (`docs/design/2026-10-25-the-editors-layout.md`, item 1).
struct ExportSheet: View {
    @Bindable var editor: EditorViewModel
    let onExportFinalCutXML: () -> Void
    let onExport: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// How long an export of this length and size takes at this Mac's measured rate, or `nil`
    /// before this Mac has finished an export of the kind. Pure.
    static func estimate(seconds: Double, frameRate: Int, width: Int, height: Int,
                         pixelsPerSecond: Double?) -> ExportETA.Reading? {
        guard let pixelsPerSecond, seconds.isFinite, seconds >= 0, frameRate > 0 else { return nil }
        let frames = Int((seconds * Double(frameRate)).rounded())
        return ExportETA.reading(ExportThroughput.seconds(frames: frames, width: width, height: height,
                                                          pixelsPerSecond: pixelsPerSecond))
    }

    /// The length the export will have: the marked range when there is one, the whole edit else.
    private var outputSeconds: Double {
        if let range = editor.timeline.exportRange {
            return Double(range.upperBound - range.lowerBound) / 1_000_000_000
        }
        return Double(editor.timeline.edit.outputDuration.rawValue) / 1_000_000_000
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Export")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], Space.section)
            Form {
                Section {
                    OutputControls(editor: editor)
                    // Beside the size, because the two are read together.
                    LabeledContent("Time") { time }
                        .font(Type.detail).foregroundStyle(.secondary)
                }
                // Applies when the save panel's format is GIF; the panel is where that is chosen.
                Section("Animated GIF") { GIFControls(editor: editor) }
                Section {
                    FinalCutXMLControls(editor: editor, onExportFinalCutXML: {
                        dismiss()
                        onExportFinalCutXML()
                    })
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export\u{2026}") {
                    dismiss()
                    // After the sheet has gone: the save panel is modal and would otherwise open
                    // over a sheet that is on its way out.
                    DispatchQueue.main.async { onExport() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(Space.section)
        }
        .frame(width: 460, height: 620)
    }

    /// The estimate, or why there is none yet. **Never another Mac's number**: the encoders differ,
    /// and this Mac has not been measured until it has exported once.
    @ViewBuilder private var time: some View {
        let size = editor.outputSize
        let rate = ExportSpeedMemory.shared.pixelsPerSecond(for: editor.codec.rawValue)
        if let reading = Self.estimate(seconds: outputSeconds,
                                       frameRate: editor.frameRate.frames(recording: editor.recordingFrameRate),
                                       width: size.width, height: size.height, pixelsPerSecond: rate) {
            Self.text(reading)
        } else {
            Text("Known after this Mac's first export in this format.")
        }
    }

    /// One reading in the reader's language — six keys, the numbers interpolated here, for the
    /// reason `ExportJob.timeText` gives.
    static func text(_ reading: ExportETA.Reading) -> Text {
        switch reading {
        case .aFewSeconds: Text("a few seconds")
        case .seconds(let value): Text("about \(value) seconds")
        case .aMinute: Text("about a minute")
        case .minutes(let value): Text("about \(value) minutes")
        case .anHour: Text("about an hour")
        case .hours(let value): Text("about \(value) hours")
        }
    }
}
