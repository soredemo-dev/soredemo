import AppKit

/// What a model needs from an undo stack: a name, and a closure that puts things back.
///
/// **A seam, and it was forced by a measurement rather than chosen for taste.** The caption
/// model first took an `UndoManager` directly. Every test of it passed alone; run as a suite in
/// the app-hosted test target they took the host down with a `SIGSEGV` inside
/// `MenuBarRecorderPanel.body` — a view none of them touch — and, after one attempt at a fix,
/// hung instead with the bundle loaded and no test started. `UndoManager` installs a run-loop
/// observer to close its automatic groups and does not retain the targets it is registered
/// with, so one created and released inside a test leaves both behind in a process that keeps
/// running. Two failure shapes, one cause, and neither is the model's logic.
///
/// What is worth testing here is WHEN a step is registered — a run of typing is one step, an
/// edit that changed nothing is none — and that is this app's decision, not Foundation's. The
/// protocol lets it be checked against a recorder that is a plain object with no run loop in it.
@MainActor protocol UndoRecording: AnyObject {
    /// Registers one undoable step. `name` is what the Edit menu shows after "Undo".
    func register(_ name: String, undo: @escaping @MainActor () -> Void)
}

extension UndoManager: UndoRecording {
    func register(_ name: String, undo: @escaping @MainActor () -> Void) {
        // **Registered against the manager itself, not against the model.** The target of
        // `registerUndo(withTarget:)` is not retained; handing it a model that a window owns
        // makes the stack's safety depend on which of the two is released first. The manager
        // is always alive when it runs its own handler.
        registerUndo(withTarget: self) { _ in
            // **Asked, not assumed** — `UndoManager` runs a handler on whichever thread called
            // `undo()`, which for the Edit menu is the main one and for anything else is not
            // promised. `MainActor.assumeIsolated` alone is the shape `GlobalHotkey` records as
            // having produced an `EXC_BREAKPOINT` in this project before.
            if Thread.isMainThread { MainActor.assumeIsolated { undo() } }
            else { Task { @MainActor in undo() } }
        }
        setActionName(name)
    }
}
