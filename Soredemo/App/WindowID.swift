/// The identifiers `Window(_:id:)` declares and `openWindow(id:)` opens.
///
/// **Not statics on `SoredemoApp`, which is where they were.** A window id is a contract between
/// the scene that declares the window and every place that opens one, and those are different
/// files by design — the menu bar item opens the editor, the editor never opens itself. Hanging
/// the contract off the `@main` struct made every opener depend on the app lifecycle for two
/// string constants that have nothing to do with it.
///
/// **What that cost, concretely:** `scripts/run-cross-boundary-probe.sh` compiles real app
/// sources into a test binary, which cannot also contain a second `@main`. So `SoredemoApp.swift`
/// is not in its list and never can be — and `MenuBarRecorder.swift` named `SoredemoApp` for
/// these two constants alone, which put the whole recording cluster out of the probe's reach:
/// `RecordingBar` names `MenuBarRecorderPanel`, and `ContentView` — where `RecordingCoordinator`
/// lives — names `RecordingBarPresenter`. Four files unreachable, transitively, over two strings.
/// The probe's own header used to record that as a fact about the app lifecycle. It was a fact
/// about where these two lines were declared.
///
/// A `String` rather than a `case` on an enum with a raw value: `Window(_:id:)` and
/// `openWindow(id:)` both take a `String`, so a richer type would be spelled `.rawValue` at every
/// use and would buy nothing back.
enum WindowID {
    /// The editor window's identity, so `openWindow(id:)` can reach it from the menu bar item.
    static let editor = "editor"
    static let permissions = "permissions"
}
