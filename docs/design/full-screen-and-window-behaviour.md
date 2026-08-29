# Full screen, and what SwiftUI has no modifier for

*Measured 2026-08-26 and 2026-08-27. Code: `Soredemo/App/WindowConfigurator.swift`,
`Soredemo/App/SoredemoApp.swift`.*

## The flags

Full screen is a **collection behaviour**, not a style mask. A window only offers "Enter Full
Screen" from its green button when `.fullScreenPrimary` is set; without it the button shows a "+"
and a tiling menu, and the Window menu has no "Enter Full Screen" item at all.

`.moveToActiveSpace` is set too. This app is a menu bar item that opens an editor: somebody who
finished a recording on one Space and switched to another should get the editor where they are,
not be thrown back. The two coexist — measured, because the obvious suspicion when full screen
does not appear is that they conflict. Setting both leaves `collectionBehavior.rawValue == 130`,
which is `128 | 2`.

## `Window` versus `WindowGroup`, and the scene classification

SwiftUI classifies a `Window` scene as AUXILIARY, and an auxiliary window does not get
`.fullScreenPrimary`. Measured:

    Window       131330 = auxiliary | fullScreenAuxiliary | moveToActiveSpace
    WindowGroup   65666 = primary   | fullScreenPrimary   | moveToActiveSpace

Inserting `.fullScreenPrimary` by hand does not survive: SwiftUI strips it. So the editor is a
`WindowGroup`, which permits a second window rather than requiring one —
`EditorWindowPresence.openEditor` refuses to make one and brings the existing window forward.

## The folklore that was wrong, and how it was settled

An earlier version of the source comment said: *"this app sets no activation policy and has no
`LSUIElement`, so it is not an accessory app, whose windows genuinely cannot go full screen."*

**Both halves were false and neither had been checked.** `INFOPLIST_KEY_LSUIElement = YES` sat in
both build configurations, and `EditorWindowPresence` has always switched the policy — `.regular`
when an editor opens, `.accessory` when the last one closes.

The conclusion drawn from those false premises was false too. An isolated experiment settled it: a
bare AppKit app calling `toggleFullScreen(_:)` on a window carrying `.fullScreenPrimary` **enters
full screen under every policy** — `.regular`, `.accessory`, and accessory switched to regular —
all three reporting `didEnterFullScreenNotification` and a `.fullScreen` style mask.

So an accessory app's windows *can* go full screen. What remains missing is the ROW in the green
button's own menu, which an application does not control. `StageWindow` offers the command
directly instead, on ⌃⌘F.

## Why the size floor is applied on exit and not before

The editor opens full screen and, when it leaves, must not be a small window. Applying the floor
*first* and then toggling full screen showed three visible states in sequence, which was reported
as feeling stuck. AppKit restores the pre-full-screen frame and there is no separate API for the
restore size, so the floor is applied on `didExitFullScreenNotification` instead — and it grows
per axis, never shrinks, so a window somebody deliberately made large is left alone.

## The hook that actually fires

The first version read `view.window` once from a `DispatchQueue.main.async` in `makeNSView` and
returned silently when it was `nil` — a one-shot with a `guard` and nothing to retry it.
`viewDidMoveToWindow` fires when the view GETS a window, however late, and `updateNSView`
re-asserts afterwards so a later reset is undone on the next SwiftUI update rather than lasting
for the session.
