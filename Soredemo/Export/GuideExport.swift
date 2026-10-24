import AVFoundation
import Compositing
import Foundation
import Framing
import Geometry
import Render
import Timeline

/// The take as a step-by-step guide: `guide.md`, `guide.html` and a picture per step, in one
/// folder a person can drop into their documentation.
///
/// **The words come from `StepGuide`, which escapes them; the pictures from `StillFrameExporter`,
/// through the export's own composition.** This file only decides which steps survive the cut and
/// when each picture is taken. See `docs/design/2026-10-25-a-guide-from-the-steps.md`.
enum GuideExport {
    /// One step as the guide shows it, and where in the EDITED video its picture is taken.
    struct Picture: Equatable {
        let step: GuideStep
        let outputTime: Nanoseconds
    }

    /// How far before the press its picture is taken: the target is on screen and what it opens
    /// is not yet over it, and the camera — `ZoomBlock.preRoll` early — is already there.
    static let leadIn = Nanoseconds(150_000_000)

    /// The steps that survive `edit`, in order, each with its picture's output time.
    ///
    /// **A step whose press was cut from the video is not in the guide**: a guide that tells
    /// somebody to click what the video no longer shows describes a different recording. Empty
    /// without an anchor, which is what turns a step's instant into a time in the video.
    ///
    /// `highlight` places a step's element on its picture — `highlighter(...)` in the app, through
    /// the compositor's own frame plan; a test hands in its own to see what it was asked.
    static func pictures(for steps: [RecordedStep], anchor: EpochAnchor?, edit: EditTimeline,
                         highlight: (NormalizedFrame, Nanoseconds) -> GuideHighlight? = { _, _ in nil })
        -> [Picture] {
        guard let anchor else { return [] }
        return steps.compactMap { step in
            guard let press = FramingPlanReader.offset(of: step.origin, from: anchor),
                  let pressOutput = edit.outputTime(atSource: press) else { return nil }
            let before = Nanoseconds(press.rawValue - leadIn.rawValue)
            // Just before the press where there is a "before" in the video; the press itself at
            // the very start, or right after a cut.
            let output = before.rawValue >= 0 ? (edit.outputTime(atSource: before) ?? pressOutput) : pressOutput
            return Picture(step: GuideStep(label: step.label, role: step.role, application: step.application,
                                           highlight: step.frame.flatMap { highlight($0, output) }),
                           outputTime: output)
        }
    }

    /// Where an element is on the picture taken at `outputTime`: the compositor's frame plan for
    /// that moment — crop, card and camera, the road every rendered frame takes — and the
    /// element's corners through it (`WalkthroughHotspot`). Reads the compositor's statics, which
    /// the open project has published, exactly as the pictures themselves do.
    static func highlighter(outputWidth: Int, outputHeight: Int, sourceWidth: Int, sourceHeight: Int)
        -> (NormalizedFrame, Nanoseconds) -> GuideHighlight? {
        let compositor = StageCompositor()
        return { frame, outputTime in
            let plan = compositor.framePlan(at: CMTime(value: outputTime.rawValue, timescale: 1_000_000_000),
                                            outputWidth: outputWidth, outputHeight: outputHeight,
                                            sourceWidth: sourceWidth, sourceHeight: sourceHeight)
            return WalkthroughHotspot.box(of: frame, in: plan).map {
                GuideHighlight(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
        }
    }

    /// The sentences, in the app's language. `{label}` and `{app}` are filled — escaped — by
    /// `StepGuide`, so a translator moves them where their language puts them.
    static var phrases: GuidePhrases {
        GuidePhrases(click: String(localized: "Click {label}."),
                     clickIn: String(localized: "Click {label} in {app}."),
                     choose: String(localized: "Choose {label}."),
                     chooseIn: String(localized: "Choose {label} in {app}."),
                     pictureAlt: String(localized: "Step {number}"))
    }

    /// The words around a walkthrough's steps, in the app's language.
    static var walkthroughWords: WalkthroughWords {
        WalkthroughWords(stepOf: String(localized: "Step {number} of {total}"),
                         next: String(localized: "Next"), back: String(localized: "Back"),
                         finished: String(localized: "You have finished this walkthrough."),
                         startAgain: String(localized: "Start again"))
    }

    /// Writes the take as one walkthrough page at `file`: the same pictures as the guide, inlined,
    /// so the page is a single file that fetches nothing.
    ///
    /// **The pictures are made in a scratch folder the system chooses beside `file`**
    /// (`itemReplacementDirectory`), not under a name made up here: this target reads no ambient
    /// randomness, and the system's folder is removed with everything in it afterwards.
    static func writeWalkthrough(_ pictures: [Picture], title: String, asset: AVAsset,
                                 outputWidth: Int, outputHeight: Int, to file: URL) async throws {
        let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: file, create: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var inlined: [String] = []
        for (index, picture) in pictures.enumerated() {
            let png = scratch.appending(path: StepGuide.pictureName(for: index + 1))
            try await StillFrameExporter.export(
                asset: asset, at: CMTime(value: picture.outputTime.rawValue, timescale: 1_000_000_000),
                to: png, outputWidth: outputWidth, outputHeight: outputHeight)
            inlined.append("data:image/png;base64," + (try Data(contentsOf: png)).base64EncodedString())
        }
        try WalkthroughDocument.html(title: title, steps: pictures.map(\.step), pictures: inlined,
                                     phrases: phrases, words: walkthroughWords)
            .write(to: file, atomically: true, encoding: .utf8)
    }

    /// Writes the folder. The pictures first, so a guide whose pictures could not be made is not
    /// left behind pointing at files that are not there.
    static func write(_ pictures: [Picture], title: String, asset: AVAsset,
                      outputWidth: Int, outputHeight: Int, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, picture) in pictures.enumerated() {
            try await StillFrameExporter.export(
                asset: asset, at: CMTime(value: picture.outputTime.rawValue, timescale: 1_000_000_000),
                to: folder.appending(path: StepGuide.pictureName(for: index + 1)),
                outputWidth: outputWidth, outputHeight: outputHeight)
        }
        let steps = pictures.map(\.step)
        try StepGuide.markdown(title: title, steps: steps, phrases: phrases)
            .write(to: folder.appending(path: "guide.md"), atomically: true, encoding: .utf8)
        try StepGuide.html(title: title, steps: steps, phrases: phrases)
            .write(to: folder.appending(path: "guide.html"), atomically: true, encoding: .utf8)
    }
}
