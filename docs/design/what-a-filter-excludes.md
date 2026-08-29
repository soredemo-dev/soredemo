# What a capture filter excludes

*Code: `Core/Sources/Capture/CaptureSource.swift`.*

Only `SCContentSharingPicker` produces a live `CaptureSource`. A hand-built
`SCContentFilter` bypasses the picker's permission affordances and Presenter
Overlay, so `filter(excluding:excepting:showsMenuBar:)` rebuilds a filter from a
value the picker already vetted — which exposes no surface the person did not
choose.

## A window filter for a window, and this reverses a reversal

D2-13 chose `desktopIndependentWindow`. The window-capture repair replaced it with
a display filter plus `sourceRect`, on three arguments. A real recording then
captured the Dock, which that repair's own comment had predicted in as many
words — "anything overlapping the window's rect is captured with it. A real
regression in isolation, accepted because…". All three arguments dissolve on
inspection:

1. *"the buffer can then be sized to the window"* — a window filter does not stop
   the buffer being sized to `window.frame × backing scale`. The two were never in
   tension.
2. *"ScreenCaptureKit crops at the source, so nothing downstream applies an
   offset"* — a window filter's frame *is* the window, so there is no offset to
   apply either.
3. *"macOS composites the purple recording indicator into the frames"* — it does
   not, measured; the indicator is drawn by the window server outside the captured
   content.

What a window filter gives that no amount of cropping can: **other windows, the
Dock, the menu bar and notifications are excluded by construction**, because the
capture is of the window rather than of the screen the window happens to be on.

`sourceRect` is therefore not set for a window — it would crop the window's own
content — and `WindowFollower` no longer reconfigures the stream on a move, since
ScreenCaptureKit follows the window itself. The follower still updates the
pointer's viewport, which nothing else can do.

## This process's own windows

The recording that proved this necessary has the floating control bar sitting
across the bottom of the picture for its whole length. `excludingWindows: []`
excluded nothing, and a recorder that puts a control strip over the screen and
then records the screen records the strip.

`excludingApplications:` rather than a list of window objects: the bar is created
*after* the filter is built — it appears when the capture starts — so a window
list captured at filter time would not contain it. Excluding the application
covers every window this process has now or opens later, which for a recorder is
exactly the rule wanted. It is the visual half of what
`excludesCurrentProcessAudio` already did for sound.

A window capture needs none of this: `desktopIndependentWindow` captures one
window and nothing that overlaps it.

**The list is an argument with an empty default**, not a static this type reads.
The applications come from `SCShareableContent`, which is `async`, and this is
not; a static would have to be written before every call and would be wrong
exactly once — on the first recording after launch, which is the one a person
judges the product by.

## Excepting, and why it exists

`excepting` names windows that come back into the picture *despite* their
application being on the exclusion list. It exists because the Dock's process also
draws the wallpaper: hiding the Dock means excluding `com.apple.dock` and then
putting its five wallpaper windows and four full-screen backdrops back.
`CaptureExclusions` works out that list; `filter` only passes it on.

Empty by default, and empty is the honest default: excepting a window from an
application nobody excluded does nothing at all.

## The menu bar

`showsMenuBar` is `SCContentFilter.includeMenuBar`, passed through rather than
reasoned about — the documented switch, and it needs none of the exclusion
machinery above because it is a property rather than a list. Measured: it takes
the menu bar's status items with it and does not change `contentRect`.

## Presenting the picker

Nothing in `CaptureSourcePicker` is exercised by a probe or by `swift test`: the
observer callbacks fire only after a real click in Control Center's picker UI.

**`isActive = true` puts a screen-sharing indicator in the menu bar, and it is the
system's, not ours.** That is what the flag is documented to do — it tells macOS
this app may start sharing at any moment, so macOS says so. Nothing set it back,
so one cancelled picker left a green recording pill in the menu bar for the rest
of the session, next to an app recording nothing: the strongest claim a Mac can
make about an app, made falsely and permanently.

**`remove` matters as much.** `SCContentSharingPicker` is a singleton and it
*retains* its observers. Without removal every attempt added another and none was
released, so the second cancel called `onSelect(nil)` twice, the third three
times, each on a picker whose owner had already dropped it. Both are done from all
three terminal callbacks — chosen, cancelled, failed to start — because each is
the end of that picker's life and only one is the happy one.

**Narrowing the picker's modes is what makes two buttons two buttons.** A "Record
Screen" button that opened the same picker as "Record Window" would be two buttons
doing one thing. It is also the only honest way to offer them: this app does not
enumerate windows itself — the system picker is the permission-correct path and
the one Apple keeps working.
