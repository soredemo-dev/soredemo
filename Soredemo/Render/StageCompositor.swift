import AVFoundation
import CoreVideo
import Foundation
import Render

/// The `AVVideoCompositing` conformance. **Owns no policy**: it asks the planner for a plan and
/// hands it to a renderer. Everything it decides is which frame is being drawn and when.
///
/// **`newPixelBuffer()`, not `newReadOnlyPixelBuffer()`.** The brief that specified this file
/// hedged on which name to call. Checked directly against the macOS 27.0 SDK header
/// (`AVVideoCompositing.h`): `newPixelBuffer` is declared on `AVVideoCompositionRenderContext` and
/// is `API_DEPRECATED("Use newReadOnlyPixelBuffer() instead", macos(10.9, 27.0), ...)` — the
/// successor name occurs exactly once in the entire SDK, inside that deprecation message, and is
/// declared on no type anywhere. `newReadOnlyPixelBuffer()` does not exist to call. Because the
/// deprecation floor (27.0) is above this project's deployment target (26.0, `ARCHITECTURE.md`
/// D2), `newPixelBuffer()` produces no deprecation warning here — this is not a D6b-27 row, it is
/// simply the only name that exists.
///
/// **`CVReadOnlyPixelBuffer`, found by the compiler rather than by any header or interface file —
/// not anticipated by the brief at all.** This SDK's `AVAsynchronousVideoCompositionRequest
/// .sourceReadOnlyPixelBuffer(byTrackID:)` (the successor the header names for the now-deprecated
/// `sourceFrameByTrackID:`) returns `CVReadOnlyPixelBuffer`, a type declared in no C header and no
/// `.swiftinterface` findable on this machine — its shape was established by `-typecheck`ing
/// single-member probes and reading the compiler's own type-mismatch diagnostics, not by reading
/// documentation. `.size: CVImageSize` (`.width`/`.height: Int`) supplies `sourceWidth`/
/// `sourceHeight` below. `withUnsafeBuffer<R>(_:)` hands a plain `CVPixelBuffer` into a closure for
/// its duration — the one public route back to the type `FrameRendering` (Task 3's seam) actually
/// speaks; the underlying buffer's own `unsafeBuffer` accessor is `internal` on
/// `CVBufferRepresentable` and unreachable from here. `request.finish(withComposedPixelBuffer:)` —
/// the same Swift name the brief used — turns out to want a `CVReadOnlyPixelBuffer` too, so the
/// freshly rendered `destination` (still a plain `CVPixelBuffer` from `newPixelBuffer()`) is
/// wrapped with `CVReadOnlyPixelBuffer(unsafeBuffer:)` before being handed back.
nonisolated final class StageCompositor: NSObject, AVVideoCompositing {
    /// Set once before the composition is handed to AVFoundation. `nonisolated(unsafe)` for the
    /// same reason `CaptureSession`'s writer references are: AVFoundation calls back on its own
    /// queue and the value is published before any callback can see it.
    nonisolated(unsafe) static var renderer: (any FrameRendering)?
    nonisolated(unsafe) static var style: StageStyle = .default

    let sourcePixelBufferAttributes: [String: any Sendable]? =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    private nonisolated(unsafe) var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let trackID = request.sourceTrackIDs.first?.int32Value,
              let source = request.sourceReadOnlyPixelBuffer(byTrackID: trackID),
              let context = renderContext,
              let destination = context.newPixelBuffer(),
              let renderer = Self.renderer else {
            request.finish(with: CompositorError.notConfigured)
            return
        }
        let plan = StagePlanner.plan(
            outputWidth: Int(context.size.width), outputHeight: Int(context.size.height),
            sourceWidth: source.size.width, sourceHeight: source.size.height,
            style: Self.style)
        do {
            // `source` is read-only, and `FrameRendering.render(_:source:into:)` — Task 3's seam —
            // asks for a plain `CVPixelBuffer`. `withUnsafeBuffer` is the one public bridge between
            // the two, scoped to this closure so nothing holds the unwrapped buffer past the call
            // that actually reads it.
            try source.withUnsafeBuffer { sourceBuffer in
                try renderer.render(plan, source: sourceBuffer, into: destination)
            }
            request.finish(withComposedPixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: destination))
        } catch {
            request.finish(with: error)
        }
    }

    enum CompositorError: Error { case notConfigured }
}
