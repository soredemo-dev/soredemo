# The editor opens as a window that fills the screen

2026-10-25. The owner asked for the move from a finished take into the editor to be smoother.
It cannot be, while the editor opens in native full screen: the move into a new Space is
composited by the window server and nothing an app draws can cover it or change it —
`the-editor-comes-out-of-the-notch.md` measured a 0.4 s hole, and two real fixes reduced it to
flickers it could not remove. Native full screen also arrives late: `FullScreenEntry` asks until
AppKit accepts, because a toggle at `didBecomeKey` is ignored, so the window is first seen as a
window and then swept away into its Space.

## The question, and the owner's answer

Asked with the cost of each written beside it:

| | what a person sees | cost |
| --- | --- | --- |
| **a window filling the screen** — chosen | the editor comes forward at its final size on the same desktop, in about a third of a second | the menu bar and the Dock stay; full screen is the toolbar's Full Screen button, or ⌃⌘F |
| native full screen, as now | a window, then the system's Space transition | not smoother; the part that is rough is not this app's to change |
| a setting choosing between them | either | two opening paths to keep working, for a preference nobody has asked for |

**Why this is not the design that was rejected in September.** That one filled the screen with
a borderless cover and gave up what a Space gives: a Mission Control tile, ⌃→, and the green
button's meaning. This is an ordinary titled window sized to the screen's visible frame, so it
keeps all three — it is a tile in Mission Control, ⌃→ moves between desktops as with any window,
and the toolbar's Full Screen button and ⌃⌘F still take it into full screen, where the toolbar behaviour that already
exists still applies.

## Decisions

- **`WindowConfigurator.opensFullScreen` is turned off**, not deleted: the full-screen path is
  still the Full Screen button's and ⌃⌘F's, and `FullScreenEntry` stays for the day the switch is turned back.
- **The window fills the visible frame** — the screen less the menu bar and the Dock — rather
  than `WindowSizeFloor`'s 92%, which was the size for a window a person had chosen to make
  smaller. The floor still applies when it leaves full screen.
- **It arrives at its final size; it does not grow out of the menu bar — though that was built
  first and measured.** Growing the window's frame from a small rectangle under the menu bar
  re-lays the whole editor out on every step of the animation, and the first steps land while
  the main thread is still drawing the editor for the first time. Logged from inside the app:
  the frame sat at its 182 × 104 start for 0.1 s, then jumped to 1266 wide by 0.2 s — what a
  person sees as a large window lurching, not one arriving. (The window was not held at its
  minimum size, as first guessed: `setFrame` took 182 × 104 without complaint. The log said so
  before any fix was written.)
- **So the layout is paid while it is hidden, and what moves is a layer.** `EditorOpening.present`
  sizes the hidden window to the visible frame, lays it out and draws it, and only on the next
  turn fades the window in while the content's layer scales from 96 % about its centre — the
  GPU's work, no layout per frame. Logged: alpha 0.20 at 30 ms, 0.51 at 100 ms, 0.88 at 200 ms,
  1 at 300 ms; one hold of about 30 ms near the start.
- **Hidden until it is drawn.** The window is made transparent when it is first attached, so
  the default-sized frame AppKit paints before the window becomes key is never seen. **A
  transparent window that never becomes key would be an editor nobody can see**, so a deadline
  shows it regardless — `EditorOpening.revealDeadline`, 1.5 s. Seen working: with `present`
  disabled, gate 6 found the window visible at its default 900 × 492. The full-screen path had
  the opposite rule (`alphaValue = 0` reads as not on screen and stops the toggle), which is one
  more reason the two paths are not mixed.
- **One animation, not two: AppKit's own is turned off.** A window ordered front already
  animates — AppKit infers a document window's zoom-in from its type — and growing it from the
  menu bar on top of that would be the September mistake again, two transitions telling two
  stories. The editor's window sets `animationBehavior = .none`, which `NSWindow.h` describes as
  exactly this: "Suppress inferred animations", for a window whose app animates it itself. Not
  `NSAutomaticWindowAnimationsEnabled`: that is a person's system-wide default, not the app's to
  change.
- **The end frame is the system's own "Fill".** Since macOS 15 the Window menu's Fill, ⌃fn F
  and dragging a window to the menu bar make a window cover the visible frame; this opens it at
  that frame, so a person who then tiles it, or double-clicks its title bar, gets what every
  other window gets, from the same place. (Zoom is different — it asks the app for an ideal size
  — and is left alone.)
- **The display's scaling needs nothing.** A MacBook runs a scaled mode by default ("looks like"
  1512 × 982 on a 3024 × 1964 panel), and every frame here is in points from `visibleFrame`,
  which already is the scaled size; tested on a screen off the origin, and the arithmetic has no
  scale in it to get wrong.
- **Reduce Motion**: the fade alone, 0.2 s, no scale.
- **An editor already open** is brought forward and grown to the visible frame the same way, if
  it is smaller; one that is already full screen is left there.

## Found by the owner the same day: a recording opened a small window, unanimated

The first build waited for the window to become **key** before filling it — a rule inherited
from the full-screen path, whose toggle AppKit ignores on a window that is not key. Filling has
no such need. After a recording the app is not frontmost, and `WindowConfigurator` had already
measured key arriving one time in four on that path; when it did not, the reveal deadline
showed the window where it was, 900 × 492, with no fade. Gate 6 never saw it: it launches the
app from a shell, where the app is frontmost and the window always becomes key.

So the fill runs a turn after the window is attached, key or not, and the deadline itself
fills and fades rather than showing a small window. The full-screen path still waits for key.

## Sources

- `NSWindow.h`, macOS 27 SDK: `NSWindowAnimationBehaviorNone` — "Suppress inferred animations".
- Apple, [`animationBehavior`](https://developer.apple.com/documentation/appkit/nswindow/animationbehavior-swift.property).
- Fill and Zoom in macOS 15: [MacMost](https://macmost.com/window-tiling-in-macos-sequoia.html),
  [TidBITS](https://tidbits.com/2024/11/08/how-to-tame-sequoias-window-tiling/).

## How it is verified

`EditorOpeningTests`: the content scales about its centre, checked on a non-square layer — a scale
about the corner, which a layer anchored at its corner does unasked, moves the centre and fails.
Gate 6, `check-editor-opens-full-screen.sh`, asked AppKit whether the window was full screen; it
now asks whether the window fills the visible frame and is visible, and prints each edge's
distance. Measured on a 1512 × 982 screen: asked for (0, 84, 1512, 865), AppKit settled the window
at (0, 86, 1512, 863) — its bottom two points up — so the gate allows two points per edge and
prints them. Red with `present` disabled (the window stayed 900 × 492 and was shown by the
deadline). Looked at: a screen recording of the opening, stepped at 30 fps — one fade at the final
frame, no Space, no jump.
