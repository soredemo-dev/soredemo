// `@unsafe` because `@preconcurrency` suppresses the concurrency checking that would
// otherwise catch a data race across this import — required by `.strictMemorySafety()`,
// which the app target never applied to this file. Safe here in the sense the mark asks
// for: the ScreenCaptureKit values this file holds (`SCDisplay`, `SCWindow`,
// `SCContentFilter`) are only read, never mutated, and every use is on the main actor or
// inside `CaptureSourcePicker`'s own callbacks.
@unsafe @preconcurrency import ScreenCaptureKit
import Geometry

/// What gets recorded — a display or a window — and the geometry that choice
/// implies.
///
/// `@preconcurrency import` because `SCDisplay` and `SCWindow` are not
/// `Sendable` in the SDK; this type asserts what the compiler cannot verify.
///
/// Only `SCContentSharingPicker` produces a live `CaptureSource` — a hand-built
/// `SCContentFilter` bypasses the picker's permission affordances and Presenter
/// Overlay.
///
/// Every member is `nonisolated` so that `CaptureSourcePicker`'s `nonisolated`
/// observer callbacks can call them synchronously under this project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
/// Everything a window capture needs, as its own type rather than four associated values
/// on an enum case: the case's data has its own invariants — the rect must be the window's
/// place on THAT display, the buffer must be sized to the window — and they belong together.
public struct WindowCapture: Sendable {
    public let window: SCWindow
    /// The display the window's centre sits on. **A display filter with a source rect, not
    /// `desktopIndependentWindow`** — see `CaptureSource.filter()` for the three reasons.
    public let display: SCDisplay
    /// The window's rect in that display's own POINT space, for
    /// `SCStreamConfiguration.sourceRect`. ScreenCaptureKit crops at the source, so frames
    /// arrive already cropped and there is no per-frame offset for anything downstream to
    /// apply.
    public let sourceRect: PointRect
    /// The output buffer, in pixels, **sized to the WINDOW**. Fixed when the segment opens
    /// and never changed: D2-13's finding stands — a QuickTime track cannot change
    /// dimensions mid-track — and what changed is only which rectangle it is sized to.
    public let bufferWidth: Int
    public let bufferHeight: Int

    /// The same capture cropped at a different rectangle — the window having moved or been
    /// resized while recording. **The buffer is deliberately carried over unchanged**: a
    /// QuickTime track cannot change dimensions mid-track (D2-13), so a resize is absorbed
    /// by ScreenCaptureKit scaling the new source rect into the existing buffer rather than
    /// by the video changing resolution. See `WindowFollower` for what that costs.
    public nonisolated func following(sourceRect updated: PointRect) -> WindowCapture {
        WindowCapture(window: window, display: display, sourceRect: updated,
                      bufferWidth: bufferWidth, bufferHeight: bufferHeight)
    }

    public init(window: SCWindow, display: SCDisplay, sourceRect: PointRect,
                bufferWidth: Int, bufferHeight: Int) {
        self.window = window
        self.display = display
        self.sourceRect = sourceRect
        self.bufferWidth = bufferWidth
        self.bufferHeight = bufferHeight
    }
}

public enum CaptureSource: Sendable {
    case display(SCDisplay)

    case window(WindowCapture)

    /// The same source cropped at a new rectangle, for a window that moved mid-recording.
    /// A display source has no crop to move and returns itself — the caller does not branch.
    public nonisolated func following(sourceRect updated: PointRect) -> CaptureSource {
        switch self {
        case .display: return self
        case .window(let capture): return .window(capture.following(sourceRect: updated))
        }
    }

    /// The window being recorded, if this is a window capture — what `WindowFollower` needs
    /// to identify and re-read. `nil` for a display.
    public nonisolated var window: SCWindow? {
        switch self {
        case .display: return nil
        case .window(let capture): return capture.window
        }
    }

    /// The intrinsic geometry — what `GeometryRevision` is a digest of.
    ///
    /// The window's frame is structurally unreachable here: digesting it would
    /// mint a new `GeometryRevision` on every drag. For `.window`, the
    /// caller-supplied `displayUUID` carries a source identity minted once per
    /// selection, since a window has no identity surviving its app's restart.
    ///
    /// `SCDisplay.width`/`.height` are points (`SCShareableContent.h`), so they
    /// are multiplied by `scale` — `DisplayGeometry` carries native pixels.
    public nonisolated func geometry(scale: Double, displayUUID: UUID) -> DisplayGeometry {
        switch self {
        case .display(let display):
            return DisplayGeometry(
                displayUUID: displayUUID,
                pixelWidth: Int((Double(display.width) * scale).rounded()),
                pixelHeight: Int((Double(display.height) * scale).rounded()),
                scale: scale)
        case .window(let capture):
            return DisplayGeometry(
                displayUUID: displayUUID,
                pixelWidth: capture.bufferWidth,
                pixelHeight: capture.bufferHeight,
                scale: scale)
        }
    }

    /// Where inside the output buffer this source's content is placed, in
    /// pixels, for `SCStreamConfiguration.destinationRect`.
    ///
    /// Set explicitly: `SCStream.h` documents only that an unset value uses the
    /// entire output surface, never where content that under-fills the surface
    /// is anchored, so the anchor must not be inferred from observed behaviour.
    ///
    /// For `.window` this is a snapshot of the frame when the segment opens and
    /// does not follow the window. A window resized past it is scaled into it,
    /// which `SCStreamFrameInfoContentScale` reports as `!= 1` and
    /// `Diagnostics.resampledFrameCount` counts.
    public nonisolated func destinationRect(scale: Double) -> PixelRect {
        switch self {
        case .display(let display):
            // The identity case, stated so the display path is visibly handled.
            return PixelRect(x: 0, y: 0,
                             width: Double((Double(display.width) * scale).rounded()),
                             height: Double((Double(display.height) * scale).rounded()))
        case .window(let capture):
            // The buffer IS the window since the source-rect repair, so the content fills
            // it exactly and the destination is the identity — the same shape as `.display`
            // above. Before the repair this clamped a window-sized rect into a
            // display-sized buffer, which is the offset that put the recording in a corner.
            return PixelRect(x: 0, y: 0,
                             width: Double(capture.bufferWidth),
                             height: Double(capture.bufferHeight))
        }
    }

    /// **The rectangle this source actually records**, in the global point space
    /// `CGEvent` reports pointer locations in.
    ///
    /// Asked of the SOURCE rather than assembled by the session: which rectangle is being
    /// recorded is this type's own knowledge, and a caller that had to reconstruct it would
    /// be a second place the display-versus-window distinction could be got wrong — which
    /// is precisely how the cursor came to be normalised against the wrong rectangle.
    ///
    /// `geometry(scale:displayUUID:)`'s arguments are threaded through unchanged, because a
    /// viewport's revision must be the SAME revision the segment's samples carry.
    public nonisolated func viewport(scale: Double, displayUUID: UUID) -> CaptureViewport {
        let geometry = self.geometry(scale: scale, displayUUID: displayUUID)
        switch self {
        case .display(let display):
            let bounds = CGGeometryBridge.pointRect(from: display.frame)
            return CaptureViewport(geometry: geometry,
                                   globalOriginX: bounds.x, globalOriginY: bounds.y,
                                   widthInPoints: bounds.width, heightInPoints: bounds.height)
        case .window(let capture):
            // The source rect is display-local; the pointer arrives in global points, so it
            // is rebased back out. The window's own frame is still not read here — but no
            // longer because the recording is fixed to the opening rect. It is because
            // `SCWindow.frame` is a snapshot from the content query and never updates;
            // `WindowFollower` reads the live frame and hands back a source rect through
            // `following(sourceRect:)`, so this stays the one place the rebase is written.
            let bounds = CGGeometryBridge.pointRect(from: capture.display.frame)
            return CaptureViewport(geometry: geometry,
                                   globalOriginX: bounds.x + capture.sourceRect.x,
                                   globalOriginY: bounds.y + capture.sourceRect.y,
                                   widthInPoints: capture.sourceRect.width,
                                   heightInPoints: capture.sourceRect.height)
        }
    }

    /// The `SCContentFilter` this source captures through — what is handed to
    /// `SCStream(filter:configuration:delegate:)`, and the reverse of
    /// `init(pickerFilter:availableDisplays:)`. Rebuilding a filter from a value
    /// the picker vetted exposes no surface the person did not already choose.
    /// **A DISPLAY filter for both cases, with `sourceRect` doing the window's cropping.**
    /// Reverses D2-13's `desktopIndependentWindow`, for three reasons of decreasing
    /// obviousness:
    ///
    /// 1. the output buffer can then be sized to the WINDOW, so a window recording is not a
    ///    display-resolution frame with the window occupying a fraction of it;
    /// 2. ScreenCaptureKit crops at the source, so there is no per-frame content-rect offset
    ///    for anything downstream to apply — the problem disappears rather than being
    ///    solved, and `capture-stream`'s content-rect work becomes unnecessary;
    /// 3. `desktopIndependentWindow` makes macOS composite **the purple recording indicator
    ///    into the captured frames** (observed by `../opensource/a Swift recorder`, Apache 2.0).
    ///
    /// **What this loses, stated rather than discovered later**: a window filter excludes
    /// other windows by construction and a display filter with a source rect does not, so
    /// anything overlapping the window's rect is captured with it. A real regression in
    /// isolation, accepted because the alternative is a capture that is wrong in three
    /// visible ways; `excludingApplications` can narrow it later.
    public nonisolated func filter() -> SCContentFilter {
        switch self {
        case .display(let display):
            return SCContentFilter(display: display, excludingWindows: [])
        case .window(let capture):
            return SCContentFilter(display: capture.display, excludingWindows: [])
        }
    }

    /// The rect ScreenCaptureKit should crop to, in the filtered display's point space —
    /// `nil` for a display capture, which crops nothing.
    public nonisolated var sourceRect: PointRect? {
        switch self {
        case .display: return nil
        case .window(let capture): return capture.sourceRect
        }
    }

    /// Derives a `CaptureSource` from a filter the picker produced. Returns
    /// `nil` for `.application` and `.none`, for an empty `availableDisplays`,
    /// and for a non-positive size, rather than building a value that would trap
    /// later inside `.geometry()`.
    ///
    /// `availableDisplays` supplies the display a `.window` source is cropped out
    /// of: the one whose bounds contain the window's CENTRE, not the largest.
    /// A window is captured through a display filter plus a source rect, so the
    /// display has to be the one the window is actually on — the largest display
    /// was the right answer only while the buffer was display-sized, which was
    /// the defect. `SCDisplay` exposes no scale, so `filter.pointPixelScale`
    /// converts points (`SCShareableContent.h`) to pixels.
    ///
    /// Not `nonisolated`, unlike `.geometry()`/`.filter()` above: it stays
    /// implicitly `@MainActor`, so `CaptureSourcePicker` hops onto the main
    /// actor before calling it.
    public init?(pickerFilter filter: SCContentFilter, availableDisplays: [SCDisplay]) {
        switch filter.style {
        case .display:
            guard let display = filter.includedDisplays.first else { return nil }
            self = .display(display)

        case .window:
            guard let window = filter.includedWindows.first else { return nil }
            let frame = CGGeometryBridge.pointRect(from: window.frame)
            let centreX = frame.x + frame.width / 2
            let centreY = frame.y + frame.height / 2
            guard let host = availableDisplays.first(where: {
                let bounds = CGGeometryBridge.pointRect(from: $0.frame)
                return centreX >= bounds.x && centreX < bounds.x + bounds.width
                    && centreY >= bounds.y && centreY < bounds.y + bounds.height
            }) else { return nil }

            let hostBounds = CGGeometryBridge.pointRect(from: host.frame)
            // `sourceRect` is in the DISPLAY's own point space, so the window's global
            // frame is rebased onto it.
            let sourceRect = PointRect(x: frame.x - hostBounds.x, y: frame.y - hostBounds.y,
                                       width: frame.width, height: frame.height)
            let pixelScale = Double(filter.pointPixelScale)
            let width = Int((frame.width * pixelScale).rounded())
            let height = Int((frame.height * pixelScale).rounded())
            guard width > 0, height > 0 else { return nil }
            self = .window(WindowCapture(window: window, display: host, sourceRect: sourceRect,
                                         bufferWidth: width, bufferHeight: height))

        case .application, .none:
            return nil

        @unknown default:
            return nil
        }
    }
}

/// Presents the system content picker and reports the `CaptureSource` a human
/// chose.
///
/// Nothing here is exercised by a probe or by `swift test`: the observer
/// callbacks fire only after a real click in Control Center's picker UI.
///
/// The three observer methods are `nonisolated` deliberately.
/// `SCContentSharingPickerObserver` is a non-isolated ObjC protocol, so a build
/// without the `InferIsolatedConformances` upcoming feature rejects an
/// implicitly `@MainActor` conformance; the picker is also not documented to
/// call back on the main thread.
public final class CaptureSourcePicker: NSObject, SCContentSharingPickerObserver {
    private let onSelect: @Sendable (CaptureSource?) -> Void

    /// Optional hook for the raw `SCContentFilter` the picker returned, called
    /// before `init(pickerFilter:availableDisplays:)` derives a `CaptureSource`
    /// from it. `nil` for every product caller; used only by the manual
    /// `--present-picker` verification step in `SoredemoApp.swift`.
    private let debugFilterObserver: (@MainActor @Sendable (SCContentFilter) -> Void)?

    public init(onSelect: @escaping @Sendable (CaptureSource?) -> Void,
                debugFilterObserver: (@MainActor @Sendable (SCContentFilter) -> Void)? = nil) {
        self.onSelect = onSelect
        self.debugFilterObserver = debugFilterObserver
        super.init()
    }

    /// Marks the shared picker active and shows it. `SCContentSharingPicker` is
    /// a singleton (`.shared`) this type observes rather than owns; main-actor
    /// because it presents UI, unlike the callbacks below.
    ///
    /// `allowedPickerModes` is restricted to `.singleWindow` and
    /// `.singleDisplay` because the default also offers applications and
    /// multi-selections, which `CaptureSource` has no case for; a later caller
    /// could change that, so the initialiser still returns `Optional`.
    ///
    /// `restrictModes: false` exists only to check that the restriction changes
    /// what the picker offers; it is not for product use.
    @MainActor
    public func present(restrictModes: Bool = true) {
        let picker = SCContentSharingPicker.shared
        if restrictModes {
            var configuration = picker.defaultConfiguration
            configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
            picker.defaultConfiguration = configuration
        }
        picker.isActive = true
        picker.add(self)
        picker.present()
    }

    /// `init(pickerFilter:availableDisplays:)` is main-actor isolated, so this
    /// hops there rather than calling it inline; the callback itself stays
    /// `nonisolated`.
    ///
    /// `availableDisplays` comes from `SCShareableContent.currentProcess`
    /// (macOS 14.4+), which reports displays without a Screen Recording grant.
    /// If it throws or returns none, a window selection reports `nil` to
    /// `onSelect` rather than falling back to the filter's own `contentRect`.
    public nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                                  didUpdateWith filter: SCContentFilter,
                                                  for stream: SCStream?) {
        let onSelect = self.onSelect
        let debugFilterObserver = self.debugFilterObserver
        // `debugFilterObserver` runs inside the hop, not inline: its
        // implementation routes `filter.contentRect` through `CGGeometryBridge`,
        // which is implicitly `@MainActor`. Called before `onSelect` to keep the
        // documented ordering: the filter, then the value derived from it.
        Task { @MainActor in
            debugFilterObserver?(filter)
            let availableDisplays = (try? await SCShareableContent.currentProcess)?.displays ?? []
            onSelect(CaptureSource(pickerFilter: filter, availableDisplays: availableDisplays))
        }
    }

    public nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                                  didCancelFor stream: SCStream?) {
        onSelect(nil)
    }

    public nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        onSelect(nil)
    }
}
