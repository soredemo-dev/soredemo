# Phase 3A carried forward

*What later phases need from 3A-2 and 3A-3. Written at the end of the phase, per AGENTS.md;
`git log` and the design documents beside this one are the rest of the record.*

## 1. Code with no caller yet, each with its intended first caller

| Symbol | State | Intended first caller |
| --- | --- | --- |
| `SuccessorMasterWriter` | Compiles, never constructed on this machine — its initialiser needs `AVAssetWriter.inputReceiver(for:)`, macOS 27, above the 26.0 floor | Whoever raises the floor. `bothWritersSatisfyTheSameProtocol` names the type and says plainly that naming is all it does |
| `CaptureSource.filter()`, `.destinationRect(scale:)`, `.geometry(scale:displayUUID:)`, `init(pickerFilter:availableDisplays:)` | Called in the product; **unreachable from `swift test`** — every parameter is a type only ScreenCaptureKit hands out | Unchanged. The probe and a person remain the only instruments |
| `CapturePermissions.blockingFailures()` | No caller (D6a-V row, count 0) | A first-run gate in `review-ui` |
| `Degradation.noMicrophoneTrack` | No producer — `degradation(for: .microphone)` returns `.blocksRecording`, measured | Nothing. It is the case the measurement refuted; kept so the enum can express what was rejected |
| `MonotonicStopwatch` | One caller (`MP4Exporter`) | — |

## 2. Rules held by convention rather than enforcement

> **DISCHARGED by Phase 3A-4 (2026-08-14), the day after this was written.** `Headless` is
> two targets — `Capture` and `Compositing` — that neither depend on each other nor may;
> `theTwoRunnableTargetsDoNotDependOnEachOther` asserts it against the resolved manifest in
> both directions, with a seeded-edge credential each way. `captureTierFilesInHeadless` is
> deleted: with two targets, Gate 2 names the one it means. Design:
> `docs/design/2026-08-14-splitting-headless.md`. The paragraph below is left standing as
> the reason the split happened.

**The Headless tier's two halves have no enforced boundary.** `Sources/Headless` now holds
a capture tier and a render tier in one target. Nothing stops `CoreImageFrameRenderer`
importing `AXObserver`. The only mechanism pointing at the split is
`captureTierFilesInHeadless` in `Tests/AppSourceTests/FixtureRedactionTests.swift`, and it
exists to scope one gate, not to enforce a dependency direction. If the two halves are
meant to stay apart, that is a rule someone has to write; if they are not, the render/
capture language in several headers is describing a distinction the code does not have.

**`@safe` on `CaptureSession` is an assertion, not a check.** It says the
`Unmanaged<CaptureSession>` token is encapsulated — registered in `start()`, unregistered
in `stop()`/`deinit`, never handed out. Nothing verifies that. A future method returning
the token would silently make the annotation false.

**The `unsafe` marks are load-bearing prose in bulk.** 260 sites were marked across
`InputObserver`, `AXObserver` and `CaptureSession`, with ONE argument at each type's state
declaration covering all of them ("every access is inside `lock.withLock`"). That argument
is true today and is checked by nobody. A new access outside the lock would compile, and
the mark at its site would look exactly like the 260 correct ones.

**Two `@preconcurrency` imports now carry `@unsafe`** (`CaptureSource`,
`CapturePermissions`, `CaptureSession`). The mark names the suppression; it does not
remove it.

## 3. Defaults this phase depended on and never decided

**Public visibility was granted by need, not by design.** *(DISCHARGED by Phase 3A-4 Task
3.)* Every type that moved became `public` because a caller in the app target needed it,
one build error at a time. The narrowing could not use "the app names it" as its criterion
— `ExportReport` is `MP4Exporter.export`'s result and is exported without any app file
writing the word — so every top-level type the app does not name was narrowed and the
compiler was allowed to refuse. **23 candidates, 6 refused**, each because it appears in a
public member's signature: `FrameRendering`, `ExportReport`, `CapturePermission`,
`PermissionStatus`, `Degradation`, `PermissionObservation`. The reason is recorded at each
declaration. The remaining 17 are `internal`.

**The `Diagnostics` types gained `public init()`** so the app tier could construct one to
diff against. That is a real API decision made to fix a build error.

**`swift test` runs against whatever this machine's TCC state is.** `CapturePermissions`
tests assert only properties that hold whatever the grants are, and
`aDerivedSourcesGeometryIsStableAcrossTwoReads` returns early when no display exists.
Nobody has decided what these should do on a headless CI runner, because there is no CI.

## 4. The next merge point

`main` carries ten commits since `9d8ad7e`, each green on all three gates. The next merge
point is **the end of 3B's first task**, whatever 3B turns out to be — not "when Phase 3
finishes". Phase 1 stopped for eight tasks because a mid-task "not yet" was never given a
condition for becoming "now".

---

## What the extraction actually bought

Measured, not estimated: `Sources/Headless` is 20 files and 5,013 lines; the app target is
6 files and 699. Before 3A-3 the app target held `Soredemo/Capture/` — eleven files that
`swift test` could not link, guarded by text scans, a hand-run probe, and a person.

`scripts/count-tests.sh` reports the current total; the phase added tests for `Minting`,
the two geometry bridges' capture half, `ObservationWriter`'s real file I/O,
`AudioInterleave`, both master writers, the permissions tables, the keyboard filter, the
AX walk over a fake element source, and `SegmentLedger`.

**Four times, a new test went red and the code was right.** Media is named `master-NN.mov`
and the test said `segment-NN`; a point at y=900 on a display that is 1000×500 POINTS;
a picker initialiser that takes no `availableDisplays`; and the double-counted scan above.
Each is recorded at its own site. That ratio — four author errors, zero product defects
found — is the honest summary of what these tests are worth today: they are a floor under
future changes, not a discovery of past ones.

**One test was deleted and one gate was rescoped, both because the code moved under them.**
`microphoneDegradationMatchesTheMeasuredConsequence` grepped for a switch arm's literal
text; a real test now calls the function. Gate 2 of the redaction check scanned
"`Sources/Headless`" and called it the render path, which stopped being true when a
producer moved in — it now uses an exclusion list, chosen because a new capture file going
red is louder than a new render file going unscanned.

**Four scans passed vacuously for one commit.** The keystroke ban and
`noAppSourceReadsUserContent` among them: their subject left the tree they scan while
their assertion stayed satisfiable. They were found by reading, not by failing. Any future
move must check the green scans as well as the red ones.
