@preconcurrency import ScreenCaptureKit
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
public enum CaptureSource: Sendable {
    case display(SCDisplay)

    /// `bufferSize` is the output buffer's size in pixels, fixed at selection
    /// and never changed: a QuickTime video track cannot change dimensions
    /// mid-track. It is sized to a display, not to the window, so a window is
    /// resampled only once it grows past the whole display.
    case window(SCWindow, bufferSize: (width: Int, height: Int))

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
        case .window(_, let bufferSize):
            return DisplayGeometry(
                displayUUID: displayUUID,
                pixelWidth: bufferSize.width,
                pixelHeight: bufferSize.height,
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
        case .window(let window, let bufferSize):
            let frame = CGGeometryBridge.pointRect(from: window.frame)
            // Clamped to the buffer: a window can extend past a screen edge, and
            // `SCStream.h` does not define a destination outside the surface.
            return PixelRect(x: 0, y: 0,
                             width: min((frame.width * scale).rounded(), Double(bufferSize.width)),
                             height: min((frame.height * scale).rounded(), Double(bufferSize.height)))
        }
    }

    /// The `SCContentFilter` this source captures through — what is handed to
    /// `SCStream(filter:configuration:delegate:)`, and the reverse of
    /// `init(pickerFilter:availableDisplays:)`. Rebuilding a filter from a value
    /// the picker vetted exposes no surface the person did not already choose.
    public nonisolated func filter() -> SCContentFilter {
        switch self {
        case .display(let display):
            return SCContentFilter(display: display, excludingWindows: [])
        case .window(let window, _):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// Derives a `CaptureSource` from a filter the picker produced. Returns
    /// `nil` for `.application` and `.none`, for an empty `availableDisplays`,
    /// and for a non-positive size, rather than building a value that would trap
    /// later inside `.geometry()`.
    ///
    /// `availableDisplays` supplies a `.window` source's `bufferSize`: the
    /// largest supplied display by point-space area, not `filter.contentRect`.
    /// `SCDisplay` exposes no scale, so `filter.pointPixelScale` converts that
    /// display's points (`SCShareableContent.h`) to pixels.
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
            guard let largestDisplay = availableDisplays.max(by: { $0.width * $0.height < $1.width * $1.height })
            else { return nil }
            let pixelScale = Double(filter.pointPixelScale)
            let width = Int((Double(largestDisplay.width) * pixelScale).rounded())
            let height = Int((Double(largestDisplay.height) * pixelScale).rounded())
            guard width > 0, height > 0 else { return nil }
            self = .window(window, bufferSize: (width: width, height: height))

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
