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
/// hand bypasses both, so the app never does — `init(pickerFilter:)` below
/// only ever *reads* a filter the picker produced. The one sanctioned
/// exception is measurement: `scripts/cross-boundary-digest-probe.swift`
/// constructs filters directly from windows/displays it obtains without a
/// picker, to exercise the pure functions here without a human present.
/// **`nonisolated` on every member, deliberately**, not left to this
/// project's app-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Under
/// that default, `.geometry()`, `.filter()` and `init(pickerFilter:)` would
/// all become implicitly `@MainActor`-isolated — which broke a real caller
/// while building this task: `CaptureSourcePicker`'s observer callbacks are
/// `nonisolated` (see that type's header for why) and one of them calls
/// `init(pickerFilter:)` synchronously, which `xcodebuild` rejected with
/// `call to main actor-isolated initializer ... in a synchronous nonisolated
/// context` until this annotation was added. Beyond fixing that call site,
/// it is the correct shape for what this type claims to be: the task brief
/// calls `.geometry()` a pure function that "needs no permission and no
/// picker", and a function pinned to the main actor is not free of the
/// concurrency domain it claims independence from, whatever thread happens
/// to call it in practice today.
public enum CaptureSource: Sendable {
    case display(SCDisplay)

    /// `bufferSize` is the *output buffer's* size, in pixels — not the
    /// window's current screen size. It is fixed once, at selection, and
    /// held for the life of the recording: a QuickTime video track cannot
    /// change dimensions mid-track (design doc D2-9), so this is the number
    /// `capture-stream` must configure `SCStreamConfiguration.width/height`
    /// with and never change afterward, regardless of what the window does.
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
    /// configuration:delegate:)`. The reverse of `init(pickerFilter:)`.
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
    /// and `.none` — and for a window filter whose content is degenerate
    /// (see below), rather than constructing a value that would only fail
    /// later, deeper in `.geometry()`.
    ///
    /// `bufferSize` for a window is read from the filter's own `contentRect`
    /// (points) and `pointPixelScale`, **not** from the window's `frame` —
    /// the filter already reports the size of the *captured* content, which
    /// is what the output buffer will be and the only window-shaped number
    /// D2-13 allows into the digest. Both are `SCContentFilter` properties
    /// available since macOS 14.0, below this project's macOS 26.0 floor.
    ///
    /// `contentRect` carries a CoreGraphics type; per architecture rule 5 it
    /// is routed through `CGGeometryBridge` and never named directly in this
    /// file.
    ///
    /// **Not `nonisolated`, unlike `.geometry()`/`.filter()` above.**
    /// `CGGeometryBridge` carries no isolation annotation of its own, so
    /// under this project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` it
    /// is implicitly `@MainActor` — calling it from a `nonisolated` context
    /// is exactly the mismatch `xcodebuild` caught while building this task
    /// (`call to main actor-isolated static method 'pointRect(from:)' in a
    /// synchronous nonisolated context`). This initialiser inherits that
    /// isolation rather than fighting it; `CaptureSourcePicker` hops onto
    /// the main actor before calling it, below.
    public init?(pickerFilter filter: SCContentFilter) {
        switch filter.style {
        case .display:
            guard let display = filter.includedDisplays.first else { return nil }
            self = .display(display)

        case .window:
            guard let window = filter.includedWindows.first else { return nil }
            let contentPoints = CGGeometryBridge.pointRect(from: filter.contentRect)
            let pixelScale = Double(filter.pointPixelScale)
            let width = Int((contentPoints.width * pixelScale).rounded())
            let height = Int((contentPoints.height * pixelScale).rounded())
            // A degenerate content rect (zero or negative after rounding —
            // e.g. a filter read before the window's content settled) must
            // not become a `.window` case that traps later inside
            // `.geometry()`'s call to `DisplayGeometry.init`. Failing here,
            // at the boundary that already returns `Optional`, keeps the
            // failure inside this function's own error channel instead of
            // a precondition three calls downstream (`AGENTS.md`: failure
            // must land outside the value range, not inside a later one).
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

    public init(onSelect: @escaping @Sendable (CaptureSource?) -> Void) {
        self.onSelect = onSelect
        super.init()
    }

    /// Marks the shared picker active and shows it. `SCContentSharingPicker`
    /// is a singleton per the header (`.shared`) — this type is an observer
    /// of it, not an owner. Main-actor because it touches AppKit-adjacent,
    /// UI-presenting API, unlike the callbacks below.
    @MainActor
    public func present() {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        picker.add(self)
        picker.present()
    }

    /// `init(pickerFilter:)` is main-actor isolated (its own header explains
    /// why), so this hops there rather than calling it inline — the callback
    /// itself stays `nonisolated`, matching the other two below and the
    /// class-level doc comment's reasoning.
    public nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                                  didUpdateWith filter: SCContentFilter,
                                                  for stream: SCStream?) {
        let onSelect = self.onSelect
        Task { @MainActor in
            onSelect(CaptureSource(pickerFilter: filter))
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
