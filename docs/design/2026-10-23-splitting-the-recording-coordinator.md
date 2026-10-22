# Splitting the recording coordinator

2026-10-23. `RecordingCoordinator` is 1345 lines and does six jobs: preferences, the camera, the
microphone, the take's lifecycle, the guards around a take (wake, sleep, disk, silence), and
opening files and screenshots. Every feature since September has added to it, and the audit
(`2026-10-22-audit-and-how-to-stand-out.md` § 6) names it as the file a contributor trips on.

## The rule the split follows

**One reason to change per type** (single responsibility), **dependencies passed in** (a
`UserDefaults`, a notification centre) so each part is testable without the app, and **views
keep binding to `@Observable` models** — MVVM as the rest of the app already does it. The
coordinator stays the one owner of the take and *composes* the parts; nothing it does today
moves to a view.

## Steps, each its own commit behind green gates

1. **`RecordingPreferences`** — the nine persisted recording switches and their keys, and the
   `CaptureExclusions` they make (built in two places today: the take and the picture). The keys
   are pinned by a test: renaming one would silently reset every user's setting to its default.
2. **`CameraController`** — choosing a camera, its permission, the self-view, quality and style.
3. **`TakeGuards`** — the wake lock, sleep pause, disk watch and silence watch, engaged for the
   life of a take and fed by its clock.
4. **Opening and pictures** — last, because they share the most state with the coordinator.

## What step 4 turned out to be

Opening a project, opening a video and taking a picture mostly *set the coordinator's own
state* — the media it shows, the edit waiting to be applied, the status line. Moving that
elsewhere would hand another type a reference back into the coordinator, which is more coupling,
not less. The part that was not the coordinator's job was **finding the camera's file in a
package**: a convention about the package format, now `ProjectStore.open`'s, beside the
recording's own lookup.

And moving it found a hole. The camera file was found by name and checked only for existing, so
a shared package whose `camera-00.mov` was a symbolic link opened the file it pointed at — the
hole closed for the recording on 2026-10-22, still open one file over. It now goes through
`ProjectPackageIO.mediaFile(named:in:)`, which refuses a link; a project with a linked camera
opens without one.

**Where it ends:** the coordinator went from 1345 lines to about 1000, and what is left is the
take's own lifecycle — choosing a source, starting, pausing, stopping, a phone's take — which is
the one job it should have.

Behaviour does not change in any step. The gates are the evidence, plus a test per extracted
type for what it now owns.
