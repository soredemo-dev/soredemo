import AVFoundation
import Compositing
import Foundation
import Framing
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
    static func pictures(for steps: [RecordedStep], anchor: EpochAnchor?, edit: EditTimeline) -> [Picture] {
        guard let anchor else { return [] }
        return steps.compactMap { step in
            guard let press = FramingPlanReader.offset(of: step.origin, from: anchor),
                  let pressOutput = edit.outputTime(atSource: press) else { return nil }
            let before = Nanoseconds(press.rawValue - leadIn.rawValue)
            // Just before the press where there is a "before" in the video; the press itself at
            // the very start, or right after a cut.
            let output = before.rawValue >= 0 ? (edit.outputTime(atSource: before) ?? pressOutput) : pressOutput
            return Picture(step: GuideStep(label: step.label, role: step.role, application: step.application),
                           outputTime: output)
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
