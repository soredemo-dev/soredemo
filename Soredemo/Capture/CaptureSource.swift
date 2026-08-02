@preconcurrency import ScreenCaptureKit
import Geometry

/// What gets recorded — a display or a window — and the geometry that choice
/// implies. `ROADMAP.md`'s `capture-source` row.
///
/// **`@preconcurrency import`, not a plain one.** `SCDisplay` and `SCWindow`
/// are not `Sendable` in the SDK (verified by compiling `enum X: Sendable {
/// case a(SCDisplay) }` under `-swift-version 6 -strict-concurrency=complete`,
/// which fails without this import and passes with it) — Apple has not
/// audited these ObjC types for concurrency, so the compiler cannot verify
/// they are safe to send across an isolation boundary and we assert it
/// instead. That assertion is not free: `SCShareableContent` vends these
/// objects from a background queue, and the app is expected to hold them
/// only long enough to read their (effectively immutable, TCC-vended)
/// properties before handing them onward as `CaptureSource`. The brief's
/// Step 1 sample compiles this enum with a plain `import`, which does not
/// build under this project's Swift 6 language mode — recorded here rather
/// than silently corrected, per `AGENTS.md`'s rule that a document's numbers
/// are requirements about intent, and its code is verified rather than
/// trusted.
///
/// **Only `SCContentSharingPicker` produces a live `CaptureSource` in the
/// running app.** The picker carries permission affordances and Presenter
/// Overlay for free (`ROADMAP.md`); constructing an `SCContentFilter` by
/// hand bypasses both, so the app never does — `init(pickerFilter:availableDisplays:)` below
/// only ever *reads* a filter the picker produced. The one sanctioned
/// exception is measurement: `scripts/cross-boundary-digest-probe.swift`
/// constructs filters directly from windows/displays it obtains without a
/// picker, to exercise the pure functions here without a human present.
/// **`nonisolated` on every member, deliberately**, not left to this
/// project's app-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Under
/// that default, `.geometry()`, `.filter()` and `init(pickerFilter:availableDisplays:)` would
/// all become implicitly `@MainActor`-isolated — which broke a real caller
/// while building this task: `CaptureSourcePicker`'s observer callbacks are
/// `nonisolated` (see that type's header for why) and one of them calls
/// `init(pickerFilter:availableDisplays:)` synchronously, which `xcodebuild` rejected with
/// `call to main actor-isolated initializer ... in a synchronous nonisolated
/// context` until this annotation was added. Beyond fixing that call site,
/// it is the correct shape for what this type claims to be: the task brief
/// calls `.geometry()` a pure function that "needs no permission and no
/// picker", and a function pinned to the main actor is not free of the
/// concurrency domain it claims independence from, whatever thread happens
/// to call it in practice today.
public enum CaptureSource: Sendable {
    case display(SCDisplay)

    /// `bufferSize` is the *output buffer's* size, in pixels — **not** the
    /// window's own current or natural size. It is fixed once, at selection,
    /// and held for the life of the recording: a QuickTime video track
    /// cannot change dimensions mid-track (design doc D2-9), so this is the
    /// number `capture-stream` must configure `SCStreamConfiguration.width`/
    /// `.height` with and never change afterward, regardless of what the
    /// window does — alongside `scalesToFit = false` and
    /// `preservesAspectRatio = true`, which is `capture-stream`'s
    /// configuration to make, not this type's.
    ///
    /// **Display-sized, per D2-13a — not window-content-sized.** The design
    /// doc's D2-13 originally left scale-to-fill versus letterbox open for a
    /// recording to settle; D2-13a settled it from the header instead:
    /// `scalesToFit`/`preservesAspectRatio` are documented flags with
    /// documented defaults, and the chosen shape is a buffer sized to (a)
    /// display, not to the window. Sizing to the window's own current
    /// dimensions means growing the window past that size gets resampled
    /// (`scalesToFit = false` only scales *down*); sizing to a display means
    /// that only happens if the window grows past the whole display — D
    /// strictly dominates, same architecture, larger buffer. So
    /// `init(pickerFilter:availableDisplays:)` below derives this from the
    /// caller-supplied displays, not from the filter's own `contentRect`.
    case window(SCWindow, bufferSize: (width: Int, height: Int))

    /// The intrinsic geometry — what `GeometryRevision` is a digest of.
    ///
    /// For `.window`, the window's current screen frame is deliberately
    /// absent from this function's body — not merely unused, structurally
    /// unreachable, since the `SCWindow` associated value is pattern-matched
    /// away (`case .window(_, let bufferSize)`) and nothing about the window
    /// itself is ever read. A moving window is a moving display arrangement,
    /// and D-P2 already ruled a changing arrangement must stay out of the
    /// digest — digesting it would mint a new `GeometryRevision` on every
    /// drag, which is the exact failure D-P2 rejected for display
    /// arrangement (design doc D2-13).
    ///
    /// `scale` and `displayUUID` are supplied by the caller, never read from
    /// `self` — this function touches no ambient state and no CoreGraphics
    /// API, so it needs neither permission nor a picker to test. For a
    /// display, `displayUUID` is the real persistent identity from
    /// `CGDisplayCreateUUIDFromDisplayID` (D-P2); a window has no identity
    /// that survives its owning application restarting (see this file's
    /// header and `ROADMAP.md`'s `capture-source` row), so for `.window`
    /// this parameter carries a source identity minted once per selection
    /// rather than a literal display's UUID — the field is reused for that
    /// purpose rather than adding a second identity field to
    /// `DisplayGeometry`, which has no vocabulary for "this is a window, not
    /// a display" and does not need one: the digest only needs *an*
    /// identity that distinguishes one captured surface from another.
    ///
    /// `SCDisplay.width`/`.height` are documented in the header as **points**,
    /// not pixels (`SCShareableContent.h`), so they are multiplied by `scale`
    /// here exactly as `CGDisplayBounds` is elsewhere in this project —
    /// `DisplayGeometry` carries native pixels throughout (Phase 1 design
    /// doc, "Geometry: the Y-axis flip").
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

    /// The `SCContentFilter` this source captures through — the direction
    /// `capture-stream` needs: what actually gets handed to `SCStream(filter:
    /// configuration:delegate:)`. The reverse of `init(pickerFilter:availableDisplays:)`.
    ///
    /// Constructing a filter here is not the hand-built filter the header
    /// above warns against: it is reconstructing, from a value the picker
    /// already vetted, the same filter the picker vetted — no new surface is
    /// exposed to capture that the person did not already choose.
    public nonisolated func filter() -> SCContentFilter {
        switch self {
        case .display(let display):
            return SCContentFilter(display: display, excludingWindows: [])
        case .window(let window, _):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// Derives a `CaptureSource` from a filter the picker produced (Step 2).
    /// Returns `nil` for anything this app does not model — `.application`
    /// and `.none` — and for a window filter this process cannot size a
    /// buffer for (see below), rather than constructing a value that would
    /// only fail later, deeper in `.geometry()`.
    ///
    /// `availableDisplays` is how a `.window` source gets its `bufferSize`
    /// under D2-13a's decision (see that case's doc comment): the *largest*
    /// of the supplied displays, by point-space area — not `filter
    /// .contentRect`, which reports the window's own current size, exactly
    /// the number D2-13a moved away from. Ranking by point area rather than
    /// pixel area is a deliberate simplification: `SCDisplay` exposes no
    /// scale of its own (verified against the header — `width`/`height`/
    /// `frame`/`displayID` only), so comparing pixel areas across displays
    /// with different scales would need a second, separate scale lookup per
    /// display (e.g. matching each `SCDisplay.displayID` against
    /// `NSScreen.screens`), which is more machinery than this task's scope
    /// asked for. On any real multi-display setup seen while building this
    /// (a single 5K-class display), the two rankings agree; a setup where
    /// they would not — a small, very-high-scale display next to a large,
    /// low-scale one — is a known gap, left for whoever wires this into
    /// `capture-stream` to close if it matters there. The caller (today,
    /// `CaptureSourcePicker`) supplies `availableDisplays`, matching this
    /// file's existing pattern for ambient SDK state — see `.geometry()`'s
    /// `scale`/`displayUUID` parameters, supplied the same way.
    ///
    /// The chosen display's `width`/`height` are points (`SCShareableContent.h`,
    /// same as `.geometry()`'s `.display` case); this initialiser reuses
    /// `filter.pointPixelScale` — the window's own filter-reported scale —
    /// to convert them to pixels, rather than looking up the chosen
    /// display's own scale, since `SCDisplay` does not expose one and the
    /// two are the same value whenever the window and the sizing display
    /// share a scale, which they do unless the window started on a
    /// differently-scaled display than the one chosen for sizing.
    ///
    /// A degenerate result (an empty `availableDisplays`, or a non-positive
    /// size after rounding) must not become a `.window` case that traps
    /// later inside `.geometry()`'s call to `DisplayGeometry.init`. Failing
    /// here, at the boundary that already returns `Optional`, keeps the
    /// failure inside this function's own error channel instead of a
    /// precondition three calls downstream (`AGENTS.md`: failure must land
    /// outside the value range, not inside a later one).
    ///
    /// **Not `nonisolated`, unlike `.geometry()`/`.filter()` above** — kept
    /// implicitly `@MainActor` under this project's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so `CaptureSourcePicker`
    /// hops onto the main actor before calling it, below.
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

/// Presents the system content picker and reports the `CaptureSource` a
/// human chose. `ROADMAP.md` `capture-source`: `SCContentSharingPicker`, not
/// a custom picker.
///
/// **Nothing here is exercised by a probe or by `swift test`.**
/// `SCContentSharingPickerObserver`'s callbacks fire only after Control
/// Center's picker UI receives a real click, which needs a running app with
/// a menu-bar presence and a person in front of it — the "awaiting-human"
/// half of this task. What is verified is that this type *compiles* against
/// the real `SCContentSharingPicker` API surface, under this project's exact
/// Swift 6 / `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build settings
/// (`xcodebuild`, not a bare `swiftc` guess at the flags).
///
/// Not yet wired to anything — `capture-stream` (`ROADMAP.md`'s next row) is
/// the intended first caller, from `Soredemo/App/SoredemoApp.swift` or a
/// menu command, once there is a stream for the resulting `CaptureSource` to
/// start.
///
/// **The three observer methods are `nonisolated` deliberately, not merely
/// unannotated.** `SCContentSharingPickerObserver` is a plain (non-isolated)
/// ObjC protocol, and this project's app target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` plus the
/// `InferIsolatedConformances` upcoming feature, which is permissive enough
/// to accept an *implicitly* `@MainActor` conformance here — verified by an
/// `xcodebuild` of the real target. A bare `swiftc -swift-version 6` build
/// without that upcoming feature (the shape `scripts/cross-boundary-digest-probe.swift`
/// uses to compile this file) rejects the same implicit conformance outright
/// (`error: conformance ... crosses into main actor-isolated code`, observed
/// while building this task). Marking the callbacks `nonisolated` compiles
/// under both, does not depend on which upcoming features a caller's build
/// happens to enable, and is the more honest annotation regardless: Control
/// Center's picker is not documented to call back on the main thread.
public final class CaptureSourcePicker: NSObject, SCContentSharingPickerObserver {
    private let onSelect: @Sendable (CaptureSource?) -> Void

    /// Optional hook for the raw `SCContentFilter` the picker returned,
    /// called *before* `init(pickerFilter:availableDisplays:)` derives a
    /// `CaptureSource` from it. `nil` for every real caller today — nothing
    /// in the product needs the filter itself, only what `CaptureSource`
    /// derives from it. It exists for one reason: Task 7's human
    /// verification step (`Soredemo/App/SoredemoApp.swift`, `--present-picker`)
    /// needs to print `filter.contentRect`/`.pointPixelScale` beside the
    /// derived value, and doing that against the *real* derivation path —
    /// this type, unmodified — is worth more than a second, parallel
    /// observer that could drift from what actually ships. See that file for
    /// the three cases a person should check.
    private let debugFilterObserver: (@Sendable (SCContentFilter) -> Void)?

    public init(onSelect: @escaping @Sendable (CaptureSource?) -> Void,
                debugFilterObserver: (@Sendable (SCContentFilter) -> Void)? = nil) {
        self.onSelect = onSelect
        self.debugFilterObserver = debugFilterObserver
        super.init()
    }

    /// Marks the shared picker active and shows it. `SCContentSharingPicker`
    /// is a singleton per the header (`.shared`) — this type is an observer
    /// of it, not an owner. Main-actor because it touches AppKit-adjacent,
    /// UI-presenting API, unlike the callbacks below.
    ///
    /// **`allowedPickerModes` is restricted to `.singleWindow` and
    /// `.singleDisplay`.** Left at its default (`0`, "no excluded picking
    /// modes" per the header), the picker can also hand back a whole
    /// application, multiple windows, or multiple applications — shapes
    /// `CaptureSource` has no case for. Restricting the picker keeps the
    /// picker and the type in agreement *by construction*, the same move as
    /// `Evidence` refusing to be empty and `NormalizedPoint` validating in
    /// its own initialiser: no downstream "I do not support this" branch has
    /// to exist, because the shape it would guard against is never offered.
    /// `init(pickerFilter:availableDisplays:)` still returns `Optional`
    /// rather than a non-failable value, though — this restriction lives in
    /// picker *configuration*, which a later caller could change, and the
    /// derivation function must not assume its own caller left it alone.
    @MainActor
    public func present() {
        let picker = SCContentSharingPicker.shared
        var configuration = picker.defaultConfiguration
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.add(self)
        picker.present()
    }

    /// `init(pickerFilter:availableDisplays:)` is main-actor isolated (its
    /// own header explains why), so this hops there rather than calling it
    /// inline — the callback itself stays `nonisolated`, matching the other
    /// two below and the class-level doc comment's reasoning.
    ///
    /// `availableDisplays` comes from `SCShareableContent.currentProcess`
    /// (`getCurrentProcessShareableContentWithCompletionHandler:`, macOS
    /// 14.4+) — the same permission-free, picker-free source
    /// `scripts/cross-boundary-digest-probe.swift` uses for its fixtures,
    /// used here for the same reason: displays are not owned by a process,
    /// so this call reports them without a Screen Recording grant, verified
    /// empirically before writing this (`AGENTS.md`'s primary-source rule —
    /// the header's own wording, "without user consent via TCC", was
    /// checked, not trusted). If it throws or returns no displays,
    /// `init(pickerFilter:availableDisplays:)` returns `nil` for a window
    /// selection — a real failure, reported to `onSelect` as `nil` rather
    /// than silently falling back to the filter's own `contentRect`, which
    /// is exactly the number D2-13a moved away from.
    public nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                                  didUpdateWith filter: SCContentFilter,
                                                  for stream: SCStream?) {
        debugFilterObserver?(filter)
        let onSelect = self.onSelect
        Task { @MainActor in
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
