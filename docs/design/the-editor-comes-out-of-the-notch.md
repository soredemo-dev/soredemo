# The editor comes out of the notch

> **Withdrawn 2026-09-18. The code is deleted; this document is kept because the measurement
> that killed it is the useful part, and because the shape of the mistake is one this project
> keeps making.**
>
> **What was wrong was not the animation. It was a claim written as a fact.** The design rested
> on this sentence:
>
> > A full-screen panel … is what hides AppKit's own full-screen zoom — the desktop sliding to
> > a new Space is the one part of this that cannot be animated by us and **must simply not be
> > seen**.
>
> It was never measured. A screen recording of a real opening — 20 fps, the Dock's brightness as
> the indicator of whether the cover was working — says it was seen:
>
> | | covered | exposed |
> |---|---|---|
> | as built | 0.45 s | **0.4 s**, Dock at full brightness, a windowed editor with its title bar |
> | after two real fixes to the cover | three runs | two flickers of 0.1 s |
>
> The two fixes were real and are worth keeping in mind. `panel.isFloatingPanel = true`
> **overwrites** `panel.level`, and those two lines were in that order — so a cover meant for
> `.screenSaver` ran at `.floating` and the Dock drew over it for the whole of this design's
> life, invisible to eight gates and four rounds of screenshots. And
> `styleMask.contains(.fullScreen)` is true from the moment a transition BEGINS, so the cover
> left while macOS was still working. Neither fix removed the flickers, because the Space is
> composited by the window server and an app cannot draw over it.
>
> **So there were two transitions telling two stories** — "the editor comes out of the notch"
> and "a window moved into a new Space" — and that is not a timing problem. Filling the screen
> without a Space was built and measured (one continuous cover, no hole) and then rejected for
> what it cost: no Mission Control tile, no ⌃→, and the green button losing its meaning. The
> editor keeps native full screen and AppKit's transition is the only one.
>
> **What is worth taking from this if anyone comes back to it:** the geometry was right and it
> was tested on thirteen Mac shapes; `NotchGeometry`, `ScreenMetrics` and their matrix are in
> the history at `git log -- Soredemo/App/NotchGeometry.swift`. The one idea taken from another
> app — a notch assistant's outward-curling top corners — is the detail that separates "the notch got
> bigger" from "a panel is hanging under the notch", and it is worth remembering wherever a
> notch surface is drawn again.

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
| the corner | a notch assistant's `NotchIslandShape`: the top corners curve OUTWARD into the menu bar | the detail that separates "the notch got bigger" from "a panel is hanging under the notch" — and the one thing here that was taken from another app rather than derived |

Its defaults, which are a reasonable starting point and not gospel: top radius 15, bottom radius
20, opening `.bouncy(duration: 0.4)`, closing `.smooth(duration: 0.4)`.

**Nobody appears to have done the transition this is about.** Every one of those apps expands the
notch into a panel that stays near the notch. Growing it into a *window* — and specifically into
a full-screen window — is not a thing any of them do, and no write-up of it turned up. So the
prior art settles the surface and the metrics, and the rest of this is ours.

## Every number below is one machine's, and the design must not be

This was written from a 14-inch MacBook Pro at 1512 x 982. The numbers in the next section are
true of it and of nothing else, and treating them as properties of "the notch" is the mistake
this section exists to stop.

**The same panel offers eleven scaled modes**, from 960 x 600 to 1800 x 1169 points. The notch is
a fixed number of PIXELS, so its size in points moves with every one of them — roughly 117 points
wide at the smallest and 220 at the largest. A design that knows "185" knows nothing.

**A notched Mac can report no notch.** macOS lists each mode twice: 1512 x 982 includes the notch
strip and 1512 x 945 does not, and in the second kind the screen has no auxiliary areas and no
top safe-area inset. So the question is never "is this a MacBook Pro" — it is "does this screen,
right now, in this mode, have a notch", asked of the screen.

`NotchGeometry` and `ScreenMetrics` hold the whole decision as a value with no constants in it,
and `NotchGeometryTests` runs it over thirteen real geometries: this machine, four of its own
scaled modes, the 16-inch and both Airs, the notch-excluded mode, three external displays and a
pre-notch MacBook. What is asserted there is **properties** — the shape starts inside its own
screen, starts centred, always grows, ends on the frame it was handed — never a golden rectangle.
Two controls confirm the matrix can fail: writing the fallback as this machine's 185 points
turns `theFallbackIsTheSameShareOfEveryScreen` red, and deciding "has a notch" from the
safe-area inset alone turns `oneAuxiliaryAreaIsNotANotch` red.

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

**On this machine.** The distance is `menubarHeight - safeAreaInsets.top`, and nothing published
says those two are one point apart on every Mac, in every mode, in every future release. So the
shape reports `gap` and answers `startsFlush`, and the animation asks rather than assumes: flush
means grow straight out, and anything else means travel that distance first so the shape reads as
coming from BEHIND the notch rather than detaching from it. `aScreenWithRoomBetweenTheNotchAndTheWindowSaysSo`
is the test that keeps the question open.

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

- **The top corners are SQUARE and flare outward, and this is the one thing the shipping notch
  apps had that this design did not.** It first said the top corners hold the notch's radius the
  whole way, so the shape stays attached to what it came from. Photographed at the first frame,
  that is a rounded-topped pill hanging under the menu bar — attached to nothing. The hardware's
  sides run straight up into the menu bar and **curl outward** where they meet it, and
  [a notch assistant]'s `NotchIslandShape` is built around exactly that: "its top corners curve outward
  into the menu bar (like the hardware notch does)". `NotchGeometry.topFlare(atProgress:)` is
  that curl, as a fraction of the notch's height rather than their six points, and it closes
  squared so it is a quarter of the way at halfway and gone at the end — a full-screen rectangle
  with two wedges at the top is not a shape anything has. Only the bottom corners open, from the
  notch's radius to the editor's.
- **Bottom edge leads.** On this machine it travels 918 pt against the sides' 663 each; the
  ratio, not the numbers, is what matters and it comes out similar on every geometry in the
  matrix because a notch is always much wider than it is tall. Letting the bottom reach
  its destination slightly ahead reads as the shape being *pulled down* rather than inflated.
- **A curve, not a spring — changed on building it.** The design said to start at
  `.spring(duration: 0.45, bounce: 0.15)` and look at it. What is written is a cubic ease-out,
  because the shape is not animated by SwiftUI at all: the clock is linear and
  `NotchGeometry.rect(atProgress:)` interpolates every edge itself, which is what stops width
  and height being stretched by one animation at 8.2x and 29.7x. A spring's overshoot in that
  arrangement would put the shape's edge past the screen for a frame or two, which is not a
  flourish on a rectangle that is already the size of the display.

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

`hasNotch` is `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` both being non-nil **and** a
non-zero `safeAreaInsets.top` — half an answer is not a notch, and a screen mid-reconfiguration
reports half answers. It is not "is this a MacBook Pro": a notched panel in a notch-excluded mode
belongs here too.
a notch library's fallback is a 300 pt strip of the menu bar's height at the top centre. The
shape is right; the fixed number is not — 300 points is a third of a small external display and a
sixth of an ultrawide. **A fraction instead**, 12.2%, which is the notch's own share of a
14-inch, so the gesture is the same size relative to the screen wherever it plays — **the idea is "the editor comes out of the top of the screen", and
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

## What building it changed

**The shape is the editor's own ground, not black, and it carries a hairline edge that fades.**
The first version filled it with `Color.black`, and two things were wrong with that. It hands
over to a real window at the end, and a shape that is not the colour of the thing it becomes
hands over with a step in it — so it is `Theme.Surface.base`. And at notch size, against a
desktop the backdrop has barely started to darken, a near-black shape on a dark strip is
invisible: the first tenth of the gesture was nothing happening. The same light edge `Glass`
uses, at `Glass.edgeOpacity`, fading out as the shape takes over the screen.

**`UnevenRoundedRectangle`, not a hand-written `Shape`.** A custom one has to name `CGRect` in
`path(in:)` and D6 rule 5 forbids that in the app target. The built-in does the one thing the
design needs — different radii top and bottom — so the rule cost nothing here.

**A bare number after a launch flag is a document.** `--show-notch-transition 2 20` put
`無法打開文件「20」。檔案不存在。` on screen, over the animation being photographed: AppKit
hands unrecognised positional arguments to the document machinery. The options are
`--name=value` for that reason and no other.

**Photographing it needed a slowdown, and the slowdown cannot settle the durations.**
`screencapture` takes about a third of a second a frame and the whole gesture is 0.55 s; six
shots fired at it from a fixed sleep caught nothing, twice. `--notch-slowdown=N` stretches
wall-clock time without changing the animation's own timeline, which photographs the SHAPE.
Speed is a judgement and the instrument for it is a person at 1x.

## What this does not answer

- **The exact durations and the easing.** Written above as a starting point with the reasoning,
  and still not watched at full size by anybody. `--show-notch-transition` with no options plays
  it at 1x, which is the only way this gets settled.
- **Whether the backdrop should be black or a heavy blur of the desktop.** Black is honest about
  what is happening — the screen is changing Space — and a blur is prettier. It has not been
  looked at either way.
- **Whether the notch's real corner radius is 15/20.** Those are another library's numbers, not
  Apple's published ones and not measured here — and, like every other length, they are in points
  and so want checking at more than one scale.
- **Whether `menubarHeight - safeAreaInsets.top` is one point on Macs other than this one.** The
  code no longer cares, but the answer decides whether `startsFlush` is the common path or the
  rare one, and nobody here can attach a 16-inch.

[a notch library]: https://github.com/a notch library
[a notch assistant]: read locally at ~/Documents/opensource/a notch assistant — `macos/a notch assistant/a notch assistant/NotchHUD.swift`
[panaitiu]: https://notes.alinpanaitiu.com/Fullscreen-apps-above-the-MacBook-notch
