import Testing
import Foundation
import Compositing
import Framing
import Geometry
import Overlays
import Project
import Render
import Timeline
import Variants
@testable import Soredemo

private func ns(_ seconds: Double) -> Nanoseconds { Nanoseconds(Int64((seconds * 1000).rounded()) * 1_000_000) }
private func encoded<Value: Encodable>(_ value: Value) -> Data { try! EditState.encoding(value) }

/// **A project with a decision in every field** — none at its default, so a field that is not
/// written on save or not read on open changes the result. `everyFieldOfTheFixtureIsSet` keeps
/// it that way when `EditState` grows.
private let epoch = BootEpoch(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!)
private let everything = EditState(
    timeline: EditTimeline.whole(duration: ns(20)).removing(sourceRange: ns(5).rawValue..<ns(8).rawValue),
    audioMix: AudioMix().setting(.microphone, muted: true),
    zoomAdjustmentData: encoded([ZoomAdjustment(origin: HostInstant(epoch: epoch, hostTime: ns(7)),
                                                startDelta: ns(0.25))]),
    framingOverrideData: encoded([FramingOverride(epoch: epoch, instant: ns(3), action: .suppress)]),
    styleData: encoded(StageStyle(insetFraction: 0.1, cornerRadius: 24, shadowRadius: 20,
                                  shadowOpacity: 0.5, background: .solid(red: 0.2, green: 0.3, blue: 0.4))),
    outputShapeName: AspectVariant.portrait.name,
    captionTrackData: encoded(CaptionTrack(cues: [CaptionCue(text: "Hello", start: ns(1), end: ns(2))])),
    captionStyleData: encoded(CaptionStyle.default.changing(heightFraction: 0.07)),
    burnsInCaptions: true,
    textTrackData: encoded(TextTrack().adding(text: "Title", start: ns(2), end: ns(4))),
    redactionTrackData: encoded(RedactionTrack().adding(x: 0.1, y: 0.1, width: 0.2, height: 0.2,
                                                        start: ns(1), end: ns(2))),
    annotationTrackData: encoded(AnnotationTrack().adding(shape: .arrow, startX: 0.2, startY: 0.3,
                                                          endX: 0.6, endY: 0.7, start: ns(3), end: ns(5))),
    cursorStyleData: encoded(CursorStyle.default.changing(scale: 1.5)),
    cameraStyleData: encoded(CameraOverlayStyle.default.changing(x: 0.2)),
    cropData: encoded(CropRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)),
    hidesKeystrokes: true,
    musicData: encoded(MusicBed(filename: "bed.m4a")),
    zoomIntensity: 1.4,
    cameraPace: CameraPace.snappy.rawValue,
    noiseReductionData: encoded(NoiseReduction.Settings(strength: 2, floor: 0.1)),
    spokenTerms: ["Soredemo"],
    chapterTrackData: encoded(ChapterTrack().adding(title: "Intro", start: ns(0))))

/// The fields of two edits that differ, by name — so a failure says which decision was lost.
private func differingFields(_ a: EditState, _ b: EditState) -> [String] {
    zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children).compactMap { left, right in
        String(describing: left.value) == String(describing: right.value) ? nil : left.label
    }
}

/// Opened the way `StageWindow.load()` opens one: the recording's length first, then the edit.
@MainActor private func opened(_ edit: EditState) -> (EditorViewModel, failures: [String]) {
    let model = EditorViewModel()
    model.timeline.load(duration: 20)
    let failures = model.restore(edit)
    return (model, failures)
}

/// Serialized: the sub-models publish to `StageCompositor`'s process-global statics.
@MainActor @Suite(.serialized) struct EditorViewModelTests {
    @Test func everyFieldOfTheFixtureIsSet() {
        #expect(everything.audioMix.changesAnything)
        for child in Mirror(reflecting: everything).children where child.label != "audioMix" {
            let isNil = Mirror(reflecting: child.value).displayStyle == .optional
                && Mirror(reflecting: child.value).children.isEmpty
            #expect(!isNil, "the fixture leaves `\(child.label ?? "?")` unset, so the round trip cannot test it")
        }
    }

    /// **The one thing a project file must never do: lose a decision between saving and opening.**
    @Test func aSavedProjectOpensExactlyAsItWasSaved() {
        let (model, failures) = opened(everything)
        #expect(failures.isEmpty)
        let resaved = model.currentEditState(hasCamera: true)
        #expect(differingFields(resaved, everything).isEmpty,
                "lost or changed between open and save: \(differingFields(resaved, everything))")
    }

    /// Opening a project and touching nothing is not a change, and must not ask to be saved.
    @Test func anOpenedProjectHasNothingUnsaved() {
        let (model, _) = opened(everything)
        model.savedPackage = URL(fileURLWithPath: "/tmp/project.soredemo")
        #expect(!model.hasUnsavedChanges(hasCamera: true))
    }

    /// A part that cannot be read is named, and does not take the rest of the project with it.
    @Test func anUnreadablePartIsNamedAndTheRestStillOpens() {
        var damaged = everything
        damaged.textTrackData = Data("not json".utf8)
        let (model, failures) = opened(damaged)
        #expect(failures == ["the text"])
        #expect(model.texts.track.isEmpty)
        #expect(model.chapters.track.chapters.map(\.title) == ["Intro"])
        #expect(model.projectStatus != nil)
    }

    /// A camera's placement is saved only when there is a camera to place.
    @Test func noCameraMeansNoCameraPlacementSaved() {
        let (model, _) = opened(everything)
        #expect(model.currentEditState(hasCamera: false).cameraStyleData == nil)
    }

    // MARK: - export choices

    /// Choosing a destination sets all four; changing one afterwards reads back as Custom rather
    /// than still claiming the destination.
    @Test func aPresetSetsAllFourAndAnyChangeMakesItCustom() {
        let model = EditorViewModel()
        model.preset = .message
        #expect(model.resolution == .p720 && model.codec == .h264)
        #expect(model.frameRate == .fps30 && model.quality == .small)
        #expect(model.preset == .message)
        model.quality = .best
        #expect(model.preset == nil)
        model.preset = nil
        #expect(model.quality == .best, "choosing Custom is not a thing to do, and must change nothing")
    }

    @Test func aTransparentStageMovesTheCodecToOneThatKeepsTheAlpha() {
        let model = EditorViewModel()
        model.codec = .h264
        model.keepCodecAbleToCarryTransparency()
        #expect(model.codec == .h264, "an opaque stage leaves the choice alone")
        model.stageStyle.restore(StageStyle(insetFraction: 0.06, cornerRadius: 18, shadowRadius: 32,
                                             shadowOpacity: 0.35, background: .transparent))
        model.keepCodecAbleToCarryTransparency()
        #expect(model.codec.carriesTransparency)
        #expect(model.codec == TransparentExport.codecsThatCarryIt[0])
    }

    /// The shape and the recording both reach the output size — a portrait of a recording whose
    /// short side is 1964, not the 1080 default the export used to be pinned to.
    @Test func theOutputSizeFollowsTheShapeAndTheRecording() {
        let model = EditorViewModel()
        model.recordingShortSide = 1964
        model.variant = .portrait
        model.resolution = .matchRecording
        let size = model.outputSize
        #expect(size.width < size.height)
        #expect(min(size.width, size.height) == 1964)
        model.resolution = .p720
        #expect(min(model.outputSize.width, model.outputSize.height) == 720)
    }

    /// A marked section carries only its own chapters, placed from its start.
    @Test func anExportOfASectionCarriesOnlyItsChapters() {
        let model = EditorViewModel()
        model.timeline.load(duration: 30)
        model.chapters.restore(ChapterTrack()
            .adding(title: "Before", start: ns(2))
            .adding(title: "Inside", start: ns(14))
            .adding(title: "After", start: ns(25)))
        let section = EditTimeline.whole(duration: ns(30)).trimmed(toSource: ns(10).rawValue..<ns(20).rawValue)
        let placed = model.exportChapters(through: section)
        #expect(placed.map(\.name) == ["Before", "Inside"])
        #expect(placed.map(\.start) == [ns(0), ns(4)])
    }

    @Test func theEstimateIsForWhatWillBeWritten() {
        let model = EditorViewModel()
        model.timeline.load(duration: 60)
        let whole = model.estimatedExportBytes
        #expect(whole > 0)
        model.quality = .small
        #expect(model.estimatedExportBytes < whole)
    }
}
