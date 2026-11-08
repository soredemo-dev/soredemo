import Foundation
import Observation
import Compositing
import Framing
import Geometry
import Overlays
import Project
import Render
import Timeline
import Variants

/// Everything the editor window decides about one recording, and the two conversions between that
/// and a project file.
///
/// **The view model `StageWindow` did not have.** Its state and its save and open logic were
/// `@State` properties and private functions of a `View` — 2088 lines — so the one thing a project
/// file must never do, lose a decision between saving and opening, could not be tested without a
/// window. `EditorViewModelTests.aSavedProjectOpensExactlyAsItWasSaved` is what this split buys.
/// See `docs/design/2026-09-27-organising-the-project.md`.
///
/// **What stays in the view:** the player, the preview composition, what the inspector is showing
/// — state about the WINDOW, which a project file has no opinion about.
@Observable
final class EditorViewModel {
    // MARK: - the models each part of the editor owns

    /// Every framing decision the gate made, and the reviewer's own.
    let review = FramingReviewModel()
    /// The stage's look and the cursor's.
    let stageStyle = StageStyleModel()
    /// What survives editing — clips, cuts, speeds, and the zoom adjustments made on the lane.
    let timeline = TimelineEditorModel()
    let captions = CaptionsModel()
    /// Titles and notes drawn over the picture.
    let texts = TextOverlaysModel()
    /// Parts of the recording a person has hidden.
    let redactions = RedactionsModel()
    let annotations = AnnotationsModel()
    let chapters = ChaptersModel()
    /// What the person did, step by step, read from the same log as the zooms.
    let steps = RecordedStepsModel()
    /// The cuts the producers propose, for the Cuts tab. Read from the same log as the steps.
    let cuts = CutProposalsModel()
    /// The person's own agent, editing this recording from the Agent tab.
    let agent = AgentPanelModel()
    /// Notes pinned on the recording, for the agent — or anyone — to address.
    let notes = NotesModel()

    // MARK: - authored values

    /// Where the camera sits on the stage.
    var cameraStyle = CameraOverlayStyle.default
    /// The part of the recording used at all.
    var crop = CropRect.whole
    /// The output shape. Drives the preview as well as the export.
    var variant = AspectVariant.landscape
    /// Whether the shape on screen is one a person picked or restored, rather than the starting
    /// value — set at both places that make a choice, so a future default has one flag to read.
    var chosenShapeDeliberately = false
    /// How loud each recorded source is. See `AudioMix`.
    var audioMix = AudioMix.unchanged
    /// Noise removal on the microphone. **`nil` is off**, and off is the default.
    var noiseReduction: NoiseReduction.Settings?
    /// The music bed. Its file lives in the package, so this is a filename.
    var music = MusicBed.none
    /// How much of the derived zoom to use, over the whole recording.
    var zoomIntensity = FramingDepth.neutralIntensity
    /// How fast the camera moves between framings.
    var cameraPace = CameraPace.standard

    // MARK: - facts about the recording

    /// The recording's own pixel size — both dimensions, because `Match Recording` rebuilds a
    /// SHAPE from it and a short side alone cannot say what shape it is.
    var recordingSize = (width: 1920, height: 1080)

    /// The recording's short side in pixels, so `Match Recording` has something to match. 1080
    /// until the recording loads, which is what the export used to be pinned to anyway.
    var recordingShortSide = 1080
    var recordingFrameRate = 60

    // MARK: - how it is exported

    /// Held here, not by the save panel, so switching the panel's format popup does not reset
    /// them.
    var gifSettings = GIFSettings.balanced
    var quality = ExportQuality.best
    /// **The recording's own size, not 1080p.** A 3024×1964 capture exported at a 1080p default
    /// came out 1662×1080 — six pixels in ten discarded, and the one control that could undo it
    /// defaulted to the wrong rung.
    var resolution = ExportResolution.matchRecording
    var codec = ExportCodec.h264
    /// Matching by default, because a capture's rate is a decision somebody already made.
    var frameRate = ExportFrameRate.matchRecording

    /// The exported picture's size, for the shape and resolution chosen.
    var outputSize: (width: Int, height: Int) {
        Self.size(for: variant, resolution: resolution, recordingShortSide: recordingShortSide)
    }

    /// **A destination, standing for the four settings.** Reading it answers "which preset are
    /// these four", `nil` for Custom; choosing one sets all four and then gets out of the way, so
    /// changing any of them afterwards reads back as Custom rather than claiming "Web" for an
    /// export that no longer is. See `ExportPreset`.
    var preset: ExportPreset? {
        get { ExportPreset.matching(resolution: resolution, codec: codec, frameRate: frameRate,
                                    quality: quality) }
        set {
            guard let chosen = newValue else { return }
            resolution = chosen.resolution
            codec = chosen.codec
            frameRate = chosen.frameRate
            quality = chosen.quality
        }
    }

    /// **Snapped rather than left dangling.** A person who chose H.264 and then made the
    /// background transparent has a selection no longer offered; SwiftUI would show an empty
    /// picker and the export would refuse. Moving it to the smallest format that carries alpha is
    /// visible — the picker changes in front of them. See `TransparentExport`.
    func keepCodecAbleToCarryTransparency() {
        if stageStyle.isTransparent, !codec.carriesTransparency {
            codec = TransparentExport.codecsThatCarryIt[0]
        }
    }

    /// Roughly how large the export will be — of the marked section when there is one, since
    /// that is what the button will write.
    var estimatedExportBytes: Int {
        quality.estimatedBytes(
            outputWidth: outputSize.width, outputHeight: outputSize.height,
            frameRate: frameRate.frames(recording: recordingFrameRate),
            seconds: Double(timeline.editForExport.outputDuration.rawValue) / 1_000_000_000,
            codec: codec)
    }

    /// The chapters an export of `edit` carries — through the EXPORT's edit, so a marked section
    /// carries only the chapters inside it.
    func exportChapters(through edit: EditTimeline) -> [PlacedChapter] {
        chapters.track.outputChapters(through: edit, outputDuration: edit.outputDuration).placed
    }

    /// **Re-rendered at the variant's own dimensions, never cropped from the landscape one.**
    /// `StagePlanner` fits and never fills, so a portrait export of a landscape recording
    /// letterboxes rather than cutting the sides off — the part of the screen the demo was
    /// happening in is often exactly what a crop would remove.
    /// **The export size, which used to be the constant 1920.** Measured on a real recording:
    /// the capture was 3024×1964 and every export came out 1920×1080, so six pixels in ten were
    /// thrown away and there was no control that could ask for them back. `ExportResolution`
    /// picks by short side, which is the only ladder that describes a portrait output as well
    /// as a landscape one.
    static func size(for variant: AspectVariant, resolution: ExportResolution,
                     recordingShortSide: Int) -> (width: Int, height: Int) {
        let shape = variant.dimensions(longestEdge: 1920)
        let aspect = Double(shape.width) / Double(max(shape.height, 1))
        return resolution.size(forAspect: aspect, recordingShortSide: recordingShortSide)
    }

    /// The size the PREVIEW composites at — the export's, capped.
    ///
    /// **A preview was compositing at the recording's own size**: 6.86 Mpixels a frame at 60 fps
    /// for a 3492 x 1964 recording, to fill a pane about 900 points wide. A custom compositor
    /// that misses AVFoundation's per-frame deadline has the frame DROPPED and signalled as
    /// `-12784`, which is the stutter and the console line together.
    ///
    /// **A cap, never an increase**, and the export does not come through here at all. Why the
    /// preview is still an `AVVideoCompositing` when four of five sibling projects render their
    /// own, and what the cap costs, are in
    /// `docs/design/2026-09-22-the-preview-composited-at-export-resolution.md`.
    static func previewSize(for variant: AspectVariant, resolution: ExportResolution,
                            recordingShortSide: Int) -> (width: Int, height: Int) {
        let full = size(for: variant, resolution: resolution, recordingShortSide: recordingShortSide)
        let short = min(full.width, full.height)
        guard short > previewShortSideCap, short > 0 else { return full }
        let scale = Double(previewShortSideCap) / Double(short)
        return (evenDown(Double(full.width) * scale), evenDown(Double(full.height) * scale))
    }

    /// 1080 on the short side. A standard rung rather than an invented number, and above what
    /// any editor pane on a current Mac displays — the pane is a fraction of a window that is a
    /// fraction of the screen. Somebody on a 6K display with the inspector closed can out-resolve
    /// it, and would see a slightly soft preview of a sharp export.
    static let previewShortSideCap = 1080

    /// Even, because an odd buffer dimension is where a stray column of green comes from — the
    /// same rule `ExportFormat.even` keeps for the export.
    private static func evenDown(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return max(2, rounded - (rounded % 2))
    }

    // MARK: - the project on disk

    /// Where this recording has been saved, or `nil` for a scratch recording.
    var savedPackage: URL?
    /// The edit as it was when last saved or opened, so "has anything changed" compares against
    /// what is on disk rather than against nothing.
    var savedEdit = EditState.untouched
    var projectStatus: String?

    /// **True when closing would lose something.** A scratch recording always would.
    func hasUnsavedChanges(hasCamera: Bool) -> Bool {
        savedPackage == nil || currentEditState(hasCamera: hasCamera) != savedEdit
    }

    /// **The share of the output frame the recording occupies in the chosen shape**, from the
    /// CROPPED size — a crop re-frames every zoom exactly as a shape change does.
    var outputCoverage: Double {
        let cropped = crop.size(ofSourceWidth: recordingSize.width, sourceHeight: recordingSize.height)
        guard cropped.width > 0, cropped.height > 0 else { return 1 }
        return variant.coverage(ofSourceAspect: Double(cropped.width) / Double(cropped.height))
    }

    // MARK: - to and from a project file

    /// Everything a person decided, gathered from the models that hold it.
    ///
    /// **Assembled here rather than held here**, because each model owns its own part and a
    /// second copy would be a second answer. `hasCamera`, because the placement of a camera track
    /// that does not exist is not a decision anyone made.
    func currentEditState(hasCamera: Bool) -> EditState {
        EditState(
            timeline: timeline.editToSave,
            audioMix: audioMix,
            zoomAdjustmentData: timeline.zoomAdjustments.isEmpty
                ? nil : try? EditState.encoding(timeline.zoomAdjustments),
            framingOverrideData: review.overrides.isEmpty
                ? nil : try? EditState.encoding(review.overrides),
            styleData: try? EditState.encoding(stageStyle.style),
            outputShapeName: variant.name,
            captionTrackData: captions.track.isEmpty
                ? nil : try? EditState.encoding(captions.track),
            captionStyleData: captions.track.isEmpty
                ? nil : try? EditState.encoding(captions.style),
            burnsInCaptions: captions.burnsIn ? true : nil,
            textTrackData: texts.track.isEmpty ? nil : try? EditState.encoding(texts.track),
            redactionTrackData: redactions.track.isEmpty
                ? nil : try? EditState.encoding(redactions.track),
            annotationTrackData: annotations.track.isEmpty
                ? nil : try? EditState.encoding(annotations.track),
            cursorStyleData: try? EditState.encoding(stageStyle.cursor),
            cameraStyleData: hasCamera ? try? EditState.encoding(cameraStyle) : nil,
            cropData: crop.isWhole ? nil : try? EditState.encoding(crop),
            hidesKeystrokes: stageStyle.showsKeystrokes ? nil : true,
            musicData: music == .none ? nil : try? EditState.encoding(music),
            // Neutral is not a decision, so an untouched project stays untouched on disk.
            zoomIntensity: zoomIntensity == FramingDepth.neutralIntensity ? nil : zoomIntensity,
            // Standard is not a decision either.
            cameraPace: cameraPace == .standard ? nil : cameraPace.rawValue,
            // Absent means off, so a project nobody asked has nothing to say about it.
            noiseReductionData: noiseReduction.flatMap { try? EditState.encoding($0) },
            // An empty list is nothing to say either.
            spokenTerms: captions.spokenTerms.isEmpty ? nil : captions.spokenTerms,
            chapterTrackData: chapters.track.isEmpty ? nil : try? EditState.encoding(chapters.track),
            dismissedCutData: timeline.dismissedCuts.isEmpty
                ? nil : try? EditState.encoding(CutProposal.Key.fileOrder(timeline.dismissedCuts)),
            notesData: notes.board.notes.isEmpty ? nil : try? EditState.encoding(notes.board))
    }

    /// Applies a saved edit to the models, and returns the parts that could not be read.
    ///
    /// **Every part is optional and an absent one is left alone**, so a project written before a
    /// field existed opens with that part at its default rather than cleared. A decode that FAILS
    /// is reported: a person whose zoom corrections were silently dropped would redo them and save
    /// over the file that still had them.
    @discardableResult
    func restore(_ edit: EditState) -> [String] {
        var failures: [String] = []
        if let saved = edit.timeline { timeline.restoreSavedEdit(saved) }
        audioMix = edit.audioMix
        do {
            noiseReduction = try EditState.decoding(edit.noiseReductionData,
                                                    as: NoiseReduction.Settings.self)
        } catch { failures.append("noise removal") }
        do {
            if let adjustments = try EditState.decoding(edit.zoomAdjustmentData,
                                                        as: [ZoomAdjustment].self) {
                timeline.restoreZoomAdjustments(adjustments)
            }
        } catch { failures.append("zoom adjustments") }
        do {
            if let overrides = try EditState.decoding(edit.framingOverrideData,
                                                      as: [FramingOverride].self) {
                review.restoreOverrides(overrides)
            }
        } catch { failures.append("framing decisions") }
        do {
            if let style = try EditState.decoding(edit.styleData, as: StageStyle.self) {
                stageStyle.restore(style)
            }
        } catch { failures.append("the look") }
        do {
            if let cursor = try EditState.decoding(edit.cursorStyleData, as: CursorStyle.self) {
                stageStyle.restoreCursor(cursor)
            }
        } catch { failures.append("the cursor") }
        stageStyle.setShowsKeystrokes(edit.hidesKeystrokes != true)
        // Clamped on the way in: it arrives from a file, which is rule 8's case, and a saved
        // negative would make every depth the ceiling rather than failing visibly.
        zoomIntensity = min(max(edit.zoomIntensity ?? FramingDepth.neutralIntensity, 0),
                            FramingDepth.maximumIntensity)
        // An unknown name is the pace this build knows best, not a refusal to open.
        cameraPace = edit.cameraPace.flatMap(CameraPace.init(rawValue:)) ?? .standard
        do {
            if let saved = try EditState.decoding(edit.musicData, as: MusicBed.self) {
                music = saved
            }
        } catch { failures.append("the music") }
        do {
            if let camera = try EditState.decoding(edit.cameraStyleData,
                                                   as: CameraOverlayStyle.self) {
                cameraStyle = camera
            }
        } catch { failures.append("the camera") }
        do {
            if let saved = try EditState.decoding(edit.cropData, as: CropRect.self) {
                crop = saved
            }
        } catch { failures.append("the crop") }
        if let name = edit.outputShapeName {
            // **The matching shape is rebuilt rather than looked up.** It is deliberately not
            // in `all` — being in a list is exactly what would stop it depending on the
            // recording's size, which is the thing that makes it match.
            if name == AspectVariant.matchRecordingName,
               let own = AspectVariant.matching(width: recordingSize.width,
                                                height: recordingSize.height) {
                variant = own
                chosenShapeDeliberately = true
            } else if let shape = AspectVariant.all.first(where: { $0.name == name }) {
                variant = shape
                chosenShapeDeliberately = true
            }
        }
        do {
            // The style is restored even when the track failed to decode, so a person who
            // transcribes again does not also have to redo how it looks.
            let style = try EditState.decoding(edit.captionStyleData, as: CaptionStyle.self)
            if let track = try EditState.decoding(edit.captionTrackData, as: CaptionTrack.self) {
                captions.restore(track: track, style: style ?? captions.style,
                                 burnsIn: edit.burnsInCaptions ?? false)
            } else if let style {
                captions.setStyle(style)
            }
            // Restored whether or not a track came back: the names are a person's own list and
            // outlive the transcript that prompted them.
            captions.restoreTerms(edit.spokenTerms ?? [])
        } catch { failures.append("the captions") }
        do {
            if let track = try EditState.decoding(edit.textTrackData, as: TextTrack.self) {
                texts.restore(track)
            }
        } catch { failures.append("the text") }
        do {
            if let track = try EditState.decoding(edit.redactionTrackData,
                                                  as: RedactionTrack.self) {
                redactions.restore(track)
            }
            // **A redaction that failed to decode is reported louder than the rest**, because
            // opening a project and not being told the covers are gone is how a key gets
            // published. The shared failure list is the mechanism.
        } catch { failures.append("the hidden regions") }
        do {
            if let track = try EditState.decoding(edit.annotationTrackData,
                                                  as: AnnotationTrack.self) {
                annotations.restore(track)
            }
        } catch { failures.append("the marks") }
        do {
            if let track = try EditState.decoding(edit.chapterTrackData, as: ChapterTrack.self) {
                chapters.restore(track)
            }
        } catch { failures.append("the chapters") }
        do {
            if let keys = try EditState.decoding(edit.dismissedCutData, as: [CutProposal.Key].self) {
                timeline.restoreDismissedCuts(Set(keys))
            }
        } catch { failures.append("the dismissed cut suggestions") }
        do {
            if let board = try EditState.decoding(edit.notesData, as: NoteBoard.self) {
                notes.restore(board)
            }
        } catch { failures.append("the pinned notes") }
        savedEdit = edit
        if !failures.isEmpty {
            projectStatus = String(localized: "Opened, but could not read \(failures.joined(separator: ", ")).")
        }
        return failures
    }

    /// **The lane's blocks, from the same call the camera makes.** Extracted the moment there
    /// were two callers: `load()` and the intensity dial. A second derivation with its own
    /// arguments is how a lane comes to disagree with the picture it is describing.
    func refreshDerivedZooms() {
        timeline.setDerivedZooms(ZoomBlock.blocks(
            for: review.plan.framedClicks(with: review.overrides,
                                          pointerFallbackRevision: review.fallbackRevision),
            coverage: outputCoverage, intensity: zoomIntensity))
    }
}
