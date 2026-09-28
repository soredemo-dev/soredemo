import AppKit
import SwiftUI

/// **Asks before the editor window closes, in front of the delegate SwiftUI gave it.**
///
/// The editor closed without a word — only quitting asked — so a recording never saved was lost
/// to the red button, and its sound played on after the window had gone (2026-09-28). SwiftUI has
/// no "should this window close" for a `WindowGroup`: `windowDismissBehavior(.disabled)` removes
/// the close button, which is a different thing. So this stands in front of SwiftUI's own
/// delegate, answers `windowShouldClose`, and hands every other message straight through —
/// replacing SwiftUI's delegate outright would break what it does with the window.
///
/// **Installed again on every `configure()`**, because SwiftUI may set the delegate again; a
/// second install replaces the question rather than wrapping the guard in another guard.
/// `EditorCloseGuardTests`.
@MainActor
final class EditorCloseGuard: NSObject, NSWindowDelegate {
    // `nonisolated(unsafe)`: the two NSObject overrides below are nonisolated and read it. Safe
    // because it is written once, in `init`, before the guard is anyone's delegate, and AppKit
    // messages a window's delegate on the main thread.
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    private let shouldClose: @MainActor () -> Bool
    private let didClose: @MainActor () -> Void

    /// `window.delegate` is weak, so the guard is kept alive here — keyed WEAKLY on the window,
    /// so it goes when the window does.
    private static let alive = NSMapTable<NSWindow, EditorCloseGuard>.weakToStrongObjects()

    private init(original: (any NSWindowDelegate)?, shouldClose: @escaping @MainActor () -> Bool,
                 didClose: @escaping @MainActor () -> Void) {
        self.original = original
        self.shouldClose = shouldClose
        self.didClose = didClose
    }

    /// `shouldClose` asks the person; `didClose` runs only for a close that is going ahead —
    /// after both this and SwiftUI's delegate have agreed.
    static func install(on window: NSWindow, shouldClose: @escaping @MainActor () -> Bool,
                        didClose: @escaping @MainActor () -> Void) {
        let underneath = (window.delegate as? EditorCloseGuard)?.original ?? window.delegate
        let installed = EditorCloseGuard(original: underneath, shouldClose: shouldClose, didClose: didClose)
        alive.setObject(installed, forKey: window)
        window.delegate = installed
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        let theirs = original?.windowShouldClose?(sender) ?? true
        if theirs { didClose() }
        return theirs
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || ((original as? NSObject)?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? { original }
}

/// Puts `EditorCloseGuard` on the window this view is in, and again whenever that window becomes
/// key — SwiftUI may reset the delegate, and a guard it removed would close silently again.
struct EditorCloseHook: NSViewRepresentable {
    let shouldClose: @MainActor () -> Bool
    let didClose: @MainActor () -> Void

    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.shouldClose = shouldClose
        view.didClose = didClose
        return view
    }

    func updateNSView(_ view: HookView, context: Context) {
        view.shouldClose = shouldClose
        view.didClose = didClose
    }

    final class HookView: NSView {
        var shouldClose: (@MainActor () -> Bool)?
        var didClose: (@MainActor () -> Void)?
        private var keyObserver: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = nil
            guard let window else { return }
            install(on: window)
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.install(on: window) }
                }
        }

        private func install(on window: NSWindow) {
            EditorCloseGuard.install(on: window,
                                     shouldClose: { [weak self] in self?.shouldClose?() ?? true },
                                     didClose: { [weak self] in self?.didClose?() })
        }
    }
}
