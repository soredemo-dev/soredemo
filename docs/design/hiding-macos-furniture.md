# Hiding macOS furniture from a recording

*Measured 2026-08-29 and 2026-08-30. Code: `Core/Sources/Capture/CaptureExclusions.swift`,
`Soredemo/Recording/DesktopIcons.swift`.*

Three things sit in front of whatever is being demonstrated: the Dock, the menu bar, and the
desktop's icons. Two of them are now kept out of the picture without touching the machine at all.
The third still changes a preference, and this note says why the difference exists.

## The Dock: three mechanisms, and the obvious one does nothing

Every recipe online says `defaults write com.apple.dock autohide -bool true`.

**On its own that does nothing.** The Dock does not watch the key. `NSScreen.main`'s usable height
was 105 pt short of the full frame before the write, after the write, and after writing it back —
three identical readings. The preference route therefore also needs the Dock killed and relaunched.

`System Events`' `set autohide of dock preferences` *does* work live, with the Dock's pid unchanged
through `false → true → false`. But it needs an Apple Events grant, a second permission dialog, and
somebody who declines it gets a switch that silently does nothing. It persists into
`com.apple.dock` anyway, so it still owes a restore across crashes.

Both change somebody's Mac in order to change a video.

**What ships is a capture-filter exclusion.** Nothing about the machine changes: the Dock stays
where it is, the person can still click it while recording, and it is simply not in the picture.
No preference written, no process killed, no permission asked for, and no restore owed — so there
is no state a crash can strand.

### The wallpaper trap

`com.apple.dock` owns **eleven** windows, and five of them are titled `Wallpaper-<UUID>`: the
desktop picture is drawn by the Dock's own process. Excluding the application outright risks
taking the wallpaper with it.

    layer           20   1512x982   onScreen=Y  title Dock
    layer  -2147483624   1512x982               title Wallpaper-<UUID>   (six of them)
    layer  -2147483622   1512x982               title Fullscreen Backdrop (four)

Exactly one window is the Dock — `kCGDockWindowLevel`, measured at 20. So the application is
excluded and every window of it except that one comes back through `exceptingWindows`. Both
variants were captured and compared; the shipped one is the belt-and-braces version.

**What it costs:** a window of the Dock created *after* the filter is built is not in the excepted
list. In practice that is a full-screen backdrop created mid-recording. The filter is rebuilt for
every segment, which bounds the exposure.

## The menu bar: one documented property

`SCContentFilter.includeMenuBar`. It takes the menu bar's **twelve status items with it** — the
bar is one window at `kCGMainMenuWindowLevel` (24) titled `Menubar`, and Clock, Battery, WiFi,
Sound, Siri, NowPlaying and the rest are separate windows one level above at
`kCGStatusWindowLevel` (25). Turning the property off removed all thirteen, and the top of the
frame comes back showing the desktop rather than a black strip.

`contentRect` is 1512x982 either way: it hides rather than crops. That matters, because a property
that cropped would change the output's dimensions and every geometry downstream is built on those.

Worth more than tidiness: a menu bar says what time it is, how much battery is left, which network
somebody is on, and — through its extras — which applications they run.

## Why the desktop icons still restart Finder

`com.apple.finder`'s `CreateDesktop` controls whether Finder draws the desktop, and Finder reads it
once at launch. The files never move; only the drawing stops. Restarting Finder closes the Finder
windows somebody has open, which is why the switch is off by default and asked for rather than
assumed.

**A cheaper mechanism was measured and is not used yet.** Finder owns exactly one window at
`kCGDesktopIconWindowLevel` (-2147483603), and a capture with that one window excluded has the
desktop icon that was visible in the control shot gone, wallpaper untouched. No preference, no
restart, no restore owed.

It is not adopted because `SCContentFilter` offers exactly one exclusion list, this process must be
on it at APPLICATION granularity — the control bar is created after the filter is built — and so
excluding one Finder window means excluding the Finder application and naming its other windows in
`exceptingWindows`. Any Finder window opened *after* the recording starts would then vanish from
the video. For the Dock that risk is negligible; for Finder, during a demo, it is exactly the thing
somebody would open. Solving it properly means re-resolving the filter as windows appear.

## Restoring a preference exactly, including "there was no key"

For the mechanism that does write a preference, the restore has to put back what was there — which
may be *absent*. Writing `true` on the way out looks the same and leaves behind a key that was
never there; it is the kind of trace nobody notices and nobody cleans up.

So the prior value is read and stored before anything is written, and the obligation is
**persisted**: writing the key records that a restore is owed, and the app pays that debt at launch
before doing anything else. The flag is cleared only after the restore has actually happened.

`kill(pid, SIGTERM)`, not `NSRunningApplication.terminate()`. The polite quit is honoured as a
genuine quit and **launchd does not bring Finder back** — measured, no Finder after six seconds. An
unclean exit is what `killall` sends, and Finder was back in 0.25 s. Even so, nothing relies on
launchd being in that mood: if Finder has not returned within the grace period, it is launched
explicitly.
