import CoreVideo
import Foundation
import Render

/// Errors from a `FrameRendering` implementation. `RenderPlan`/`StageStyle` carry
/// `shadowRadius`/`shadowOpacity`, but no implementation behind this seam draws a shadow.
enum FrameRenderingError: Error, CustomStringConvertible {
    case noRenderDevice

    // `CustomStringConvertible` so the case can be asserted on directly; on a machine with a GPU
    // it is never constructed.
    public var description: String {
        switch self {
        case .noRenderDevice:
            "no Metal render device is available (MTLCreateSystemDefaultDevice() returned nil) — CoreImageFrameRenderer needs one to build its CIContext"
        }
    }
}

/// Draws one frame from a plan. No Core Image or Metal type may appear in this file; a test
/// enforces it.
// `public` because it is the TYPE of `StageCompositor.renderer`, which the app tier sets
// (`StageWindow`). Phase 3A-4 narrowed it and the compiler refused — that refusal is the
// measurement: this protocol is genuinely part of the exported surface, where `CursorArt`
// and `HeadlessGeometryBridge`, narrowed in the same pass, were not.
public nonisolated protocol FrameRendering: Sendable {
    /// `CVPixelBuffer` in and out: the one vocabulary every candidate implementation speaks.
    func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws
}
