import CoreVideo
import Foundation
import Render

/// Errors from a `FrameRendering` implementation. `RenderPlan`/`StageStyle` carry
/// `shadowRadius`/`shadowOpacity`, but no implementation behind this seam draws a shadow.
public enum FrameRenderingError: Error, CustomStringConvertible {
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
public nonisolated protocol FrameRendering: Sendable {
    /// `CVPixelBuffer` in and out: the one vocabulary every candidate implementation speaks.
    func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws
}
