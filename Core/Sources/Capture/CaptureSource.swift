// `@unsafe` because `@preconcurrency` suppresses the concurrency checking that would
// otherwise catch a data race across this import — required by `.strictMemorySafety()`,
// which the app target never applied to this file. Safe here in the sense the mark asks
// for: the ScreenCaptureKit values this file holds (`SCDisplay`, `SCWindow`,
// `SCContentFilter`) are only read, never mutated, and every use is on the main actor or
// inside `CaptureSourcePicker`'s own callbacks.
@unsafe @preconcurrency import ScreenCaptureKit
import Geometry

/// A rectangle of a display, and the buffer it is recorded into.
///
/// The same shape as `WindowCapture` minus the window, deliberately — the two are
/// captured by the same mechanism and differ only in what chose the rectangle. Not
/// folded into one type with an optional window: `WindowFollower` asks whether
/// there is a window to follow, and an optional would make that a runtime question
/// where the type system can answer it.
public struct RegionCapture: Sendable {
    /// The display the region sits on.
    public let display: SCDisplay
    /// The region in that display's own POINT space, for `SCStreamConfiguration.sourceRect`.
    public let sourceRect: PointRect
    /// The output buffer in pixels, sized to the region. Even in both dimensions, for
    /// `CaptureSource.evenFloor`'s reason: an odd dimension is where a stray column of green
    /// comes from.
    public let bufferWidth: Int
    public let bufferHeight: Int

    public init(display: SCDisplay, sourceRect: PointRect,
                bufferWidth: Int, bufferHeight: Int) {
        self.display = display
        self.sourceRect = sourceRect
        self.bufferWidth = bufferWidth
        self.bufferHeight = bufferHeight
    }

    /// The buffer a dragged rectangle needs, in pixels.
    ///
    /// **Separate from the initialiser so it can be tested.** An `SCDisplay` cannot be
    /// constructed in a unit test, so the value type itself is only reachable through the
    /// cross-boundary probe — but the arithmetic is where this goes wrong, and the arithmetic
    /// needs no handle. `CaptureSource.evenFloor` is the same rule the window path uses: an odd
    /// dimension is where a stray column of green comes from.
    ///
    /// **Floored to at least 2**, because a drag can end where it started. A zero-width buffer is
    /// an `AVAssetWriter` that refuses its input, and a recording that fails at the moment of
    /// starting is the worst time to fail.
    public nonisolated static func buffer(for rect: PointRect, scale: Double)
    -> (width: Int, height: Int) {
        (max(CaptureSource.evenFloor(rect.width * scale), 2),
         max(CaptureSource.evenFloor(rect.height * scale), 2))
    }
}

/// Everything a window capture needs, as its own type rather than four associated
/// values on an enum case: the rect must be the window's place on THAT display and
/// the buffer must be sized to the window, and those invariants belong together.
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

/// What gets recorded — a display, a window, or a region — and the geometry that
/// choice implies.
///
/// Only `SCContentSharingPicker` produces a live value: a hand-built
/// `SCContentFilter` bypasses the picker's permission affordances and Presenter
/// Overlay. Every member is `nonisolated` so `CaptureSourcePicker`'s `nonisolated`
/// observer callbacks can call them synchronously under this project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
public enum CaptureSource: Sendable {
    case display(SCDisplay)

    case window(WindowCapture)

    /// A rectangle of a display, chosen by dragging it out.
    ///
    /// **The seam this file left open.** `sourceRect` returned `nil` for every case and said so
    /// in a comment — "a future case that started cropping again has to change this line". This
    /// is that case, and everything it needs was already here: `SCStreamConfiguration.sourceRect`
    /// is applied by the session, `destinationRect` and `viewport` already handle a source whose
    /// buffer is smaller than its display, and the pointer rebase for a window is the same
    /// arithmetic a region wants.
    ///
    /// **Why a recorder needs one.** A display capture of a demo that lives in a 600-point panel
    /// spends nine tenths of its pixels on desktop, and a window capture cannot do it at all when
    /// the thing being shown is part of a window rather than all of it.
    case region(RegionCapture)

    /// The same source cropped at a new rectangle, for a window that moved mid-recording.
    /// A display source has no crop to move and returns itself — the caller does not branch.
    ///
    /// **A region returns itself too, and for a different reason.** A window's crop follows the
    /// window; a region is a rectangle of the SCREEN that somebody dragged out, and moving it
    /// because a window under it moved would be following a thing they did not choose.
    public nonisolated func following(sourceRect updated: PointRect) -> CaptureSource {
        switch self {
        case .display, .region: return self
        case .window(let capture): return .window(capture.following(sourceRect: updated))
        }
    }

    /// The window being recorded, if this is a window capture — what `WindowFollower` needs
    /// to identify and re-read. `nil` for a display.
    public nonisolated var window: SCWindow? {
        switch self {
        case .display, .region: return nil
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
        case .region(let capture):
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
        case .region(let capture):
            // Identity, for `.window`'s reason: the buffer IS the region.
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
        case .region(let capture):
            // The same rebase as a window's, and for the same reason: the crop is display-local
            // and the pointer arrives in global points. A region does not move, so unlike a
            // window there is no follower feeding it a new rect.
            let bounds = CGGeometryBridge.pointRect(from: capture.display.frame)
            return CaptureViewport(geometry: geometry,
                                   globalOriginX: bounds.x + capture.sourceRect.x,
                                   globalOriginY: bounds.y + capture.sourceRect.y,
                                   widthInPoints: capture.sourceRect.width,
                                   heightInPoints: capture.sourceRect.height)
        }
    }

    /// Largest even integer at or below `value`. See the buffer-size comment for why even.
    public static func evenFloor(_ value: Double) -> Int {
        guard value.isFinite, value >= 2 else { return 0 }
        let rounded = Int(value.rounded(.down))
        return rounded - (rounded % 2)
    }

    /// The `SCContentFilter` this source captures through, and the reverse of
    /// `init(pickerFilter:availableDisplays:)`.
    ///
    /// A WINDOW gets a window filter, not a display filter plus a crop: other windows, the Dock,
    /// the menu bar and notifications are then excluded by construction. A DISPLAY excludes this
    /// process's own applications, because a recorder that puts a control strip over the screen
    /// and then records the screen records the strip.
    ///
    /// `excepting` names windows that come back DESPITE their application being excluded — the
    /// Dock's process also draws the wallpaper. `showsMenuBar` is `includeMenuBar` passed through.
    /// The list is an argument with an empty default rather than a static, because the
    /// applications come from an `async` query and a static would be wrong exactly once.
    ///
    /// See `docs/design/what-a-filter-excludes.md`.
    public nonisolated func filter(excluding applications: [SCRunningApplication] = [],
                                   excepting windows: [SCWindow] = [],
                                   showsMenuBar: Bool = true)
    -> SCContentFilter {
        switch self {
        case .display(let display):
            let filter = SCContentFilter(display: display, excludingApplications: applications,
                                         exceptingWindows: windows)
            filter.includeMenuBar = showsMenuBar
            return filter
        case .window(let capture):
            // **The Dock is excluded here by construction, so `excepting` has nothing to undo.**
            // A window filter captures one window and nothing overlapping it — the same argument
            // the header makes about the menu bar and notifications.
            return SCContentFilter(desktopIndependentWindow: capture.window)
        case .region(let capture):
            // **A display filter, because a region is part of a display and not of any window.**
            // The crop is `SCStreamConfiguration.sourceRect`; this only decides what may appear
            // inside it, and what may not is this application — the same exclusion the display
            // case makes, and for the same reason the recording bar was once burnt into a video.
            let filter = SCContentFilter(display: capture.display,
                                         excludingApplications: applications,
                                         exceptingWindows: windows)
            // A region that does not reach the top of the screen contains no menu bar to hide,
            // and one that does is asking the same question a display capture asks. Set either
            // way rather than conditioned on the region's rect: the crop is applied downstream by
            // `sourceRect`, and a filter that answered differently depending on where somebody
            // dragged a box would be a second rule to keep in step with the first.
            filter.includeMenuBar = showsMenuBar
            return filter
        }
    }

    /// This process as ScreenCaptureKit sees it — what `filter(excluding:)` wants.
    ///
    /// **`SCShareableContent.currentProcess`, which needs no Screen Recording grant**: it
    /// reports this process's own windows and nothing else, which is all an exclusion list has
    /// to contain. Asking for the full shareable content would prompt, and would also hand back
    /// every other application on the machine.
    ///
    /// Matched on the process identifier rather than the name: a bundle name can be localised or
    /// shared, and an exclusion that matched the wrong application would blank part of a
    /// recording without saying so.
    public nonisolated static func thisApplication() async -> [SCRunningApplication] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let content = try? await SCShareableContent.currentProcess
        return (content?.applications ?? []).filter { $0.processID == pid }
    }

    /// The rect ScreenCaptureKit should crop to, in the filtered display's point space —
    /// `nil` for a display capture, which crops nothing.
    /// The crop to apply at the source. **`nil` for BOTH cases now.**
    ///
    /// A display capture never had one, and a window capture no longer needs one: the filter
    /// is the window, so the frames already contain exactly it. Setting a rect here for a
    /// window would crop the window's own content by the window's offset on its display —
    /// the very thing the rect used to compensate for.
    ///
    /// Kept as a property rather than deleted because a REGION capture is a real future case
    /// (`ROADMAP`'s `capture-source` names one), and that is what `sourceRect` is for.
    public nonisolated var sourceRect: PointRect? {
        switch self {
        // A window is captured with `desktopIndependentWindow`, which crops for us.
        case .display, .window: return nil
        case .region(let capture): return capture.sourceRect
        }
    }

    /// **Which cases crop at the source, named, as a property of the TYPE.** This used to read
    /// `sourceRectIsAlwaysNil` and return `true`, with a comment saying a future case that
    /// started cropping again would have to change the line and face it. `.region` is that case:
    /// it is captured as a display filter, so the rectangle has to reach
    /// `SCStreamConfiguration.sourceRect` or the whole screen arrives.
    ///
    /// Named rather than counted, so the test that reads it says WHICH case crops rather than how
    /// many do — a count would go on passing if a future case started cropping and `.region`
    /// stopped. A test can assert this without an `SCWindow` or an `SCDisplay`, which is why it
    /// exists at all: neither handle can be constructed in a unit test.
    public nonisolated static var croppingCases: [String] { ["region"] }

    /// Where the window sits, in its display's point space. Not the stream's crop any more —
    /// `viewport(scale:displayUUID:)` rebases it back to global points so the pointer is
    /// normalised against the rectangle actually being recorded.
    public nonisolated var windowRectOnDisplay: PointRect? {
        switch self {
        case .display: return nil
        case .window(let capture): return capture.sourceRect
        // **`nil`, because a region is not a window.** `WindowFollower` reads this to decide
        // what to keep following; a region does not move, and reporting one here would have the
        // follower chasing a rectangle nobody is going to drag.
        case .region: return nil
        }
    }

    /// Derives a `CaptureSource` from a filter the picker produced. `nil` for
    /// `.application` and `.none`, for an empty `availableDisplays`, and for a
    /// non-positive size, rather than building a value that would trap later.
    ///
    /// `availableDisplays` supplies the display a `.window` source is cropped out of:
    /// the one whose bounds contain the window's CENTRE, not the largest — the
    /// largest was right only while the buffer was display-sized, which was the
    /// defect. `SCDisplay` exposes no scale, so `filter.pointPixelScale` converts
    /// points to pixels.
    ///
    /// Not `nonisolated`, unlike `.geometry()`/`.filter()`: it stays implicitly
    /// `@MainActor`, so `CaptureSourcePicker` hops before calling it.
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
            // **Centre first, then any overlap.** The centre test alone finds nothing for a
            // window dragged so its middle is past a display's edge — between two screens, or
            // pushed off the side — and a window with no host is a capture that cannot start.
            // so intersection is the fallback. Centre stays FIRST because it is the better
            // answer when both apply: a window straddling two displays belongs to the one
            // showing most of it.
            func contains(_ display: SCDisplay) -> Bool {
                let bounds = CGGeometryBridge.pointRect(from: display.frame)
                return centreX >= bounds.x && centreX < bounds.x + bounds.width
                    && centreY >= bounds.y && centreY < bounds.y + bounds.height
            }
            func overlaps(_ display: SCDisplay) -> Bool {
                let bounds = CGGeometryBridge.pointRect(from: display.frame)
                return frame.x < bounds.x + bounds.width && frame.x + frame.width > bounds.x
                    && frame.y < bounds.y + bounds.height && frame.y + frame.height > bounds.y
            }
            guard let host = availableDisplays.first(where: contains)
                    ?? availableDisplays.first(where: overlaps)
            else { return nil }

            let hostBounds = CGGeometryBridge.pointRect(from: host.frame)
            // `sourceRect` is in the DISPLAY's own point space, so the window's global
            // frame is rebased onto it.
            let sourceRect = PointRect(x: frame.x - hostBounds.x, y: frame.y - hostBounds.y,
                                       width: frame.width, height: frame.height)
            let pixelScale = Double(filter.pointPixelScale)
            // **Floored to even, with a floor of 2.** H.264 in 4:2:0 subsamples chroma by two
            // in each direction, so an odd buffer edge has no defined chroma plane and
            // VideoToolbox either refuses or silently rounds it — the same constraint
            // `AspectVariant.dimensions` states for the export side, and it applies here too
            // because this buffer is what the encoder eventually sees. Both comparable
            // recorders clamp with `max(2, …)`; neither says why, and the reason belongs
            // written down once.
            let width = Self.evenFloor(frame.width * pixelScale)
            let height = Self.evenFloor(frame.height * pixelScale)
            guard width >= 2, height >= 2 else { return nil }
            self = .window(WindowCapture(window: window, display: host, sourceRect: sourceRect,
                                         bufferWidth: width, bufferHeight: height))

        case .application, .none:
            return nil

        @unknown default:
            return nil
        }
    }
}

/// Presents the system content picker and reports the `CaptureSource` a human chose.
///
/// Nothing here is exercised by a probe or by `swift test`: the observer callbacks
/// fire only after a real click in Control Center's picker UI. They are
/// `nonisolated` deliberately — `SCContentSharingPickerObserver` is a non-isolated
/// ObjC protocol and the picker is not documented to call back on the main thread.
///
/// `@unchecked Sendable` because each callback hops to the main actor to hand the
/// shared picker back, which sends `self`. Safe: both stored properties are `let`
/// and both are already `@Sendable` closures.
public final class CaptureSourcePicker: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
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

    /// Marks the shared picker active and shows it. `SCContentSharingPicker` is a
    /// singleton this type observes rather than owns; main-actor because it presents
    /// UI, unlike the callbacks below.
    ///
    /// `allowedPickerModes` is narrowed to `.singleWindow` and `.singleDisplay` —
    /// `CaptureSource` has no case for applications or multi-selections, and the
    /// narrowing is also what makes "Record Screen" and "Record Window" two buttons
    /// rather than one opening twice. A later caller could widen it, so the
    /// initialiser still returns `Optional`.
    ///
    /// `restrictModes: false` exists only to check that the restriction changes what
    /// the picker offers; it is not for product use.
    public enum Modes: Sendable {
        case displaysAndWindows
        case displaysOnly
        case windowsOnly
        /// **A rectangle, which this picker cannot offer.** `SCContentSharingPicker` has displays,
        /// windows and applications and no fourth kind; a region is chosen by dragging one out on
        /// `RegionPickerOverlay`. The case is here anyway because the panel reads `pendingMode` to
        /// show which of its cards is busy, and a card whose mode had no name could not be lit.
        case region

        var allowed: SCContentSharingPickerMode {
            switch self {
            case .displaysAndWindows, .region: [.singleWindow, .singleDisplay]
            case .displaysOnly: [.singleDisplay]
            case .windowsOnly: [.singleWindow]
            }
        }
    }

    @MainActor
    public func present(restrictModes: Bool = true, modes: Modes = .displaysAndWindows) {
        let picker = SCContentSharingPicker.shared
        if restrictModes {
            var configuration = picker.defaultConfiguration
            configuration.allowedPickerModes = modes.allowed
            picker.defaultConfiguration = configuration
        }
        picker.isActive = true
        picker.add(self)
        picker.present()
    }

    /// Hands the shared picker back: clears `isActive` and removes the observer.
    ///
    /// `isActive = true` puts the SYSTEM's screen-sharing indicator in the menu bar,
    /// and one cancelled picker used to leave it there for the session. The picker is
    /// a singleton that RETAINS observers, so without the removal the second cancel
    /// called `onSelect(nil)` twice.
    ///
    /// Called from all three terminal callbacks, because each is the end of this
    /// picker's life and only one of them is the happy one.
    @MainActor
    public func dismiss() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
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
            self.dismiss()
            let availableDisplays = (try? await SCShareableContent.currentProcess)?.displays ?? []
            onSelect(CaptureSource(pickerFilter: filter, availableDisplays: availableDisplays))
        }
    }

    public nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                                  didCancelFor stream: SCStream?) {
        let onSelect = self.onSelect
        Task { @MainActor in
            self.dismiss()
            onSelect(nil)
        }
    }

    public nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let onSelect = self.onSelect
        Task { @MainActor in
            self.dismiss()
            onSelect(nil)
        }
    }
}
