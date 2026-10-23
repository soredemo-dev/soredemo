import AppKit
import Foundation
import Overlays
import Render
import SwiftUI
import Timeline
import UniformTypeIdentifiers

/// How a caption looks, and the sidecar file it can be exported to or read back from. Moved out
/// of `CaptionsPanel` (2026-10-23); the file panels it opens are its own, and the work behind
/// them is `CaptionsModel`'s.
struct CaptionLookControls: View {
    let model: CaptionsModel
    let mediaURL: URL
    /// What the recording is called — the sidecar's starting name. See `RecordingName`.
    let recordingName: String
    let edit: EditTimeline?
    let onChange: () -> Void

    var body: some View {
        Toggle("Burn into the video", isOn: Binding(
            get: { model.burnsIn },
            set: { model.setBurnsIn($0); onChange() }))
        Text("A burnt-in caption cannot be turned off, translated or searched. A sidecar file can.")
            .font(Type.detail).foregroundStyle(.secondary)

        Slider(value: Binding(get: { model.style.heightFraction },
                              set: { model.setStyle(styleChanging(height: $0)); onChange() }),
               in: 0.02...0.09) { Text("Size") }
        Slider(value: Binding(get: { model.style.bottomInsetFraction },
                              set: { model.setStyle(styleChanging(inset: $0)); onChange() }),
               in: 0...0.4) { Text("Height above the bottom") }
        Slider(value: Binding(get: { model.style.backgroundOpacity },
                              set: { model.setStyle(styleChanging(plate: $0)); onChange() }),
               in: 0...1) { Text("Plate") }

        // **Six controls that were literals in `CaptionStyle.asTextStyle`.** Every one of them
        // was already drawable — the conversion passed `x: 0.5`, `.center`, `isBold: false`, a
        // black plate and no shadow as constants, so a caption could be sized and raised and
        // nothing else.
        Picker("Alignment", selection: Binding(
            get: { model.style.alignment },
            set: { model.setStyle(model.style.changing(alignment: $0)); onChange() })) {
            ForEach(TextAnchor.allCases, id: \.self) { anchor in
                Text(LocalizedStringKey(anchor.displayName)).tag(anchor)
            }
        }
        // Only where it can do anything: a centred caption is at the middle by definition, and
        // a slider that moves nothing is a slider people learn not to trust.
        if model.style.alignment != .center {
            Slider(value: Binding(
                get: { model.style.horizontalFraction },
                set: { model.setStyle(model.style.changing(horizontalFraction: $0)); onChange() }),
                   in: 0...1) { Text("Across the frame") }
        }
        Toggle("Bold", isOn: Binding(
            get: { model.style.isBold },
            set: { model.setStyle(model.style.changing(isBold: $0)); onChange() }))
        ColorPicker("Text", selection: Binding(
            get: { Color(red: model.style.red, green: model.style.green, blue: model.style.blue) },
            set: { colour in
                let rgb = Self.components(of: colour)
                model.setStyle(model.style.changing(red: rgb.red, green: rgb.green,
                                                    blue: rgb.blue))
                onChange()
            }), supportsOpacity: false)
        // Offered only when there is a plate to colour. At zero opacity it draws nothing, and a
        // colour well for an invisible rectangle is a control that answers nothing.
        if model.style.backgroundOpacity > 0 {
            ColorPicker("Plate colour", selection: Binding(
                get: { Color(red: model.style.plateRed, green: model.style.plateGreen,
                             blue: model.style.plateBlue) },
                set: { colour in
                    let rgb = Self.components(of: colour)
                    model.setStyle(model.style.changing(plateRed: rgb.red, plateGreen: rgb.green,
                                                        plateBlue: rgb.blue))
                    onChange()
                }), supportsOpacity: false)
        }
        fontRow

        // **Offered above the plate and the shadow, because it is the one that reads over
        // anything.** A plate covers the picture and a shadow softens an edge; an outline
        // follows the letters, so a caption crossing a light region and a dark one in the same
        // line stays legible without a rectangle across the frame.
        Slider(value: Binding(
            get: { model.style.outlineWidthFraction },
            set: { model.setStyle(model.style.changing(outlineWidthFraction: $0)); onChange() }),
               in: 0...0.14) { Text("Outline") }
        if model.style.outlineWidthFraction > 0 {
            ColorPicker("Outline colour", selection: Binding(
                get: { Color(red: model.style.outlineRed, green: model.style.outlineGreen,
                             blue: model.style.outlineBlue) },
                set: { colour in
                    let rgb = Self.components(of: colour)
                    model.setStyle(model.style.changing(outlineRed: rgb.red,
                                                        outlineGreen: rgb.green,
                                                        outlineBlue: rgb.blue))
                    onChange()
                }), supportsOpacity: false)
        }

        Slider(value: Binding(
            get: { model.style.shadowOpacity },
            set: { model.setStyle(model.style.changing(shadowOpacity: $0,
                                                       shadowBlurFraction: $0 > 0
                                                           ? max(model.style.shadowBlurFraction,
                                                                 0.004)
                                                           : model.style.shadowBlurFraction))
                   onChange() }),
               in: 0...1) { Text("Shadow") }
        Text("A shadow separates the words from what is behind them without covering it, which is what a plate does instead.")
            .font(Type.detail).foregroundStyle(.secondary)

        // **The recogniser has been giving word times all along and nothing read them.**
        // `TranscribedWord.start`/`.end` were stored, retimed through cuts and clipped at cut
        // boundaries, and never drawn.
        Toggle("Highlight the word being said", isOn: Binding(
            get: { model.style.highlightsSpokenWord },
            set: { model.setStyle(model.style.changing(highlightsSpokenWord: $0)); onChange() }))
        if model.style.highlightsSpokenWord {
            Slider(value: Binding(
                get: { model.style.unspokenOpacity },
                set: { model.setStyle(model.style.changing(unspokenOpacity: $0)); onChange() }),
                   in: 0.15...1) { Text("Other words") }
            if let transcript = model.transcript, transcript.words.isEmpty {
                // Said rather than left to fail silently: a language whose model reports no word
                // times produces a toggle that does nothing, and a person would blame the app.
                Label("This language's model gave no word times, so the whole line stays lit.",
                      systemImage: "info.circle")
                    .font(Type.detail).foregroundStyle(.secondary)
            }
        }

        HStack(spacing: Space.snug) {
            ForEach(SubtitleFile.Format.allCases, id: \.self) { format in
                Button("Export .\(format.fileExtension)") {
                    guard model.readyToExport(),
                          let url = Self.sidecarDestination(format: format,
                                                            defaultName: recordingName)
                    else { return }
                    model.exportSidecar(format: format, edit: edit, to: url)
                }
            }
            Spacer()
            Button("Import…") {
                guard let url = Self.chooseSidecar() else { return }
                model.importSidecar(from: url, edit: edit)
                onChange()
            }
        }
        // **The escape hatch, and it is worth saying it is one.** Whatever this panel cannot do,
        // a dedicated subtitle editor can — and an export with no import is a one-way door.
        Text("Import replaces every caption with the file's. A sidecar carries no word times, so highlighting stays off for what comes back until this recording is transcribed again.")
            .font(Type.detail).foregroundStyle(.secondary)
    }


    /// The font a caption is set in: the project's own, or the system's.
    ///
    /// **The file is copied into the project, not referenced.** `adoptMusic`'s argument
    /// exactly: a caption pointing at a `.ttf` on somebody's Desktop is a caption that changes
    /// when the file moves, and a project opened on another machine would silently fall back to
    /// a different width. Inside the package it travels with the recording.
    ///
    /// **A name rather than a preview of the type.** Rendering a sample means loading the font
    /// into this view, and the view is not where fonts are resolved — `TextArt` is, once, for
    /// both measurement and drawing. A second loader here is the second answer that seam exists
    /// to prevent.
    @ViewBuilder private var fontRow: some View {
        HStack(spacing: Space.snug) {
            Text("Font").font(Type.label)
            Spacer(minLength: Space.tight)
            (model.style.fontFilename.map { Text(verbatim: $0) } ?? Text("System"))
                .font(Type.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose\u{2026}") { chooseFont() }
            if model.style.fontFilename != nil {
                Button("System") {
                    model.setStyle(model.style.changing(fontFilename: .some(nil)))
                    onChange()
                }
            }
        }
        if let fontFailure = model.fontFailure {
            Label { Text(verbatim: fontFailure) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    private func chooseFont() {
        guard let source = Self.chooseFontFile() else { return }
        model.adoptFont(source, mediaURL: mediaURL)
        onChange()
    }

    /// The open panel, fonts only.
    @MainActor
    private static func chooseFontFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.font]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The open panel, sidecars only.
    @MainActor
    private static func chooseSidecar() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleFile.Format.allCases.compactMap {
            UTType(filenameExtension: $0.fileExtension)
        } + [.plainText]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Where to write a sidecar, starting from the recording's name.
    @MainActor
    private static func sidecarDestination(format: SubtitleFile.Format,
                                           defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A colour's own components, in the space the renderer draws in.
    ///
    /// **Converted to sRGB rather than read raw.** A `Color` from the picker can be in the
    /// display's P3 space, and its raw components in that space are different numbers for the
    /// same colour — a red picked on a P3 display would export as a duller one. sRGB is what
    /// `CoreImageFrameRenderer` composites in and what the recording is pinned to.
    static func components(of colour: Color) -> (red: Double, green: Double, blue: Double) {
        let converted = NSColor(colour).usingColorSpace(.sRGB) ?? NSColor(colour)
        return (Double(converted.redComponent), Double(converted.greenComponent),
                Double(converted.blueComponent))
    }

    private func styleChanging(height: Double? = nil, inset: Double? = nil,
                               plate: Double? = nil) -> CaptionStyle {
        model.style.changing(heightFraction: height, bottomInsetFraction: inset,
                             backgroundOpacity: plate)
    }
}
