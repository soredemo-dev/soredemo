# Splitting `Headless` — the boundary that already exists, enforced

*Phase 3A-4. The first item `docs/design/2026-08-14-phase-3a-carried-forward.md` names:
"the Headless tier's two halves have no enforced boundary."*

## The question

After 3A-3, `Sources/Headless` holds twenty files doing two unrelated jobs. Several headers
call one half "the capture tier" and the other "the render tier" — `CGGeometryBridge` says
it is "the capture tier's ENTRY", `HeadlessGeometryBridge` "the render tier's EXIT". The
redaction check's Gate 2 had to name a twelve-file exclusion list to say which half it
meant. All of that describes a distinction the build system does not have: nothing stops
`CoreImageFrameRenderer` importing `AXObserver`.

## The measurement that makes this cheap

**The two halves reference each other zero times.** Grepped both directions over every
capture symbol and every render symbol; the only two hits are in prose
(`MP4Exporter`'s header mentions `MasterWriting` to say it is unusable here,
`MonotonicStopwatch`'s cites `Minting.swift` as a precedent). No code reference exists in
either direction.

So the boundary is not something to introduce. It is something that is already true and
that nothing checks — which is exactly the shape this project has been burned by twice
this phase: the strict-memory-safety gate that answered differently on identical input, and
Gate 2's directory-as-proxy-for-tier.

## The decision

**Two sibling targets, not one target plus a rule.**

| | Enforced by | Drift possible? |
| --- | --- | --- |
| One target + a plugin rule or text scan | a scan someone maintains | yes — and this phase found four scans that had gone vacuously green |
| **Two targets** | the compiler; an import that does not exist cannot be written | no |

The 3A-1 design already argued this preference: *"An allow-list of frameworks is a
mechanism, not an invariant: define the boundary that way and it has no principle, only a
table that grows one row at a time."* A target is a principle.

### Names, and what each states

`Headless` stated an exclusion — *needs a window or a running app, does not belong here* —
and both new targets keep it: both carry the `HeadlessCheck` plugin, so `import AppKit` and
`import SwiftUI` still fail the build in each.

| Target | Invariant it states | Files |
| --- | --- | --- |
| **`Capture`** | **Reads the world.** ScreenCaptureKit, event taps, accessibility, the microphone, the clock. Produces evidence and never consumes it | `AXObserver`, `AudioInterleave`, `CGGeometryBridge`, `CaptureError`, `CapturePermissions`, `CaptureSession`, `CaptureSource`, `InputObserver`, `MasterWriter`, `Minting`, `ObservationWriter`, `SuccessorMasterWriter` |
| **`Compositing`** | **Turns a plan into pixels.** GPU, Core Image, AVFoundation. Reads evidence off disk and never captures any | `CompositionBuilder`, `CoreImageFrameRenderer`, `CursorArt`, `FrameRenderer`, `HeadlessGeometryBridge`, `MonotonicStopwatch`, `MP4Exporter`, `StageCompositor` |

**Not `Render`** for the second: `Sources/Render` already exists and is the DETERMINISTIC
planning tier (`PointerTrack`, `RenderPlan`, `StagePlanner` — no GPU, no clock). Reusing the
word for the tier that actually touches a GPU would collapse the distinction the two tiers
exist to draw. `Compositing` names what the code does that `Render` cannot.

### Dependencies

    Capture       → Geometry, Timeline, Graph, Project
    Compositing   → Geometry, Timeline, Project, Render

`Graph` is Capture's alone (`Minting.digest` returns `ContentDigest`). `Render` is
Compositing's alone. **Neither depends on the other, and neither may**: that is the whole
point, and after this change it is a fact about the package manifest rather than a sentence
in a header.

## What rides along

**The ambient-value permits get simpler and stricter.** Today one target carries a two-file
permit set (`Minting.swift`, `MonotonicStopwatch.swift`). After the split each target has
exactly one boundary file — `Minting` in Capture, `MonotonicStopwatch` in Compositing — so
each scan is a single-permit claim again, and a clock read in Capture can no longer be
excused by Compositing's permit or the reverse.

**Gate 2's exclusion list disappears.** It exists only to say "the render half of
`Headless`". With two targets the gate scans `Sources/Compositing` and `Sources/Render` and
the twelve-entry list, plus the `#require`-every-entry-exists machinery guarding it, is
deleted. A list that stops being needed is better than a list kept correct.

**The public surface gets re-examined, which is carried-forward item 1.** Every type went
`public` during 3A-3 because a caller in the app target needed it. The split forces the
question per symbol: a type used only inside its own half can be `internal` again. Do this
in the same pass — it is cheap now and gets more expensive per caller.

## Test targets

`HeadlessTests` becomes `CaptureTests` and `CompositingTests`, each depending on its own
target only — so a test cannot quietly reach across the boundary the product code is now
forbidden to cross. Two package tests move with them:

- `everyPublicTypeInHeadlessIsNamedByATestThatLinksTheProduct` becomes one check per
  target, over the matching test directory.
- `noDeterministicTestTargetDependsOnHeadless` names two targets instead of one.

The observation-log fixture is a Compositing resource: `RecordedPointerPositionTests` reads
it to drive `StageCompositor`. Capture writes logs and does not read them.

## Order

1. Manifest: two targets, two test targets, dependencies as above. Files move in the same
   commit — a manifest naming directories that do not exist does not build.
2. Scans and gates follow: ambient permits, Gate 2, the entry rule, the deterministic-target
   check.
3. Narrow `public` → `internal` wherever the app target does not name the symbol, measured
   rather than guessed.

Each step ends green on all three gates, as every 3A-3 task did.
