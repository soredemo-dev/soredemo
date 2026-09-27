# The recorder lives in the notch

2026-09-27. The owner asked for an interface that hides in the notch the way a notch shelf app's does.
This is not `the-editor-comes-out-of-the-notch.md` coming back: that design grew the notch into
the EDITOR and was withdrawn because a Space transition cannot be covered. The editor stays a
window. What moves into the notch is everything around a take — which today is a menu-bar panel,
a floating bar at the bottom of the screen, and a countdown panel.

The interaction was drawn first as a tuning page ("The Transformable Notch", this session); this
document is the part of it that gets built now, and what is left for later.

## States

| state | when | what it is | size |
| --- | --- | --- | --- |
| **dormant** | nothing is happening | the notch itself; nothing drawn that the hardware does not already show | the notch |
| **glance** | the pointer is on the notch | the notch widens into the menu bar: "Record" on one side, the shortcut on the other | notch + two wings |
| **open** | glance, then a click | the recorder: what to record, microphone, camera, start | a panel hanging from the notch |
| **live** | a take is running | a red dot and the time on the left wing, the level on the right | notch + two wings, **never taller than the notch** |
| **live, expanded** | the pointer is on it during a take | pause, stop, save the last seconds | a short panel under the notch |

Events: pointer entered, pointer left, click, click outside, escape, recording began, recording
ended. The machine is a pure value (`NotchSurfaceState`) and its transitions are the tests.

Two rules decided by the recording, not by taste:

- **Live is never taller than the notch.** Anything below the notch is on the screen being
  recorded. The compact state sits in the menu-bar strip and its wings, which a display capture
  shows as menu bar anyway (the app's own windows are excluded from the capture, so the surface
  itself is never in the file).
- **Nothing activates the app during a take.** The panel is non-activating; the controls in live
  are clicks, never key focus, so the application being recorded keeps its caret.

## Geometry — reused, not re-derived

`ScreenMetrics` and the thirteen-screen matrix from the withdrawn design (`git show
e2b7863^:Soredemo/App/NotchGeometry.swift`) are ours and come back unchanged in substance: the notch
is `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width` wide and
`safeAreaInsets.top` tall, a notched Mac can report no notch, and no length is a constant.

What is new is `NotchSurfaceLayout.rect(for:on:)` — one rectangle per state — and the properties
asserted over the matrix: every state is top-aligned to the screen, centred on the notch, contains
the notch, stays inside the screen; dormant is exactly the notch; glance ⊂ open; live compact is
exactly the notch's height. Wings are a multiple of the notch's own height, so they scale with the
display mode; panels that hold controls have a minimum width in points, because text is in points.

**No notch on the screen: no surface.** The floating bar keeps doing what it does. The fallback
strip the withdrawn design drew on a plain screen existed to give a transition somewhere to start;
here there is no transition, and a black lozenge in the middle of an external display's menu bar
is not a control anybody would find.

## The surface

One `NSPanel`, borderless, non-activating, above the menu bar (`.statusBar + 1`), joining all
Spaces and full-screen Spaces, no shadow. It is the size of the largest state and never moves; the
shape inside it animates. Clicks outside the current shape pass through, the same way
`RecordingBarPanel` passes its shadow's halo through — otherwise an invisible rectangle would eat
clicks on the menu bar.

The shape keeps a notch assistant's outward-curling top corners at every size (the one idea taken from
another app, as before), with the flare a fraction of the notch's height. Its size animates on
`.spring(response: 0.42, dampingFraction: 0.84)` — the frame, never a scale transform, because
width and height grow by different factors. Reduce Motion replaces it with a 0.2 s fade.

## The pointer is read from where it is, not from hover — measured

The first build woke the notch with SwiftUI's `onHover`. With state changes logged and a pointer
resting on the notch, it went glance → dormant → glance → dormant → glance → dormant: hover reports
"left" while the shape grows under the pointer, and the click that followed landed on a surface
that had just shrunk and was never delivered. So the presenter watches the pointer (global and
local mouse monitors, which need no permission) and asks `NotchSurfacePointer` — a pure function
with **hysteresis**: the pointer enters by reaching the notch and leaves only by leaving everything
the surface has grown to. The rebuilt run logged `dormant → glance → open → dormant` for hover,
click, click outside, with no flicker; live expanded and collapsed on the pointer the same way.

Looked at on this machine, 1512 x 982: glance shows the record glyph and "Record" in the left wing
and the shortcut in the right; open shows Screen, Window and Area over the microphone and camera
menus; live shows the dot and the time left, the level right, at exactly the notch's height, and
Pause and Stop appear under it only while the pointer is there. The first open panel had 30 points
of empty space under its controls and the depth was cut to fit.

## What this replaces, and what it does not

- **The floating bar is not shown while the notch surface is.** Setting: *Recording → Controls
  in the notch*, on by default when the built-in display has a notch. Off, or no notch: the bar.
- **The menu-bar panel stays.** It is the app's presence and the only surface on a Mac with no
  notch.
- **Not in this change:** the countdown as a state of the surface, Review (the take as a
  filmstrip with keep / retake), and marks dropped during a take. They are in the tuning page and
  are the next rows; each needs its own design pass (Review activates the app, which the others
  must never do).
