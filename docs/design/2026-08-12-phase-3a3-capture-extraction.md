# Phase 3A-3 — Capture moves into `Headless`

**Status:** design, 2026-08-12.
**Scope:** move `Soredemo/Capture/` — eleven files, 4,099 lines with comments — and
`Soredemo/Support/Minting.swift` into `Sources/Headless`. The number in the 3A-1 design
("2,293 lines") was non-comment lines at 2026-08-04; the code has since grown and the
figure here is `wc -l` today, stated so the two do not read as a contradiction.

Same why as 3A-1, next tranche: `swift test` cannot link an executable target, so every
line under `Soredemo/Capture/` is guarded today by text scans, a hand-run probe and a
person. `1a98402` is the standing exhibit for what that arrangement misses.

## What moves, and what does not

**Moves** (no file imports AppKit or SwiftUI — verified by grep, and `HeadlessCheck`
enforces the ban from the moment they join the target): `CaptureError`,
`CGGeometryBridge`, `ObservationWriter`, `AudioInterleave`, `MasterWriter`,
`SuccessorMasterWriter`, `CaptureSource`, `CapturePermissions`, `InputObserver`,
`AXObserver`, `CaptureSession` — and `Minting`, which is not optional: Capture calls
`Minting.hostNow()` at 19 sites plus `epochAnchor()`, `displayIdentity(of:)` and
`newIdentifier()`, so Capture cannot move without it.

**Does not move:** `RecordingCoordinator` and the SwiftUI surface (`ContentView`,
`SoredemoApp`, `ProjectDocument`) — they are the app tier by the name's own rule.
`MediaSink` is declared in `CaptureSession.swift` and moves with it; `ProjectDocument`
keeps its conformance app-side, which is the seam working as designed.

`HeadlessCheck` needs no change: it is a ban-list (AppKit, SwiftUI, Cocoa, Quartz), and
ScreenCaptureKit, ApplicationServices, Carbon and IOKit are exactly the "real
frameworks, no window" the Headless tier exists to admit. Runtime permission gates
(Screen Recording, Input Monitoring, AX trust) make some paths untestable in fact on an
unprovisioned machine — that changes which tests can assert what, not where the code
belongs; the tier's invariant is *runnable*, not *provisioned*.

## The scans follow the code, and two get stronger

The text scans in `Tests/AppSourceTests` enforce rules over `Soredemo/` by path. A move
that outruns its scans would silently shrink every rule's scope, so each affected scan
moves in the same task as its subject:

1. **Ambient values, app side** (`…EnterOnlyThroughMinting`): with `Minting` gone from
   the app target, the permitted file would not exist and the `#require` would fail
   loudly — the safe direction, and also the opportunity. The scan becomes
   **zero-permit** (`violationsEverywhere`): *no app source reads an ambient value at
   all*; the app asks `Headless` for minted values. That is a strictly stronger claim
   than today's. `ContentView` and `ProjectDocument`, today's only app-side `Minting`
   callers, keep calling it through `import Headless` — the scan bans the ambient
   NAMES (`Date(`, `UUID(`, …), not the word `Minting`.

2. **Ambient values, Headless side** (`…EnterHeadlessOnlyThroughMonotonicStopwatch`):
   the permit becomes a two-file set — `Minting.swift` and `MonotonicStopwatch.swift`,
   each a file whose every member reads the environment, so each whole-file permit
   still costs nothing. `violations(banned:permittedPath:in:)` grows a set-of-paths
   overload with the same one-`#require`-per-path discipline. Folding the stopwatch
   into `Minting` was considered and rejected: `Minting`'s header claim is "pure
   ambient→package mappings", and a stateful stopwatch is not that.

3. **CG geometry bridge** (`coreGraphicsGeometryTypesAppearOnlyInTheBridge`): the
   bridge file moves, so a same-shape scan over `headlessSourceFiles()` takes over
   with the moved path, and the app-side scan drops to zero-permit (no app file may
   name the four CG geometry types at all once the bridge is out).

4. **Keystroke ban and `noAppSourceReadsUserContent`**: today they cover `Soredemo/`
   only, which was the whole surface that touched input. `InputObserver` moving means
   the surface these bans exist for leaves their scope — both scans extend to
   `headlessSourceFiles()` in the same task as that move, with the same
   permitted-file discipline the keyboard filter already requires (`InputObserver`
   is the one legitimate holder of the key-event APIs it filters).

## Strict memory safety pays as it goes

Every moved file joins the target's `strict` settings the moment it moves. `CGEvent`
taps, AX walks and audio-buffer interleaving will surface unmarked unsafe sites the app
target never measured. The repaired gate reports them in sites per task; each site gets
`unsafe` plus a why-safe comment in the task that moves it, never batched to the end —
a task that leaves the gate red is not done. The gate's clean-per-run design (23 s)
makes this affordable per task.

## Task order

Dependency-ordered, each task ending green (build, suite, strict gate, app builds
under `xcodebuild`):

1. `Minting` moves; ambient scans redesigned (app zero-permit, Headless two-permit).
2. Leaf files: `CaptureError`, `CGGeometryBridge` (+ bridge scan follows),
   `ObservationWriter`, `AudioInterleave`.
3. Master writers: `MasterWriter`, `SuccessorMasterWriter`.
4. `CaptureSource`, `CapturePermissions`.
5. `InputObserver`, `AXObserver` (+ keystroke and user-content bans extend).
6. `CaptureSession`; app callers switch to `import Headless`; `Soredemo/Capture/`
   deleted empty.
7. Close-out: ROADMAP and ARCHITECTURE records, carried-forward notes, and the first
   `swift test` tests that could not exist before — at minimum `ObservationWriter`
   and `CaptureSource` construction paths that the probe alone reaches today.

The walking-skeleton lesson from 3A-1 applies: the move is the deliverable, the new
tests are the proof it bought something, and neither is allowed to absorb the other's
task.
