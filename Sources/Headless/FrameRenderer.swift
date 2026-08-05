import CoreMedia
import CoreVideo
import Foundation
import Render

/// **The seam the compositor implementation happens behind, built before either implementation
/// can win.**
///
/// The card and its rounded corners can be drawn with Core Image filters or with a hand-written
/// Metal pass. Which one is faster at 4K is not known, and the decision is deliberately deferred
/// until it can be measured. That deferral is only real if this seam exists FIRST: without it,
/// whichever implementation gets written first wins by default, because by the time a 4K frame
/// time can be measured, replacing the other one is a rewrite, and the cost of the rewrite becomes
/// the argument for not doing it. The measurement would then never touch the answer.
///
/// **Not "its shadow" — corrected here, code review (Task 8, fix round 1).** This line used to
/// list a shadow among what gets drawn behind this seam. `RenderPlan`/`StageStyle` carry
/// `shadowRadius`/`shadowOpacity`, but today's only implementation, `CoreImageFrameRenderer`,
/// never reads either — see that file's own header and `docs/ARCHITECTURE.md` D6a for the
/// modelled/persisted/unread disposition.
///
/// `MasterWriting` (`Soredemo/Capture/MasterWriter.swift`) settled the same shape earlier, and that
/// seam was re-decided on evidence hours later — precisely because it existed first.
public enum FrameRenderingError: Error, CustomStringConvertible {
    case noRenderDevice

    // `CustomStringConvertible`, added at the final whole-branch review for the same
    // reason `MP4Exporter.ExportError` carries one: on every machine where the test
    // suite passes, `MTLCreateSystemDefaultDevice()` never returns `nil`, so this case
    // is never constructed by the code that throws it and the one place that named
    // it (`catch FrameRenderingError.noRenderDevice` in
    // `Tests/HeadlessTests/CoreImageFrameRendererTests.swift`) never runs either — the
    // entry rule was satisfied by an unreachable branch, not by exercise.
    // `theNoRenderDeviceCaseDescribesItself` in that same file now constructs this
    // case directly, independent of whether a GPU is present, and asserts on it.
    public var description: String {
        switch self {
        case .noRenderDevice:
            "no Metal render device is available (MTLCreateSystemDefaultDevice() returned nil) — CoreImageFrameRenderer needs one to build its CIContext"
        }
    }
}

/// Draws one frame from a plan. **No Core Image type, no Metal type, no pixel-buffer type in this
/// file** — that is enforced by a test (`RenderSeamTests.swift`), not by care.
public nonisolated protocol FrameRendering: Sendable {
    /// `CVPixelBuffer` in and out. CoreVideo, not Core Image and not Metal — the one vocabulary
    /// both candidate implementations already speak, so the signature chooses neither.
    func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws
}
