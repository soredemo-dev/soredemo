# The editor comes out of the notch

*A design, not an implementation. Every number in it was measured on the machine this was written
on; the ones that still need a human to look at them are named as such.*

## What already exists, and what does not

The notch has an established interaction vocabulary on macOS and it is worth not reinventing it.
Four shipping apps put a Dynamic-Island-style surface there — NotchNook, a notch app, Alcove,
Notchy — and one of them, [a notch library], is an open-source library whose only job is this.

Read for its decisions rather than its code, it settles three things:

| | what it does | why it matters here |
|---|---|---|
| the surface | `NSPanel`, `.screenSaver` level, clear background, no shadow, `[.canJoinAllSpaces, .stationary]` | **the same panel Soredemo already builds twice** — `CountdownPanel` and `RecordingBarPanel` are this, line for line |
| the metrics | notch width is `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width`; height is `safeAreaInsets.top` | the notch is measurable, not a guess |
| the shape | `topCornerRadius` and `bottomCornerRadius` kept separate | what makes an expanded shape read as *the notch, larger* rather than a new rectangle |

Its defaults, which are a reasonable starting point and not gospel: top radius 15, bottom radius
20, opening `.bouncy(duration: 0.4)`, closing `.smooth(duration: 0.4)`.

**Nobody appears to have done the transition this is about.** Every one of those apps expands the
notch into a panel that stays near the notch. Growing it into a *window* — and specifically into
a full-screen window — is not a thing any of them do, and no write-up of it turned up. So the
prior art settles the surface and the metrics, and the rest of this is ours.

## The measurement that decides the whole design

On this machine:

```
screen            1512 × 982
safeAreaInsets.top  32          menubarHeight 33
notch             185 × 32 pt, at x 663.5, y 950   (5.78 : 1)
native full screen  (0, 0, 1512, 949)
```

The full-screen window's top edge is at **949**. The notch's bottom edge is at **950**.

**They are one point apart.** So a shape that starts as the notch and grows into the full-screen
frame is *continuous* — it grows down and outward from the notch's own bottom edge and lands
exactly where the editor will be. There is no gap to disguise and no black band to explain.

This matters because it removes a decision that would otherwise have been forced. macOS has two
kinds of full screen: the native one (`toggleFullScreen`, its own Space, top edge below the
notch) and the old-style one (borderless, auto-hidden menu bar, frame = the whole screen), which
[does extend around the notch][panaitiu]. Old-style would have made the expansion end where it
began — but it costs the dedicated Space, and this project has a design document, a gate and a
hard-won retry budget built on the native path. The one-point measurement says we do not have to
pay that.

**Width and height do not scale together.** 185 → 1512 is 8.2×; 32 → 949 is 29.7×. A
`scaleEffect` would stretch the shape nearly four times more vertically than horizontally and
distort anything drawn inside it. The animation interpolates the *frame*, not a transform.

## The transition

Four phases, 0.55 s end to end. The durations below are a starting point derived from
a notch library's 0.4 s over a much shorter distance; **they need somebody to look at them**, and
the honest way to tune them is the way the countdown was tuned — a launch flag that plays the
transition on demand, and screenshots.

**0 → 0.10 s · the ground goes dark.** A full-screen panel at `.screenSaver` level fades a
backdrop in from clear to near-black. It is full-screen from the first frame, which is what hides
AppKit's own full-screen zoom happening behind it — the desktop sliding to a new Space is the one
part of this that cannot be animated by us and must simply not be seen.

**0.05 → 0.50 s · the notch becomes the window.** Inside that panel, one rounded rectangle
starting at exactly the notch's frame and ending at exactly the window's. Overlapping the
backdrop fade by 50 ms so the two read as one gesture rather than two.

- **Top corners hold the notch's radius the whole way.** The shape stays attached to the thing it
  came out of. Only the bottom corners open, from the notch's radius to the editor's.
- **Bottom edge leads.** It travels 918 pt; the sides travel 663 each. Letting the bottom reach
  its destination slightly ahead reads as the shape being *pulled down* rather than inflated.
- Spring, not a curve. `.bouncy` over this distance is likely too much bounce at the end — a
  window that overshoots 949 pt looks like a bug, not a flourish. Start at
  `.spring(duration: 0.45, bounce: 0.15)` and look at it.

**0.35 → 0.55 s · the editor arrives.** The real window is already full screen and already
underneath — never at `alphaValue = 0`, because this project has recorded that a window at zero
alpha is not on screen as far as AppKit is concerned and `toggleFullScreen` is silently ignored
for it. It is simply covered. The panel cross-fades out over the last 200 ms, revealing what was
there all along.

**Ordering, and why it is this way round.** The window goes full screen *first*, and the shape
animates to **the frame the window actually reached**, read from the window — not to a predicted
full-screen rect. `FullScreenEntry` can fail and fall back to a grown window; an overlay that
animated to a full-screen rectangle and handed over to a 900-point window would end in a jump.
Asking beats assuming, which is the rule the rest of this codebase already runs on.

## What it does when there is no notch

Not an edge case: this machine's own external display has no notch, and neither does any Mac
before 2021.

`hasNotch` is `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` both being non-nil.
a notch library's fallback is a 300 pt strip of the menu bar's height at the top centre, and that
is the right shape here too — **the idea is "the editor comes out of the top of the screen", and
the notch is only the most literal version of it.** A Mac without one gets the same gesture from
the same place, with all four corners rounded equally because there is no notch shape to stay
attached to.

## Reduce Motion

`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` turns the whole thing off and leaves
a 0.2 s cross-fade. Not a smaller animation — an animation that travels 918 points is exactly
what that setting exists to prevent, and halving it is not honouring it.

## What could go wrong, and what would catch it

| risk | what it looks like | the check |
|---|---|---|
| the window never reaches full screen | the shape lands on a full-screen rect over a 900 pt window | animate to the window's read frame; the existing gate already asserts the window's own state |
| a second display | the panel opens on the wrong screen | the panel follows the screen the editor window is on, not the pointer — the editor is what it becomes |
| the notch metrics are nil mid-flight | a crash, or a zero-sized start | `hasNotch` is read once, at the start, and the fallback is a value not an absence |
| the transition runs on every activation | the editor re-inflates whenever you click it | it runs on the window's first appearance only |
| it outlasts the recording | a panel at `.screenSaver` level above everything | one owner, cancelled on window close, as `CountdownPresenter` is |

## What this does not answer

- **The exact durations and the spring's bounce.** Written above as a starting point with the
  reasoning; they need to be watched at full size before any of them is asserted.
- **Whether the backdrop should be black or a heavy blur of the desktop.** Black is honest about
  what is happening — the screen is changing Space — and a blur is prettier. It has not been
  looked at either way.
- **Whether the notch's real corner radius is 15/20.** Those are another library's numbers, not
  Apple's published ones and not measured here.

[a notch library]: https://github.com/a notch library
[panaitiu]: https://notes.alinpanaitiu.com/Fullscreen-apps-above-the-MacBook-notch
