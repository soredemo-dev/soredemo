# Before and during a take: staying awake, notifications, headphones

2026-09-30. Items 1, 2 and 4 of the list the owner approved after reading a utility suite
(GPL-3.0 — read for ideas only; nothing here is adapted from it). Item 3, step numbers and a
highlighter, is `2026-09-30-steps-and-highlights.md`; item 5, screenshots, has its own document.

## 1. The display does not dim or sleep during a take

**The defect.** Nothing held the display awake. A person narrating over a still screen — the
commonest moment in a demo — touches neither mouse nor keyboard, and after the energy setting's
idle time the display dims and then sleeps. ScreenCaptureKit records what is on the display, so
the take records it going dark.

**Decision: `ProcessInfo.beginActivity([.idleDisplaySleepDisabled, .userInitiated])` for exactly
the life of a take**, screen or phone, released on every way a take ends. `.userInitiated` alone
is not enough: measured, it holds `PreventUserIdleSystemSleep` and not
`PreventUserIdleDisplaySleep` — the system stays up and the screen still goes dark.

| Alternative | Why not |
| --- | --- |
| `IOPMAssertionCreateWithName` directly | the same assertion with a C handle to leak; `beginActivity` is the Foundation spelling of it |
| hold it for as long as the app runs | a menu-bar app that keeps every Mac's display on is a battery complaint |
| hold it from choosing a target | the countdown is seconds long; the take is what needs it |

**Verified against the system, not against our own flag**: the test reads
`IOPMCopyAssertionsByProcess` for this process and asserts `PreventUserIdleDisplaySleep` is
there while held and gone after — measured in both states before the test was written (held:
`PreventUserIdleSystemSleep, PreventUserIdleDisplaySleep`; released: none).

**Not measured: the screen saver.** `IOPMLib.h` says the assertion "prevents the display from
dimming automatically"; it says nothing about the screen saver. D6b.

## 2. Notifications stay out of the video

**Asked for as "tidy the desktop and turn on Do Not Disturb before a take".** Read first, in the
SDK: **there is no public API to turn Focus on.** `INFocusStatusCenter` only *reads* whether a
Focus is on, behind an authorization and the communication-notifications entitlement. Driving
Control Center with synthetic input is the kind of thing this app refuses to do to somebody's Mac.

**What does exist is the mechanism this app already uses for the Dock, the menu bar and the
widgets: leave it out of the capture.** Banners are drawn by `com.apple.notificationcenterui`,
the same process as the desktop widgets. Measured again on 27.0 (26A428), passively: the three
widgets at layer -2147483601 and a full-screen window titled "Notification Center" at layer 21,
off screen until something shows in it.

**Decision: `CaptureExclusions.hidesNotifications`.** The process is excluded by application —
so a banner drawn after the filter is built is out too — and what comes back is only the half
that was not asked to be hidden (`DesktopWidgetWindow.comesBack`). The person still sees and
hears every banner; only the video leaves it out, which is better than Do Not Disturb for a
demo, because nothing about the Mac changes.

**Off by default**, like the Dock, the menu bar and the widgets, for the reason written on each:
a recording that silently omits part of the screen is not what pressing Record means. That is
the owner's to change.

**Not measured: that a real banner is absent from a real take.** That needs a notification
posted during a capture, which puts a banner on the owner's screen; asked for rather than done.
D6b.

**Found on the way:** `everyFieldSurvivesTheRoundTrip` built its value with `hidesDesktopWidgets`
at its default, `false`, so a decoder that forgot that field would have passed it. Every switch is
now on in that test, and it asserts so.

## 4. Knowing the speakers by their identifier, not their name

**The idea came from a utility suite, which recognises headphones by matching the device's NAME
against "headphone", "AirPods", "Beats" and a list of brands.** On this machine the names are
localised — the speakers are "MacBook Pro的揚聲器" — so a name rule is a rule that works in the
language it was written in.

**The device UID is not localised.** Measured, passively, every device on this machine:

    bltn  BuiltInMicrophoneDevice      MacBook Pro的麥克風
    bltn  BuiltInSpeakerDevice         MacBook Pro的揚聲器
    virt  MSLoopbackDriverDevice_UID   Microsoft Teams Audio

**Decision: the default output is the built-in speakers when its UID is `BuiltInSpeakerDevice`**,
and otherwise by the rule `2026-09-28-notch-audio-warnings.md` measured (transport `bltn` and
data source `ispk`). On Apple Silicon the headphone jack is its own device, so plugging headphones
in moves the default output to a device with a different UID, and the hint goes away without a
brand list. **What that device's UID is was not measured** — nothing was plugged in — so nothing
here names it: the rule is "is it the speakers", never "is it headphones".

A virtual device in front of the speakers (Teams' loopback, an aggregate) reads as not-speakers,
and the hint is not shown. That is the direction to be wrong in, for row 32's reason.
