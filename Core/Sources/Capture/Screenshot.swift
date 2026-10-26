import CoreGraphics
import CoreVideo
import Foundation
import Geometry
@unsafe @preconcurrency import ScreenCaptureKit

extension CaptureSource {
    /// **How a source is framed into a buffer** — size, crop, fit, anchor, cursor and window
    /// shadow — shared by a take (`CaptureSession.beginSegment`) and a screenshot, so a picture
    /// and a take of one source cannot be framed differently. Pixel format and colour space are
    /// not here: a take encodes H.264 from 4:2:0 and a picture keeps every pixel.
    public nonisolated func framingConfiguration(geometry: DisplayGeometry,
                                                 destination: PixelRect) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight
        // **The crop, at the SOURCE.** `nil` for a display capture. Set here rather than
        // applied per frame downstream: ScreenCaptureKit delivers frames already cropped
        // and already the output's size, so nothing later has to know a window moved.
        if let rect = sourceRect {
            configuration.sourceRect = CGGeometryBridge.rect(from: rect)
        }
        configuration.showsCursor = false                 // Step 0 / D2-8
        // **`scalesToFit` follows the capture kind, and a window needs it true.** The buffer
        // is fixed for the life of a track (D2-13), so a window RESIZED mid-recording delivers
        // content of a different size into it: `false` crops that content to the buffer, which
        // silently loses whatever the window grew by. `true` fits it, which costs sharpness and
        // shows the whole window. A display capture cannot resize, so leaving it false there
        // keeps that path exactly as measured.
        configuration.scalesToFit = window != nil
        configuration.preservesAspectRatio = true           // D2-13a
        if window != nil {
            // The window's own drop shadow is not the window. A window filter includes it by
            // default, which puts a soft dark border on every frame and a transparent one
            // around it.
            configuration.ignoreShadowsSingleWindow = true
        }
        // Set explicitly: unset, where ScreenCaptureKit places content that does
        // not fill the surface is undocumented.
        configuration.destinationRect = CGGeometryBridge.rect(from: destination)

        return configuration
    }
}

/// One picture of a source, through the filter a take of it would use.
///
/// **The same filter, so the same things are missing**: this app's own windows, and the Dock,
/// menu bar, widgets and notifications exactly when a recording would leave them out. See
/// `docs/design/2026-09-30-a-screenshot-is-a-one-frame-take.md`.
public enum Screenshot {
    public enum Failure: Error, Equatable {
        case captureFailed(String)
    }

    /// The picture, at the source's pixel size, in sRGB with every pixel — BGRA, not the take's
    /// 4:2:0, because a picture is not handed to an encoder that subsamples it anyway.
    public static func capture(_ source: CaptureSource, scale: Double, displayUUID: UUID,
                               exclusions: CaptureExclusions) async throws -> CGImage {
        let geometry = source.geometry(scale: scale, displayUUID: displayUUID)
        let configuration = source.framingConfiguration(geometry: geometry,
                                                        destination: source.destinationRect(scale: scale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        unsafe configuration.colorSpaceName = CGColorSpace.sRGB
        let furniture = await exclusions.resolve()
        let filter = source.filter(excluding: await CaptureSource.thisApplication()
                                       + furniture.applications,
                                   excepting: furniture.exceptedWindows,
                                   showsMenuBar: !exclusions.hidesMenuBar)
        do {
            return try await retryingOnceIfTransient {
                try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: configuration)
            }
        } catch {
            throw Failure.captureFailed(String(describing: error))
        }
    }

    /// Runs `attempt`, and once more if it failed with `SCStreamErrorInternalError` — the error
    /// the probe saw once in three runs on macOS 27.0.1 and not on the next two. Any other error
    /// is answered at once: a refused permission or a window that has gone cannot change its
    /// answer on a second asking. See `docs/design/2026-10-22-audit-and-how-to-stand-out.md` R8.
    static func retryingOnceIfTransient<Value>(
        _ attempt: () async throws -> Value) async throws -> Value {
        do {
            return try await attempt()
        } catch let error as NSError
            where error.domain == SCStreamErrorDomain
                && error.code == SCStreamError.Code.internalError.rawValue {
            return try await attempt()
        }
    }
}
