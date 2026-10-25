import AppKit
import QuartzCore

/// How the editor's window arrives: already at its final size, filling what the menu bar and the
/// Dock leave, faded and scaled in on the same desktop, in one animation that is this app's own.
///
/// **Not native full screen, and that is the owner's decision of 2026-10-25.** The move into a
/// new Space is composited by the window server and nothing an app draws can smooth it; a window
/// sized to the visible frame keeps its Mission Control tile and ⌃→, and the toolbar's Full
/// Screen button (⌃⌘F) still takes it into full screen. `docs/design/2026-10-25-the-editor-opens-as-a-window.md`.
///
/// **Not grown out of the menu bar, though that was built first.** Animating the window's FRAME
/// re-lays the whole editor out on every step, and the first steps land while the main thread
/// is still drawing the editor for the first time: measured, the frame sat at its 182 × 104
/// start for 0.1 s and then jumped to 1266 wide. So the layout is paid while the window is
/// hidden, at its final size, and what moves is the content's layer — the GPU's work, no layout.
@MainActor
enum EditorOpening {
    /// The content's scale when it starts to arrive. **Uncalibrated** — chosen to read as the
    /// window coming forward, as a document window does, without travelling.
    nonisolated static let startScale: Double = 0.96
    /// How long the arrival takes.
    static let duration: Double = 0.3
    /// After this a window still hidden is shown where it is, unanimated. **A hidden editor that
    /// never became key would be one nobody can see**, and becoming key is the one step whose
    /// timing this app does not control (`WindowConfigurator` measured it failing).
    static let revealDeadline: Double = 1.5

    /// A scale about the centre of a `width` × `height` layer whose anchor is its corner, as an
    /// AppKit view's layer's is: the centre stays put and the edges move toward it. Pure.
    nonisolated static func scaledAboutCentre(width: Double, height: Double, scale: Double) -> CATransform3D {
        let toCorner = CATransform3DMakeTranslation(-width / 2, -height / 2, 0)
        let back = CATransform3DMakeTranslation(width / 2, height / 2, 0)
        return CATransform3DConcat(CATransform3DConcat(toCorner, CATransform3DMakeScale(scale, scale, 1)), back)
    }

    /// Hides a window that has just been attached, until `present` shows it. AppKit's own
    /// opening animation goes too: two animations on one window tell two stories.
    static func hide(_ window: NSWindow) {
        window.animationBehavior = .none
        window.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDeadline) { [weak window] in
            MainActor.assumeIsolated {
                guard let window, window.alphaValue == 0 else { return }
                // Filled and faded in, not shown where it is: shown where it is, the deadline
                // left a 900 × 492 window that read as the editor failing to open.
                if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                    present(window, within: visible)
                } else {
                    window.alphaValue = 1
                }
            }
        }
    }

    /// Fills `visible` and shows the window. A hidden one is sized and drawn while still hidden,
    /// then fades and scales in a turn later; one already on screen is resized by AppKit's own
    /// animation. Under Reduce Motion it only fades.
    static func present(_ window: NSWindow, within visible: NSRect) {
        let hidden = window.alphaValue == 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if window.frame.width < visible.width || window.frame.height < visible.height {
            window.setFrame(visible, display: true, animate: !hidden && !reduceMotion)
        }
        guard hidden else { return }
        // The first layout and draw, paid now, while nobody can see it.
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        DispatchQueue.main.async { [weak window] in
            MainActor.assumeIsolated {
                guard let window else { return }
                if !reduceMotion, let content = window.contentView {
                    content.wantsLayer = true
                    let bounds = content.bounds
                    let arrive = CABasicAnimation(keyPath: "transform")
                    arrive.fromValue = scaledAboutCentre(width: Double(bounds.width), height: Double(bounds.height),
                                                         scale: startScale)
                    arrive.toValue = CATransform3DIdentity
                    arrive.duration = duration
                    arrive.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    content.layer?.add(arrive, forKey: "arrive")
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduceMotion ? 0.2 : duration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                }
            }
        }
    }
}
