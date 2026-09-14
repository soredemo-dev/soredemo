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

## How the editor came to open at a size that works

The rule is now a **property**, not an event: the editor never *opens* smaller
than `openingFraction` of the screen it opens on. It grows a window that is under
that and never shrinks one that is over, so a person who has made theirs larger
keeps it. The fraction is of `visibleFrame`, which already excludes the menu bar
and the Dock — every display is a different size, and a fixed number chosen on one
machine is wrong on all the others.

That is the third design. The one-shot was right in principle: somebody who sizes
this window has decided, and overwriting that on every launch breaks the
producer-value rule. What it was wrong about is that "once ever" is one flag, and
a flag is spent by things that are not a decision. Measured on a real install, in
order:

- `editorHasBeenSizedGenerously` read `1` while the editor still opened at its
  content's size, because the flag was written *before* the frame was applied and
  anything in between burnt it.
- `editorFirstOpenSizeApplied`, the key that replaced it, was spent correctly —
  and then the scene changed from `Window` to `WindowGroup` so its window could go
  full screen, which gave AppKit a **new** autosave key
  (`…editor-AppWindow-1`) holding `900 × 512`. A frame smaller than the window's
  own minimum, restored on every open, with the flag already spent and no second
  chance in it.

**What this costs, stated rather than discovered:** a person who deliberately
makes the editor small and closes it gets it back at full size next time. That is
a real loss of a real preference, and it is the trade that was chosen — an editor
that opens unusably small is the failure people actually reported, twice.

### One transition, not three

The first version grew the window to 92% and toggled full screen afterwards, on
the reasoning that AppKit restores the pre-full-screen frame. That is true, and it
made opening the editor show the window at its old size, then grow, then
transition — three visible states where a person wants one. Reported as
"感覺很卡", and it was.

So the floor moved to the other end: it is applied when full screen is *left*, in
`keepUsablyLarge`. AppKit restores whatever was autosaved there, which has already
once been that `900 × 512` frame, so leaving full screen would otherwise drop the
editor straight back into it. Applied on every exit rather than once, for the same
reason the open-size rule is a property: a flag is spent by things that are not a
person's decision.

## Hiding the toolbar in full screen

In full screen the toolbar should get out of the way and come back when you reach
for it, which is what every full-screen Mac app does and what this one did not:
the title bar and its buttons stayed drawn across the top of the picture.

**Presentation options on the notification, not a window delegate.** The
documented route is `window(_:willUseFullScreenPresentationOptions:)`, and this
window already has a delegate — SwiftUI's own, which drives the scene. Replacing
it breaks the scene; proxying it means forwarding every selector SwiftUI might
add. Setting `NSApp.presentationOptions` on entry is the same setting by the other
supported route, and it is undone on exit rather than left applied to whatever
window is frontmost next.

**All four options, because AppKit requires three of them together.**
`autoHideToolbar` must be accompanied by `autoHideMenuBar`, and `autoHideMenuBar`
by `autoHideDock` or `hideDock` — an incomplete set is an exception, not a partial
effect. `autoHideDock` rather than `hideDock`: the Dock should come back with the
menu bar when a person reaches for either, not be gone for the session.

## Two AppKit details the code cannot do without

**`.fullScreenNone` is removed before `.fullScreenPrimary` is inserted**, because
the two are mutually exclusive and `fullScreenNone` wins. SwiftUI sets it on a
`Window` scene that has a default size, and an `insert` beside it does nothing —
measured, `collectionBehavior` read back as
`primary | fullScreenNone | moveToActiveSpace` with the insert in place. The scene
no longer asks for a default size, which is what actually fixed it; the removal is
a second lock on the same door for a scene modifier added later.

**The frame is set after the window has become key**, not in `makeNSView`. That
runs while the hierarchy is still being assembled, and AppKit restores an
autosaved frame somewhere after it — a frame set then is a frame the restore
overwrites, silently, which looks exactly like the code never ran.

## The scene type, and how it was settled

The green button offered tiling and no Full Screen row, and `WindowConfigurator`
inserting `.fullScreenPrimary` looked like it had worked and had not. Two separate
causes, both found by logging the editor window's own `collectionBehavior` from
inside a running build rather than by reasoning about the API.

### `Window` is classified as auxiliary

Measured 2026-08-27, at attach and three seconds later:

```
Window       131330 = auxiliary | fullScreenAuxiliary | moveToActiveSpace
WindowGroup   65666 = primary   | fullScreenPrimary   | moveToActiveSpace
```

SwiftUI classifies a `Window` scene as AUXILIARY, and an auxiliary window gets
`fullScreenAuxiliary` — "may join another app's full-screen space" — rather than
`fullScreenPrimary`. The green button reads the latter. `WindowConfigurator`
inserted the flag and SwiftUI stripped it again within three seconds, which is why
every earlier attempt appeared to work.

So the editor is a `WindowGroup`.

**The single-window rule survives, by hand.** One recording is open at a time: a
second window would be a second set of models over the same `StageCompositor`
statics, which are process-global because AVFoundation owns compositor instances,
and the two windows would disagree. `WindowGroup` *permits* a second window rather
than requiring one, and `EditorWindowPresence.openEditor` refuses to make one — it
brings the existing window forward instead.

### `.defaultSize` disables full screen

Measured 2026-08-26 in an isolated SwiftUI `Window` scene, reading
`collectionBehavior` back at 0.2 s, 1 s and 3 s:

```
with    .defaultSize  →  66050 = primary | fullScreenNone   | moveToActiveSpace
without .defaultSize  →  65666 = primary | fullScreenPrimary | moveToActiveSpace
```

`.fullScreenNone` is the flag that says a window cannot go full screen, and it is
what makes the green button show a "+" with a tiling menu and no Full Screen row.
SwiftUI sets it for a scene with a default size and re-asserts it after every
update, so an `insert(.fullScreenPrimary)` never survived — the two are mutually
exclusive and `fullScreenNone` wins. Removing it first does not help; SwiftUI puts
it back.

The modifier had been added to stop the editor opening at its content's size,
which was the wrong tool for that job: the opening-size rule above already gives
the editor most of the screen, and unlike a default size it does not tell AppKit
the window is fixed.

`.contentMinSize` is measured innocent — the run with it and without a default
size is the one reporting `fullScreenPrimary`. The floor comes from the content,
the ceiling from nothing, so the editor resizes freely.

## Why `LSUIElement` stays, and why full screen is a property rather than an event

*Moved out of `Soredemo/App/EditorWindowPresence.swift` 2026-08-30. The `LSUIElement`
half was attached to `openEditor`, which is not what it is about — it is about the
Info.plist flag and the experiment that put it back.*

**`LSUIElement` stays, and an experiment is why.**

It was removed on 2026-08-26 on the reasoning that a UIElement app's windows cannot go
full screen, which is what `WindowConfigurator`'s header claimed and what the folklore
says. Two measurements killed that. First, the app still reported
`type="UIElement"` to LaunchServices with the flag gone, because this very function
makes it one a moment later — the flag was not what decided the process's type. Second,
an isolated AppKit app entered full screen under EVERY policy, `.accessory` included.
So the flag was neither the cause nor a cost worth paying to remove, and putting it back
is cheaper than a launch that shows a Dock tile for a frame.

What was actually missing is the row in the green button's menu, which no app controls.
`StageWindow` offers the command on ⌃⌘F instead.
Opens the editor, or brings the one that exists forward.

**`WindowGroup` permits a second window and this is what refuses one.** The scene had to
become a group so its window would be full-screen capable — see `SoredemoApp` for the
measurement — and a group's `openWindow(id:)` makes a NEW window every call. Two editors
would be two sets of models over one set of process-global `StageCompositor` statics,
which is the arrangement the scene was a `Window` to avoid.

Matched on the window's `identifier`, which SwiftUI stamps from the scene's id, rather
than on the title: the title is the recording's name and changes with it.

**Full screen is a property of being shown, not an event on the window's first key.**
`WindowConfigurator` enters it from a one-shot `didBecomeKey` observer, which fires when
SwiftUI CREATES the window and never again — so the first recording opened full screen
and every later one, arriving at a window that already existed, did not. Reported as
exactly that: "when finish recording it still doesn't go into full screen for the
editor".

This is the same correction the opening SIZE went through: a rule spent by one event is
a rule that stops applying, and the honest shape is a property re-established each time.

**The cost, stated rather than discovered**: somebody who deliberately left the editor
windowed and then records again is put back into full screen. Acceptable here and not in
general, because this function has ONE caller — a new recording or a newly opened project
— and that is precisely the moment full screen is wanted. It is not a general
"bring the editor forward".

## `.moveToActiveSpace` and full screen are mutually exclusive

*Measured 2026-09-15, after the editor was reported as "not full screen" for the third time.*

They ask for opposite things. Full screen gives a window its **own Space**; `.moveToActiveSpace`
says follow whichever Space is in front. AppKit resolves the contradiction by **silently
refusing the transition** — no error, no warning, a window that sits at the size it was given.

Measured in an isolated forty-line AppKit app, one variable changed:

| collection behaviour | result |
|---|---|
| `fullScreenPrimary \| moveToActiveSpace` | `fullScreen=false`, frame `(0, 84, 1512, 865)` |
| `fullScreenPrimary` | `fullScreen=true`, frame `(0, 0, 1512, 949)` |
| inserted, then removed before the toggle | `fullScreen=true` |

**Where the removal goes matters, and the first fix put it in the wrong place.** Removing it
next to `toggleFullScreen` looked right and changed nothing: `configure()` runs on every SwiftUI
update and re-inserted it before the asynchronous transition finished. The only place that
survives re-assertion is the one that runs every time — so the removal is in `configure()`,
conditioned on a `hasBeenFullScreen` flag that puts the behaviour back once the window has been
full screen once. The reason it is wanted survives for the windowed case: an editor opened from
the menu bar should appear on the Space somebody is looking at.

This note's own measurements above already showed `WindowGroup` sets `moveToActiveSpace` by
default, so *not inserting* it would have changed nothing. Removing it is the only thing that
does.

**Why it took three attempts.** The repair of 2026-09-10 set the window's frame to the whole
visible area before toggling, to stop a small window flashing on the way. That made the failure
look almost like success — the editor filled the screen except for a menu bar and a title bar —
and there was nothing to tell it apart from the real thing until `SoredemoUITests` compared the
window's frame against the screen's safe area and printed both numbers.

## One registration per window, not one per SwiftUI update

*2026-09-10.* `configure()` runs on every SwiftUI update, and of its three registrations only
`watchFullScreen` was guarded — by a comment that said exactly why a second registration is
wrong. The other two were not, and both consequences were real:

* every accumulated `didBecomeKey` observer fires on the **same** notification, so
  `toggleFullScreen` ran once per registration. Two calls is enter-then-exit;
* the blocks captured `window` strongly and were never removed, so every editor window ever
  opened stayed alive with its player, its compositor and its waveforms.

Registration is keyed on the window now, the blocks hold it weakly, and the tokens go when the
view leaves the window — which can only happen *because* the blocks hold it weakly. The style
mask and collection behaviour stay outside the guard: setting a bit twice is setting it once,
and SwiftUI re-asserts them.

## `toggleFullScreen` at `didBecomeKey` is too early, and AppKit does not say so

*Measured 2026-09-15, four attempts deep into "the editor is not full screen".*

At the moment the editor's window becomes key, every documented precondition for the call is
met — the window is key, the application is `.regular` (`activationPolicy` 0) and active, the
collection behaviour is `primary | fullScreenPrimary` with no `moveToActiveSpace`, and the
style mask is resizable. `toggleFullScreen(nil)` there does nothing: no error, no warning, and
`styleMask` never gains `.fullScreen`. The identical call against the identical window five
seconds later succeeds.

| what was tried | result |
|---|---|
| synchronous at `didBecomeKey` | `fullScreen=false` |
| deferred one turn with `Task { @MainActor }` | `fullScreen=false` |
| deferred 150 ms | `fullScreen=false` |
| without the preceding `setFrame` | `fullScreen=false` |
| again, five seconds later | **`fullScreen=true`** |
| asked repeatedly until it takes | **`fullScreen=true`** |

**One earlier measurement said it worked, and was not repeated.** It came from a build carrying
a temporary diagnostic that wrote to a file between `setFrame` and the toggle; the file I/O was
the delay. A timing dependency wearing a fix's clothes, and a single unrepeated measurement is
how it got believed.

`enterFullScreen(_:attemptsLeft:)` asks again rather than naming a number: eight attempts over
two seconds, stopping **on success** rather than after a fixed count — `toggleFullScreen`
toggles, so one call too many takes the window straight back out, which is the same
even-number-of-calls defect that made the editor open windowed for a week.

