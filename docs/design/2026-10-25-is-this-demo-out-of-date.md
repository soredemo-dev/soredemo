# Is this demo out of date?

2026-10-25. Idea 1's read-only half from `2026-10-25-beyond-a-screen-recorder.md` ("What this asks
of the code", item 4): before anyone replays a recording, can the app say whether the interface
it shows still exists? Built on `2026-10-25-which-application-each-click-went-to.md`, which records
each click's application as a bundle identifier.

## What it can know, and what it cannot

A step is a click on a named element — a role and a title — in an application. The check asks
three questions per step, each answered from something measured, never guessed:

1. **Is the application still here?** Its bundle identifier, looked up through Launch Services
   (`NSWorkspace.urlForApplication(withBundleIdentifier:)`).
2. **Is it the same version?** The recording keeps the application's short version beside its
   identifier, read from its bundle at the click; the check reads the installed one. A different
   version is not a broken step — it is a reason to look.
3. **Can the element still be found?** Only when the application is running, through its
   accessibility tree, bounded in depth and time as the capture walk is: a control with the same
   role and title. **Not found is not "gone"**: the element may live in a window or a menu that is
   not open. So the answer has three values — found, not found in what is open, and not asked
   (the application is not running) — and the third is never shown as a failure.

## What it says

A list of the steps, each with a state and its reason in words: "Keynote 14.2 when recorded, 14.4
now", "no button titled Export in Keynote's open windows". **Advice, not a verdict**: automation
proposes, the person decides — nothing is re-recorded or edited because of it.

## Decisions

- Read-only. It never presses anything; pressing is the replay half, later.
- The check is a pure function over (steps, what the system answered) with the lookups behind a
  protocol, so every state is a test with a fake system.
- Version: `ApplicationIdentifier` gains a sibling, the short version string, validated like the
  identifier (digits, letters, `.`, `-`, `_`, bounded), on the same decode path.

## How it is verified

The pure check against a fake system: installed or not, same version or not, element found, not
found, not asked — each state from its own input, and "not asked" never reported as a failure.
Looked at: the check run on a real recording in a running editor.
