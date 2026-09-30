# Before and during a take: staying awake, notifications, headphones

2026-09-30. Items 1, 2 and 4 of the list the owner approved after reading `a utility suite`
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
