# Roadmap

*The only ordered work list. Take the first unblocked row.*

Legend: ☐ not started · ◐ in progress · ☑ complete · ⛔ blocked

## The completion rule

> A row is not complete while the behaviour its name claims is not observable in the product. A pure
> function with no caller does not satisfy a row that claims a product behaviour. If the caller belongs
> to a different row, rename the row to what it actually delivers.

---

## Phase 0 — Validate the hypothesis

**Disposable. Not product code. Two weeks, hard stop.**

The riskiest claim in this plan is not technical: *if you remove the friction, will teams actually
record a demo per release?* Everything else assumes it, and nothing has tested it. Two weeks now beats
finding out in month nine.

| State | Row | Outcome |
| --- | --- | --- |
| ☐ | `spike-poller` | Poll a GitHub repo, detect user-visible releases. Throwaway, any language |
| ☐ | `spike-proposal` | The simplest possible "v0.4.0 shipped 3 changes. Record a demo?" surface — menu-bar item, Slack message, email. Whatever is fastest |
| ☐ | `spike-manual-pack` | Record and edit demos **by hand** for 5–10 real releases from repos that are not yours. Learn what the output must look like and how long it genuinely takes |
| ☐ | `spike-prepare` | Stage a post by hand: right aspect, text on the clipboard, composer opened |
| ☐ | `spike-findings` | `docs/findings/validation.md` — did anyone record, what stopped them, what is the real baseline coverage |

**What would change the plan.** If teams see the proposal and still do not record, friction was never
the binding constraint and the positioning needs rework. If they record but the demo is not what they
would post, output quality matters more than the loop.

**Delete the poller afterwards.** The temptation to keep and grow it is this phase's failure mode.

---

## Phase 1 — Foundation

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ☑ | `repo-skeleton` | SwiftPM package at the repository root + hand-made Xcode app target, `.macOS(.v26)`, Swift 6 language mode, builds and **launches** empty | — |
| ☑ | `architecture-plugin` | `Plugins/ArchitectureCheck`. Rules 1 (imports, **done and capped**), 2 (CG types) and 4 (manifest dependencies) enforced under both `swift build` and `xcodebuild` — each observed failing under both at Task 19. Rule 3 (determinism) **done** — link-time symbols read by `Tests/DeterminismTests`, not by the plugin, because a build-tool plugin's command runs before its target compiles. Rule 5 (CG bridge) **done** (Task 5) — `Tests/AppSourceTests`, a package test rather than a plugin rule because the plugin cannot see the Xcode app target. It shares the real lexer instead of copying it: `codeViewLines(of:)` moved out of the `architecture-checker` **executable** target, which a test target cannot import, into the `CheckerLexer` library, so the allow-list cannot drift from the enforcement it mirrors. A second app-side list rides the same mechanism — ambient time, randomness and hashing confined to `Soredemo/Support/Minting.swift`, which rule 3's link-time scan cannot reach because that file is in the app target. **☑ on this evidence and no more:** all five active rules were observed red on their own negative case, individually, at Task 19 — rules 1, 2 and 4 under `swift build` (exit 1) *and* `xcodebuild` (exit 65), rules 3 and 5 as failing tests. Three limits ride with the tick. **(a)** Rules 6 (one owner for the log→graph join) and 7 (`applyingProduced` is the sole writer of a `Derived`) are **inert** — the code they constrain does not exist yet. **(b)** Rules 3 and 5 fail `swift test`, not the build; an `xcodebuild` of the app does not run them, because the Xcode project has no test target. **(c)** `CheckerLexer` is outside rules 1 and 3: it cannot carry `plugins: archCheck` without closing a dependency cycle, and `DeterminismTests` derives its module list from plugin-attached targets, so one exclusion causes the other. Its own compliance is **held by review**. A *seventh* target added without the plugin does fail a test; what is unguarded is the exemption list itself — see the design doc's rule 3 gap table. **Rule 8** (a validating initialiser under a synthesised `Decodable`) added at Task 11.5, enforced by the plugin under both builds, observed red on nine real types and on a tenth added for the purpose. Two things ride forward with it. **(d)** Rule 8 resolves conformance and extensions across a whole TARGET but not across targets, so a `Project` type conforming to a `Graph` protocol is unresolved — D6a carries the row. **(e)** **Re-decide D2-17's pinned symbol baseline at the end of Phase 3**, when the package's symbol surface stops moving. Task 11.5 measured the cost as +10% over eleven commits on the union basis (575 → 633) after first reporting +130% by comparing a union against a per-module sum — so whoever re-runs it must state the basis, and must know a link-time baseline cannot reach the app-side half of rule 3 at any size | `repo-skeleton` |
| ☑ | `geometry-types` | `NormalizedPoint` (0–1, bottom-left), `NormalizedFrame` with `geometryRevision`; `PointRect`/`PixelRect` making the unit a compile error; cross-revision comparison is a precondition failure. **Renamed from `geometry`:** "all conversion in one place" moved to the rows whose code actually converts — **Was:** `NormalizationContext` had zero callers, and per the completion rule a pure function with no caller does not satisfy a row claiming a product behaviour. **Now, since Task 5.5 of Phase 2B (2026-08-04): it has one.** `CaptureSession` constructs `InputObserver` and `AXObserver` and routes their records into an `ObservationWriter`, which is the first time any of them has executed in the product. **Adjacent and not part of this row's three claims, but do not let it go unsaid:** `Soredemo/Capture/CGGeometryBridge.swift` — the one file allowed to name a CG geometry type, and the app's entire conversion boundary — had **zero callers in the app target**, exercised only by the hand-run `scripts/cross-boundary-digest-probe.swift`. **That also ended in Phase 2B**: its render half runs (`CursorArt`, `CoreImageFrameRenderer`, `CompositionBuilder`) and its capture half runs through `CaptureSession`. **Those last two closed on 2026-08-04, and by observation rather than by argument.** A four-second recording made by a person, through the shipping app under `dev.soredemo.mac`, wrote an observation log containing **327 pointer records, 4 button records, 2 AX chains and 1 key record** — so the AX and input conversion sites inside `InputObserver.swift` and `AXObserver.swift`, which run only when a real tap and a real AX walk deliver, have now run in the product. This row previously said they never had, and cited Input Monitoring being denied on this machine; that was true of the OLD bundle identifier. **The count is also what located `1a98402`**: 327 samples on disk against zero pointers on screen eliminated capture, permissions, the tap and the writer in one step. It is in exactly the position of the five symbols `project-format` names below: written, tested through a script, never compiled-and-run in the product. `input-observation` is the intended first caller of both it and `NormalizationContext` | `repo-skeleton` |
| ◐ | `project-format` | Versioned `Codable` document, atomic save, relative paths, upgrade path. Hand-written **`NSDocument`** package coordinator — `ReadableDocument`/`WritableDocument` are SwiftUI types requiring macOS 27, above our floor. The row spans the package/app boundary. Storage layer done (`Sources/Project`); coordinator done (`Soredemo/UI/ProjectDocument.swift`, Task 18) — a `.soredemo` package opens to a document window. The Info.plist wiring is **done** (`9ea17ac`): both configurations carry `INFOPLIST_FILE = Soredemo-Info.plist` and LaunchServices registers `com.soredemo.project`. **Still not ☑, and Task 11 moved it: three of the five now have callers, two do not.** `ProjectDocument.addMedia(_:named:)` is called by `CaptureSession` on every finalised segment (through `MediaSink`) and by name in `scripts/cross-boundary-digest-probe.swift` § 9.7; `.unreferencedMedia` and `.compactMedia` are called there too, on the same package, because the pair is what demonstrates the defect this routing fixed — a sidecar written around the document is unreferenced and the next compaction **deletes it**. Still uncalled: `Minting.now()` (nothing in the recording path needs a wall clock — `HostInstant` is the ordering key, and inventing a caller would be exactly the true-sounding sentence with nothing underneath it this row exists to refuse) and the `MediaError` enum, which is thrown inside `ProjectDocument` and caught nowhere. `addMedia(_:fileExtension:)`, the UUID-minting overload, also has no caller: capture mints its media name at `beginSegment`, before any bytes exist, because `SegmentLedger` records it when the segment opens. That is the completion rule exactly: code with no caller does not satisfy a row claiming a product behaviour. **Also not standing:** the SHA-256 vector across the package/app boundary is a **hand-run script** (`scripts/run-cross-boundary-probe.sh`, 14 checks) because the app has no test target — the package half is a standing test, the app half is not, and Phase 8's `approval-gate` rests on the app half | `geometry-types`, `derivation-graph` |
| ◐ | `derivation-graph` | Observations → actions → beats → outputs. Every derived value carries an origin (`generated`/`authored`) and a review state. **The producer-value rule with its boundary tests**. **Was ☐, which was stale:** `Sources/Graph` exists and carries 97 tests — `Evidence`, `EvidenceRef`, `Derived` with `Origin`/`ReviewState`, `Derivation` with `Outcome`/`GateCode`, `ContentDigest`, `ReverseIndex`, and `applyingProduced` as the sole writer, with the producer-value rule and a cache-hit/invalidation pair under test. **Not ☑:** the *pipeline* the row names does not exist. There are no actions, no beats and no outputs — `Sources/Framing` and `Sources/Variants` are one-line placeholder modules with one test each — and nothing in the app builds a graph: `ProjectSnapshot` carries `schemaVersion`, `geometries` and `mediaFilenames`, and no graph is persisted or read. Per the completion rule the types are delivered and the behaviour is not | `geometry-types` |

---

## Phase 2 — Record

Goal: a build that records and plays back. Nothing derived yet. **This phase alone is a shippable free recorder.**

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ◐ | `capture-source` | `SCShareableContent` enumeration; **`SCContentSharingPicker` for the picker — do not build a custom one first**. `Soredemo/Capture/CaptureSource.swift`: `.display(SCDisplay)` / `.window(SCWindow, bufferSize:)`, `.geometry(scale:displayUUID:)`, `.filter()`, `init(pickerFilter:availableDisplays:)` deriving a source from `filter.style` without ever hand-building a filter in the app (design doc D2-13). **`allowedPickerModes` restricted to `.singleWindow`/`.singleDisplay`** (`CaptureSourcePicker.present()`) so the picker cannot hand back a shape `CaptureSource` has no case for — the picker and the type agree by construction, not by an "unsupported shape" branch downstream. **Step 3 is settled, not measured** (D2-13a): `scalesToFit`/`preservesAspectRatio` are documented SDK flags with documented defaults, so a window's `bufferSize` is **display-sized** (the largest of the displays supplied to `init(pickerFilter:availableDisplays:)`), not sized to the window's own `contentRect` — sizing to the window meant growing it past that size got resampled, sizing to a display means that only happens if the window exceeds the whole display, so display-sized strictly dominates. One revision per segment; no `SegmentBoundary` case needed. `SCStreamFrameInfoContentRect`/`ScreenRect`/`ContentScale` carry the window's varying position within that fixed buffer **per frame** — `capture-stream`'s concern, not this row's. **Not ☑:** presenting the picker and a human choosing something has never happened — `CaptureSourcePicker` compiles (`xcodebuild`, both Debug configurations) and is otherwise unexercised, per the completion rule; a `--present-picker` entry point exists in `Soredemo/App/SoredemoApp.swift` for exactly this, awaiting a human run. **Verified, not assumed:** `.geometry()` never reads the wrapped `SCWindow`'s own frame — a real window dragged to a genuinely different screen position (not the `(0,0)`-identity fixture) yields the identical `GeometryRevision`; a `.window` source's `bufferSize` is genuinely display-sized, not window-sized (`3024x1964` vs the window's own `1000x784` on this machine); and reverting either property lands a probe check red, all measured via `scripts/cross-boundary-digest-probe.swift` against real `SCDisplay`/`SCWindow` instances obtained through `SCShareableContent.currentProcess`, which needs neither Screen Recording nor a picker. **Explicit limitation, not solved here:** a window-capture `GeometryRevision`'s source identity is minted once per picker selection and held only for that session — `SCWindow.windowID` does not survive the owning application restarting, and bundle identifier plus title is no better, so unlike a display revision (D-P2's "two sessions that shared a display agree without coordination"), two window-capture sessions of the same on-screen window do **not** currently agree without coordination. Load-bearing only for Phase 4's `selective-rerecord`, whose requirement has not been read | `repo-skeleton` |
| ☐ | `capture-stream` | `SCStream` + `SCStreamConfiguration`, `showsCursor = false`, `capturesAudio`. **`SCRecordingOutput` is not usable for the master** — measured (Phase 2 F2-4): at our floor it mixes the microphone into the system-audio track, one track carrying both tones, and `mixesAudioWithMicrophone` is macOS 27 only. So `AVAssetWriter`, taking `SCStreamOutputTypeScreen` / `Audio` / `Microphone` as three streams. **`SCFrameStatusIdle` is 42–84% of callbacks** and the observed rate was 9–37 fps against a requested 60, so a callback is not a frame and `minimumFrameInterval` is a floor. **Register `CGDisplayRegisterReconfigurationCallback`** (D2-10): reconfiguration closes the current segment and opens the next — the same mechanism pause already needs, since ScreenCaptureKit has no pause — and it is what mints a new `geometryRevision`. Known unknown, settled while implementing: whether the stream stops cleanly and reports, or degrades silently | `capture-source` |
| ☐ | `capture-permissions` | Screen Recording, Microphone, Input Monitoring, Accessibility — each degrading precisely | `capture-stream` |
| ☐ | `one-clock` | `CMClock.hostTimeClock` taken once; every timestamp derived from it. A sample before the origin or moving backwards is an error | `capture-stream` |
| ☐ | `audio-tracks` | System audio and microphone as independent tracks, retimed across pause | `capture-stream`, `one-clock` |
| ☑ | `input-observation` | **First caller of `NormalizationContext` — this row and `ax-observation` carry the "all conversion in one place" claim, moved from `geometry-types`.** **Also the first caller of `Soredemo/Capture/CGGeometryBridge.swift`**, which today has zero callers in the app target and is exercised only by a hand-run script — so this row is where both halves of the conversion boundary stop being pure functions nobody calls. `CGEvent.tapCreate` pointer and click stream, listen-only. **Keyboard filtered to approved shortcuts; secure input suppresses capture entirely**. **Only now observable in the product — Phase 2B Task 5.5 was the first thing to construct `InputObserver` in `CaptureSession` at all (`f830856`/`469e18c`); before that, this row's code ran only under a hand-run probe.** Evidence is a REAL recording made through the real app (Task 5.5's "row-14" evidence, `~/soredemo-evidence/row14/…/observations/segment-00.jsonl`, read firsthand): `pointer: 251`, `button: 6` — real `CGEvent.tapCreate` samples, not a harness. **Two of this row's own sub-claims are unexercised in that recording, disclosed rather than hidden**: `key: 0` (nobody typed one of the thirteen approved shortcuts during that run — the filter had nothing to filter) and zero `secureInput` records (secure input was never entered) — both are unit/probe-tested against synthetic fixtures at the package level, just not yet seen firing on a real keystroke or a real password field. Same disclosure shape `geometry-types` already uses above for its own still-unexecuted half | `one-clock` |
| ☑ | `ax-observation` | `AXUIElementCopyElementAtPosition` for the control under each click, with role, frame, and a preference for well-bounded descendants. **Same Task 5.5 wiring, same real recording.** `axChain: 3` — three real clicks hit-tested against the live Accessibility tree by `AXObserver` running inside `CaptureSession`, not a harness. **One disclosed nuance, not resolved here**: the log's own header names `accessibilityUnavailable` in its blindness, which `AXObserver`'s live source returns under that state per its own doc comment — the three real chains most likely landed after a second, separate Accessibility grant arrived mid-session (Task 5.5's report flags this and explicitly declines to re-derive the grant's wall-clock timestamp, since that TCC-log reconciliation was the coordinator's to make, not the implementer's) | `input-observation` |
| ☑ | `observation-log` | Versioned on-disk log joining video, audio, pointer, click, key, and AX records on the one clock. Format at its own `ObservationLog.schemaVersion` (**2** — bumped in review when two incompatible layouts were found both stamping themselves 1; it does not move with `ProjectSnapshot.currentSchemaVersion`, and the two are now different numbers, which is what having two is for). `ObservationLogHeader`/`ObservationLogTrailer` bracket one append-only JSONL file per segment under `observations/`; the log carries its own `BootEpoch` and `ObservationWriter.append` refuses a record from another boot session, checking **every** interval a record holds rather than its primary instant; the trailer carries one `GapWatch` per `ARCHITECTURE.md` D6a site and refuses to decode if one is missing; `ObservationLog`'s own documentation states what a record may and may not contain, enforced by `AppSourceTests.noAppSourceReadsUserContent`. **Was ◐, blocked on a premise Task 5.5 found wrong**: this row assumed wiring the live writer was `app-shell`'s job, waiting on a shell that did not exist yet. `CaptureSession` does it directly (`beginSegment`/`ObservationWriter`, Task 5.5) — no app shell needed. The end-to-end claim rests on a human step, and it HAS been run: the row-14 recording is a real segment log, header through trailer, produced by the real app (`logHeader: 1`, `logTrailer: 1`, `pointer: 251`, `axChain: 3`, `button: 6`, `tapDisabled: 149` — and the trailer's own `tapDisabled` `GapWatch` — `{"gapsFound":149,"looks":197,"lost":14950480542,…}` — reconciles exactly against an independent TCC-log cross-reference, 149 windows and 14.9505s both matching with no remainder) | `audio-tracks`, `ax-observation` |
| ◐ | `render-core` | `AVVideoCompositing` custom compositor over Core Image + Metal. Background, card, shadow, corner radius. **Background, card and corner radius are real and product-observable, not ☑.** `StageCompositor` (Phase 2B Tasks 1, 3) is the actual `customVideoCompositorClass` both `StageWindow.load()` (preview) and `MP4Exporter.export()` (export) hand to a real `AVVideoComposition` — proven by `scripts/cross-boundary-digest-probe.swift` §§ 10, 11, 14, 15 reading real composited pixels back, and by Task 4's human checklist (5/5 pass: card inset, rounded corners, correct background colour, correct aspect). **The shadow is drawn since 2026-08-19** (recorder-parity decision): `CoreImageFrameRenderer.shadowImage` blurs the card's silhouette at `shadowOpacity`, pixel-pinned in both directions by `theShadowDarkensTheBackgroundJustOutsideTheCard` / `aZeroOpacityShadowChangesNothing` — this row previously recorded it as one of two absent nouns, grepped and confirmed. Metal is deliberately not built: Task 3's `FrameRendering` seam exists precisely so the Core-Image-vs-Metal choice stays open (design doc "open item 3"), and only Core Image is implemented | `repo-skeleton` |
| ◐ | `cursor-render` | Cursor drawn at composite time, spring-smoothed, with click ripples and shortcut badges. **The drawing mechanism is real and pixel-proven, not the row's literal claim.** `StageCompositor.pointerPlacement`/`CoreImageFrameRenderer.cursorImage` (Task 5) draw a pointer and a click ripple from a real `PointerTrack`/`ClickTrack`; probe § 12.1 proves all four `PointerReading` cases change the rendered pixel correctly, off a THREE-RECORD FIXTURE the section writes itself through the real `ObservationWriter` — not off any recording. **This sentence previously claimed the section ran against "Task 5.5's row-14 REAL recording (251 real pointer samples…)"; it never did** — `grep -rn 'row14\|row-14' scripts/ Tests/` returns nothing, and the 251 was a number recalled, not counted. Rows 62, 64 and 67 cite that recording correctly, which is exactly why this one was believable. The honesty register is the last place a citation should go unchecked, and the whole-branch review caught it hours after a fixture that lied about its own clock (`1a98402`) — the same failure in prose. **Two of the row's own claims are not built.** "Spring-smoothed" was a considered REJECTION: `PointerTrack.position(at:)`'s own doc comment — "No interpolation and no hold-last-known across a gap: both produce footage that looks fine, and looking fine is what deletes the signal saying someone should look" — the same argument D6a's new substitution row (Task 8) makes about shape. "Shortcut badges" has no implementation anywhere in `Soredemo/Render` — grepped, absent. **The human step has now been run** (2026-08-04): a person recorded four seconds, watched the drawn cursor move in `StageWindow`'s live preview, and it tracked. It did not track before that watching. The step found that `pointerPlacement` queried an absolute-host-clock track with a composition time, so `.noObservationYet` came back for every frame of every recording and NO BUILD OF THIS APP HAD EVER DRAWN A POINTER — through 450 tests, 350 probe checks and three rounds of review, because probe § 12's fixture stamped its samples in the same wrong frame of reference as the code (commit `1a98402`). **That defect now has an automated instrument, and it is not another one of the same provenance** — Phase 3A-1 Task 6's `Tests/HeadlessTests/RecordedPointerPositionTests.swift` (`aPointerIsDrawnAtAll`, `aPointerIsDrawnAtTheRecordedPosition`) runs under `swift test`, feeds the REAL row-14 recording's observation log (redacted by schema; 411 lines, 251 pointer samples, 149 tap-disabled windows, every timestamp and coordinate byte-for-byte as recorded) into `StageCompositor.pointerPlacement(at:in:)`, composes the result through the production `CoreImageFrameRenderer`, and asserts two things in sequence: the drawn pointer's TIP against the placement the compositor returned, and that PLACEMENT against the position re-read from the fixture's own bytes. Three mutations calibrate it, each observed red: reverting `let time = anchor.hostTime + offset` to `let time = offset` reddens both tests at the search; deleting `CoreImageFrameRenderer.render`'s `if let pointer = plan.pointer { … }` block reddens `aPointerIsDrawnAtAll` at its own pixel-difference expectation; a 40 px offset in the renderer's translation leaves that test green and reddens `aPointerIsDrawnAtTheRecordedPosition` alone. The composition times are SEARCHED for, not hardcoded: 504 of the recording's first 600 frames fall inside a tap-disabled window, so a fixed index would have measured `.blind` five times out of six — and the search additionally requires at least four samples behind an instant and one ahead, because at the recording's FIRST drawn frame only one sample is a candidate and every selection rule agrees there. **What it still does not reach**: `startRequest(_:)`'s AVFoundation glue and `renderContextChanged(_:)` (both take types only AVFoundation constructs), and `StageCompositor.style`, which is read only inside `startRequest` — all covered only by the cross-boundary probe and by a person. **Stays partial** on the two unbuilt claims above and on a third the watching exposed: the drawn pointer is always `CursorArt`'s one arrow, because `PointerSample` records position and no cursor shape — an I-beam or a resize arrow in the real session is drawn as an arrow. Phase 3 | `render-core`, `observation-log` |
| ◐ | `export-basic` | `AVAssetWriter` + VideoToolbox: MP4 H.264/HEVC, MOV ProRes, GIF via `CGImageDestination`. **One MP4/H.264 export is real, frame-accounted and container-verified by machine.** Task 7's `MP4Exporter`; probe § 14 asserts `framesRead == framesWritten` AND independently recounts the finished file's own samples, confirms the `ftyp` major brand is NOT QuickTime's `"qt  "`; Task 8's probe § 15 confirms it draws through the SAME composition the preview does. **HEVC, MOV/ProRes and GIF are out of scope by explicit, disclosed design, not silently missing** — `MP4Exporter.swift`'s own header: "this task's own scope is 'one MP4 (H.264). Full stop.'" **The human step has now been run** (2026-08-04): Export pressed in the running app, the resulting file opened and played in QuickTime. That retires this row's unverified caveat — what keeps it partial is the disclosed scope above, nothing unmeasured. The same session's OTHER human step, watching the preview, is why this is worth insisting on: it found that `StageCompositor` had never once drawn a pointer (commit `1a98402`), through 450 tests and 350 probe checks. **I6 — `MP4Exporter`'s readiness poll (`while !writerInput.isReadyForMoreMediaData`) was uncapped — is closed, Phase 3A-1 Task 7, on the same move that carried this file from `Soredemo/Export/` into `Sources/Headless/`.** Bounded to a stated 5-second deadline (`MP4Exporter.readinessDeadlineSeconds`; chosen by argument, not by copying Spike D's own measurement — Spike D's subject is an INDEFINITE hang, with no duration to cite, so the bound is instead sized to sit far past any plausible legitimately-busy-writer delay, see the constant's own doc comment for the full argument), and exhausting it now throws a new `ExportError.writerNotReadyInTime(frame:elapsedSeconds:)` naming the frame index and the elapsed wait rather than spinning silently. `Tests/HeadlessTests/MP4ExporterTests.swift` exercises the real exporter against the real `two-tone.mov` fixture inside its own `withThrowingTaskGroup` wall-clock timeout (so a regression in the cap fails loudly rather than hanging `swift test`), and the timeout case's red was observed by hand once with the deadline forced to zero, then reverted — see `task-7-report.md` | `render-core` |
| ◐ | `app-shell` | SwiftUI `NavigationSplitView` + `Inspector`, **native Liquid Glass only**, `@Observable`. Record → play back → export. **Not `DocumentGroup`** — it hosts a SwiftUI `FileDocument`/`ReferenceFileDocument`, and `project-format`'s coordinator is an `NSDocument` (F3, F4); document windows come from `makeWindowControllers()` hosting SwiftUI, and opening goes through `NSDocumentController`. **Record → play back is real and human-verified**: `ContentView` transitioning to `StageWindow` in one window (Task 4's human checklist, 5/5 pass, macOS 26.5.2 build 25F84, commit `a060e87`) — a real recording, a real preview window, correct framing. **Export is wired but its own human leg is unrun** — the same outstanding step named on `export-basic` above. **`Inspector` was never built**: `StageWindow.swift`'s own header names the D7 pattern by name, but the view is a `NavigationSplitView` sidebar + detail only — no `.inspector()` modifier anywhere in the app, grepped and confirmed absent. `NavigationSplitView` (`StageWindow.swift`) and `@Observable` (`ContentView.swift`) are both real | `capture-stream`, `render-core`, `project-format` |
| ☑ | `preview-playback` | ~~`CADisplayLink`-driven preview.~~ **Corrected, not merely renamed**: `AVPlayer` + `AVPlayerItem.videoComposition` drives it — `ARCHITECTURE.md` D8 already reconciles this ("[not] a hand-driven `CADisplayLink` transport... it does not mandate hand-driving the clock, and it is satisfied here"). `Not CVDisplayLink` stays true — grepped repo-wide, neither API appears anywhere in `Soredemo/` or `Sources/`. **Human-verified**: Task 4's checklist, 5/5 pass, macOS 26.5.2 build 25F84, commit `a060e87` **with an uncommitted `ContentView` change in the tree, so the exact build observed is not reconstructible from any commit** (`progress.md`, Task 4) — a frame appears, the card is inset (not filling the frame), corners are visibly rounded, the margin outside the card is the dark background colour (not black, not the desktop showing through), and the recorded content's aspect ratio is preserved, not stretched | `render-core`, `app-shell` |
| ☑ | `render-parity` | Golden-image tests proving preview and export produce identical frames for the same input. **One compositor drives both** (Phase 2 D2-6), so this row tests that the wiring has not come apart rather than reconciling two renderers. Three specifications, without which it reports false failures: compare the **compositor's output buffer, before colour management** — preview goes through the display pipeline and export writes explicit Rec.709, so the same buffer legitimately looks different in each; name an **explicit set of composition times** — `SCStream` is variable frame rate (`minimumFrameInterval` is a floor, `SCFrameStatusIdle` exists for "the display did not change"), so preview on `CADisplayLink` and export on composition time sample at different instants by nature; and keep **preview-only chrome above the compositor** — selection handles and guides inside it are baked into the export silently. **Task 8, corrected at code review fix round 1.** `scripts/cross-boundary-digest-probe.swift` §§ 15–16. **The export leg is the real `MP4Exporter.export()`; the preview leg calls the real `StageWindow.configuredComposition(for:)`** — the SAME function `StageWindow.load()` calls, extracted from it at this fix round specifically so this row's earlier claim ("run against the real `StageWindow`... code, not copies") would stop being false: the first version reconstructed its own inline `CompositionBuilder.composition(...)` call at its own hardcoded `320×180`, never touching `StageWindow` at all, and a regression confined to that function (a wrong output size, a dropped `item.videoComposition`, a broken `observationLogURL` lookup) would have left it green. Now it reads `StageWindow.outputWidth`/`.outputHeight` (`1920×1080`) directly too, so the two cannot silently drift apart. `AVAssetImageGenerator` is still a stand-in for `AVPlayer`'s own frame delivery, not `AVPlayer` itself — stated in the check's own message, not only here. **States which of the two things a parity check can test, in the check's own message**: this tests that the wiring has not come apart (one `StageCompositor`, shared by both consumers, D8) — not that two renderers agree, because there is exactly one. **Pixel by pixel over the WHOLE frame, not two hand-picked points** (this row's own literal wording, unmet by the first version — code review Important findings 2/3): the first version sampled the card centre plus one point 2px inside the card's edge, and that single point was directionally blind — `insetFraction +0.01` reddened it (the card shrinks past it) but `-0.01` did not (the card grows away from it, and the point never crosses anything). Replaced with a genuine full-frame max-per-channel diff (`maxChannelDifference`), excluding a measured 12px band around the card's own rounded boundary (corners AND flat edges) where H.264 antialiases the identical geometry differently from Core Image even under MATCHING styles (measured up to 84 there with no mutation at all) — the exclusion width is stated in the check's own message alongside the ±6 tolerance, not hidden in a comment. **Observed failing in BOTH directions, not only one**: `StageStyle.default.insetFraction` diverged by **+0.01** in the export path only reddened both sample times (worst diffs 82, 79 against tolerance 6); reverted, then diverged by **−0.01** and reddened both again (worst diffs 82, 80) — the direction the first version's single edge-point check could not see. Reverted again, tree clean, re-verified green three consecutive runs (348 checks — down from 350: the per-time content/framing point-pair became one full-frame check plus the unchanged sanity check). **An explicit SET of composition times** (0.5s in the fixture's red half, 1.5s in its blue half — this row's own second specification), read off a committed fixture (`Tests/RenderParityFixtures/two-tone.mov`, ~6.5 KB, regenerable from the committed `Tests/RenderParityFixtures/generate-fixture.swift`), not a plan. **One disclosed deviation from this row's first specification, unchanged from before this fix round**: compares pixels read back through each consumer's real AVFoundation path (post colour-management), not the compositor's raw pre-colour-management buffer — deliberate, because it is what exercises the WIRING claim through the real `StageWindow`/`MP4Exporter` code, where a raw-buffer diff would only prove `CoreImageFrameRenderer.render()` is deterministic when called twice — a different, narrower claim. The third specification (preview-only chrome above the compositor) still has no check: nothing in the app draws preview-only chrome yet — `Sources/Framing`/`Sources/Variants` are one-line placeholders and Phase 4's `Editor/` does not exist — so a check against it would be vacuous by construction | `preview-playback`, `export-basic` |

---

## Phase 3 — Frame it automatically

**Phase 3's first item is structural, not diagnostic: extract app logic into a
`Headless` library target.**

*(Named `SoredemoCore` in this row's first draft, which was wrong: `SoredemoCore` is the
Foundation-only product — `ARCHITECTURE.md` rule 1, and the `architecture-plugin` completion criterion
is that `import AppKit` there fails the build. `Headless` states its own invariant instead:
**needs a window or a running app, does not belong here** — which excludes SwiftUI by the name
rather than by a rule beside it, and stays true when `Capture` moves in.)*

The app target has no automated executing instrument at all. `swift test`'s suite
does not link it — an `executableTarget` cannot be imported by a `testTarget`
— so `Tests/AppSourceTests` reads `Soredemo/` **as text**. (Run `scripts/count-tests.sh`
for the current count; it does not belong written into this document — see
`Tests/AppSourceTests/ProseClaimTests.swift`.) The only things that
execute app code are `scripts/run-cross-boundary-probe.sh` and a person running
the built `.app`. `1a98402` lived in app code for a whole phase and a person found
it, four seconds into a recording.

> **Retired for the render path — Phase 3A-1 Task 6 (`RecordedPointerPositionTests
> .swift`).** The paragraph above is still true of `Soredemo/` as a whole and of every
> row that has not moved yet, but it is no longer true of the code `1a98402` lived in.
> `CursorArt`, `HeadlessGeometryBridge`, `FrameRenderer`, `CoreImageFrameRenderer`,
> `StageCompositor` and `CompositionBuilder` are in the `Headless` library target;
> `HeadlessTests` links it and runs it.
>
> **What `aPointerIsDrawnAtAll` and `aPointerIsDrawnAtTheRecordedPosition` cover.**
> `swift test` now feeds `StageCompositor` the REAL recording's observation log
> (`Tests/HeadlessFixtures/segment-00-redacted.jsonl` — 411 lines, 251 pointer samples,
> 149 tap-disabled windows, redacted only in `AXElementRecord.title`), converts a
> `CMTime` composition time through `pointerPlacement(at:in:)`'s composition-time →
> host-clock conversion, composes the resulting placement through the production
> `CoreImageFrameRenderer`, and asserts against the DRAWN PIXELS: that a pointer was
> drawn at all, that its tip sits within 3 px of the placement, and that the placement
> itself matches the position re-read independently from the fixture's own bytes.
> The instants are searched for and required to carry at least four samples behind them
> and one ahead, so the sample-selection rule is under test rather than agreed with.
>
> **Calibrated by three observed mutations, each red on a different assertion.**
> `let time = anchor.hostTime + offset` → `let time = offset` (the `1a98402` defect)
> reddens both tests inside the search — nothing in the recording's first ten seconds
> yields a placement at all. Deleting `CoreImageFrameRenderer.render`'s
> `if let pointer = plan.pointer { … }` block reddens `aPointerIsDrawnAtAll` at its own
> pixel-difference expectation, which is the assertion the first mutation never reaches.
> A 40 px constant offset in the renderer's own translation leaves
> `aPointerIsDrawnAtAll` green and reddens `aPointerIsDrawnAtTheRecordedPosition` alone,
> so POSITION is what the second test measures rather than mere presence.
>
> **What they do NOT cover.** `StageCompositor.startRequest(_:)` takes an
> `AVAsynchronousVideoCompositionRequest` and `renderContextChanged(_:)` an
> `AVVideoCompositionRenderContext`, both of which only AVFoundation can construct, so
> no `swift test` test reaches either: `startRequest`'s leading `guard`,
> `newPixelBuffer()`, the `CVReadOnlyPixelBuffer` bridging, `request.finish(...)`, the
> `framesDropped` counter's two increment sites, and the write inside
> `renderContextChanged` are still reached **only** by
> `scripts/run-cross-boundary-probe.sh` and by a person watching a preview or an export.
> `StageCompositor.style` is likewise untouched by `swift test` — it is read only inside
> `startRequest`. Nor do these tests touch what the frame DEPICTS — the fixture
> correctly carries no media, so the source frame is synthesised and the assertion is
> geometric.
>
> **Phase 3A-2's first two tasks are DONE (2026-08-12), in the binding order: the
> gate repaired first, the sites cleared second.** What stood here was the repair
> brief — the three defects, the completion condition, the sites-unit warning — and
> it is preserved in `docs/design/2026-08-12-strict-memory-safety-gate-repair.md`
> together with the alternatives considered. The record of what was done and what
> was measured:
>
> **The repair is clean-per-run.** `scripts/check-strict-memory-safety.sh` now
> cleans a dedicated scratch path (`.build-strict-gate`, gitignored) and compiles
> every target from nothing on every run, so every warning is emitted on every run
> and the warm/cold distinction — the exact place the old design failed — is
> eliminated by construction rather than detected by heuristic. The premise under
> the old incremental design was re-measured and had expired: a from-nothing
> `swift build --build-tests` is ~23 seconds on this machine, not "minutes", and
> the package has no external dependencies, so the scratch path needs no network.
> Compile evidence is now artifacts, not log shapes: zero `.o` files after clean
> (else exit 2), more than zero after build (else exit 3) — the dead progress-line
> guard is gone. The gate reports in SITES (distinct `file:line:column`), with
> macro-buffer emissions resolved through their `expanded code originates here`
> note rather than dropped.
>
> **Both credential halves were run, and in the required order.** Baseline on the
> broken gate, same tree, zero edits: exit 1, 0, 0 — one more draw from the
> documented 0, 3, 3, 0 distribution. After the repair, red half: an unsafe
> construct seeded into `Tests/GeometryTests/NormalizedTests.swift` was listed by
> file:line:column on two consecutive runs, both exit 1; warmth no longer exists to
> qualify. Stability half: five consecutive runs on the unmodified tree — exit 1
> five times, and the five site lists hash identically. Green half, run only after
> the sites were cleared: five consecutive runs, exit 0 five times — the pass-path
> certificate the old gate never had, because on the old gate a pass was
> indistinguishable from a blind run.
>
> **The count moved from 11 to 13, and the instrument is right.** Measured by the
> repaired gate: 13 sites — 12 in `HeadlessTests/PixelBufferSupport.swift`, 1 in
> `ProjectTests/AXChainRecordTests.swift`. The 2026-08-05 count of 11 is not
> contradicted; the comment-compression commits shifted line numbers, and the two
> macro-resolved positions no longer coincide column-exactly with any primary site
> — they name the call inside the macro argument, a genuinely distinct unsafe
> expression the old hand count folded away. This is the divergence the sites-unit
> warning predicted, arriving one measurement later than expected.
>
> **All 13 sites are now marked `unsafe` at their own expression, each with a
> comment at the site saying why it is safe there** — the lock/unlock pair
> bracketing the base-address reads, the loop bounds staying inside
> height × bytes-per-row, the nullable out-pointer `PropertyListSerialization`
> never dereferences when nil. The whole suite ran green after the marks — the
> count comes from `scripts/count-tests.sh`, not from this sentence.
>
> **Phase 3A-2 item DONE (2026-08-12) — `Sources/Headless`'s ambient-time permit
> narrowed from `MP4Exporter.swift` to `MonotonicStopwatch.swift`.** The brief said
> a 345-line exporter with roughly fifteen clock lines; by the time the work
> happened the file was 154 lines with two clock expressions — the argument held
> either way, and the shape of the fix is the `Minting.swift` precedent the brief
> itself cited: make the boundary a file whose EVERY member reads the clock, so
> the whole-file permit costs nothing. `MonotonicStopwatch` (internal — its one
> caller is `MP4Exporter`, same module, and the entry rule's cheaper fix is not
> being public until someone outside needs it) owns the `SuspendingClock` reads
> and the settable-`Date`/sleeping-`ContinuousClock` argument; `MP4Exporter` holds
> a stopwatch and can no longer name a clock at all — the scan's needle list sees
> `SuspendingClock` as a banned name, so reintroducing a direct read is a red
> test, not a review catch. TDD order held: the scan's `permittedPath` flipped
> first and failed loudly on the not-yet-existing file, then the extraction made
> it green; the whole suite is green after.
>
> **Phase 3A-2 item DONE (2026-08-12) — `1a98402`'s whole class is now a compile
> error, which was the checkable outcome the brief demanded.** The shape chosen is
> the first of the two the brief offered: the track queries take the domain —
> `PointerTrack.position(at: HostInstant)` and `ClickTrack.ripplePhase(at:
> HostInstant)` — so a caller cannot hold a bare `Nanoseconds` of ambiguous domain
> at that seam at all, and the composition-offset → host-instant conversion has
> exactly one home, `EpochAnchor.instant(atOffset:)`. Reintroducing the defect by
> hand (`let time = anchor.hostTime + offset; pointer.position(at: time)`) was
> observed failing to compile — `cannot convert value of type 'Nanoseconds' to
> expected argument type 'HostInstant'`, at the exact line the original lived on —
> and reverted. A `CompositionOffset` wrapper (the second shape) was rejected as
> protecting one argument position while leaving the tracks epoch-blind.
>
> Riding with the type change, behaviourally red-then-green: the queries now
> compare epochs before intervals, so an override, sample or click stamped in
> ANOTHER boot session no longer matches this one's overlapping host times by
> coincidence — including the behaviour change `CursorOverride.epoch`'s own doc
> comment promised when the field was added "while zero files exist". Skip, not
> trap: a recording can legitimately span a reboot, the same line
> `HostRange.contains` already draws. `BlindInterval` still carries no epoch —
> giving it one is a persisted-format change deferred on its own migration
> argument. Design record: `docs/design/2026-08-12-clock-domain-types.md`.

> **Phase 3A-3 DONE (2026-08-14): `Soredemo/Capture/` no longer exists.** All eleven
> files, plus `Support/Minting.swift`, are in `Sources/Headless`; the app target is six
> files — SwiftUI, `NSDocument`, the app lifecycle and the generated `BuildProvenance`.
> Seven tasks, each ending green on three gates (`swift test`, the strict-memory-safety
> gate, `xcodebuild`). Design: `docs/design/2026-08-12-phase-3a3-capture-extraction.md`;
> what later phases inherit: `docs/design/2026-08-14-phase-3a-carried-forward.md`.
>
> **The scans were the hard part, not the moves.** Every text scan in
> `Tests/AppSourceTests` enforces a rule by PATH, so a move that outran its scans would
> silently shrink a rule's scope. Six went red and were repointed. **Four went green and
> vacuous** — the keystroke ban and `noAppSourceReadsUserContent` among them — because
> their subject left the tree they scan while their assertion stayed satisfiable. Those
> were found by reading, not by failing, and any future move must check the green scans as
> well as the red ones.
>
> Two scans came out STRONGER rather than repointed: the app-side ambient-value scan and
> the app-side CG-geometry scan are now **zero-permit** — the app target holds neither
> boundary any more, so "no app source does this at all" is what the arrangement supports.
> One scan was **deleted**: `microphoneDegradationMatchesTheMeasuredConsequence` grepped a
> switch arm's literal text, anchored on its column alignment; the file is linkable now and
> a real test calls the function. Its retirement note stays where it stood.
>
> **One gate's scope definition expired.** The redaction check's Gate 2 scanned
> "`Sources/Headless` + `Sources/Render`" and called that the render path — true until a
> PRODUCER moved in. `AXObserver` legitimately reads `.title`; it is the code that captures
> one. Rescoped with an exclusion list, chosen because a new capture file going red is
> louder than a new render file going unscanned.
>
> **260 strict-memory-safety sites** across the three largest files, none of which the app
> target had ever measured — plus two findings that were not call sites: `@preconcurrency`
> imports are themselves flagged (they suppress the checking that would catch a race), and
> `CaptureSession` has storage involving `Unmanaged<CaptureSession>`, annotated `@safe`
> rather than `@unsafe` because the token is encapsulated and `@unsafe` would push a mark
> onto every caller.
>
> **Four times a new test went red and the code was right** (a media filename, a
> points-vs-pixels mix-up, an initialiser's shape, a double-counted file list). Zero product
> defects were found. That ratio is the honest summary: these tests are a floor under future
> changes, not a discovery of past ones.

That is not a shortage of tests; the target is structurally untestable. A library
can be imported. With the logic in `Headless` and the executable reduced to a
shell, `RecordingCoordinator`, `CapturePermissions` and `StageCompositor` — today
guarded by human eyes — come into ordinary test range.

**Logging comes second, and the ordering is the argument.** Logging is diagnosis:
it makes a running app answer questions, which is why every diagnostic today was
expensive archaeology. Extraction is execution. Today's disease was every
automatic instrument agreeing on one misunderstanding, and logging does not treat
that — only letting instruments of a different provenance reach the code does.


The first thing that is not a screen recorder.

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ☐ | `timeline-core` | Integer-nanosecond output↔source mapping, three distinct timestamps: source, camera, output | `derivation-graph` |
| ☐ | `observation-ingest` | Observation log becomes graph evidence — **wired into the recording lifecycle, not a free-floating function** | `observation-log`, `derivation-graph` |
| ☐ | `graph-staleness` | `isCurrent` from version plus input hash. Every cache-hit test paired with an invalidation test | `observation-ingest` |
| ☐ | `framing-targets` | Zoom target from the AX control under each click when it passes the gates; pointer fallback otherwise. **Every rejection names its reason.** **This is the first row that writes a producer, so architecture rule 7 stops being inert here and its mechanism ships with this row** — the target is `Derived`'s public `init(value:origin:review: = .pending)`, which lets a producer set `.approved` without going through `applyingProduced`. It cannot be closed by making the initialiser internal (the app mints authored values through it); it needs a check that a producer does not name it, the same shape as rule 5 over `Sources/`. See `ARCHITECTURE.md` D4 | `observation-ingest` |
| ☐ | `framing-gates` | Named rejection cases with stable codes: confidence absent, confidence low, observation stale, does not contain the click, degenerate rectangle, partly offscreen, **too large**, **best candidate on the truncation boundary** (added from Phase 2's F2-3 — the AX chain is bounded, and a candidate sitting at the cut is indistinguishable on disk from one that was genuinely outermost unless the producer reads the truncation record; measured at 7–8% of clicks, so a normal path, not an edge case). Calibrate the size threshold against real measurements — a pane is not a control | `framing-targets` |
| ☐ | `framing-depth` | Depth scales with the framed control's size, bounded and quantised. **Verify it actually varies on real data** rather than collapsing to two values | `framing-targets` |
| ☐ | `zoom-blocks` | Pre-roll before the click, hold after, deterministic merge of nearby clicks. **Tune merge against real click cadence — demo clicks are 1–3 s apart, and an over-eager merge collapses a whole demo into one zoom** | `framing-depth` |
| ☐ | `camera-motion` | Spring-integrated zoom: settles without overshoot, carries velocity across a re-aim, safe zone so jitter does not move the camera | `zoom-blocks`, `render-core` |
| ☐ | `beat-segmentation` | Actions segment into story beats at long gaps, with pacing diagnostics. **Assert the storyboard and the camera agree; a mismatch is a diagnostic, not silence** | `zoom-blocks` |
| ☐ | `review-ui` | Every generated value shows its origin, review state, and reason. Overrides are first-class. Rejections show which gate fired | `camera-motion`, `app-shell` |
| ☐ | `free-recorder-release` | **Ship the free recorder here, not at the end.** Its only dependency is `review-ui`, and it is the distribution channel everything later sells into | `review-ui` |

---

## Phase 4 — Edit

Four operations. Deliberately not an NLE.

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ☐ | `basic-edit` | Trim, cut, speed via `AVMutableComposition`. No ripple, no snapping, no multicam | `timeline-core`, `app-shell` |
| ☐ | `transcript` | `SpeechAnalyzer` + `SpeechTranscriber`, word-level, on-device. Includes the `AssetInventory` first-run locale flow | `app-shell` |
| ☐ | `text-based-editing` | **The primary editing surface.** Delete words to cut video; removed words invalidate exactly the dependent beats. TextKit 2 for layout, selection, hit-testing | `transcript`, `basic-edit`, `graph-staleness` |
| ☐ | `captions` | Word-timed captions, styled. Evaluate `AVCaptionRenderer` and macOS 27 generated subtitles before rendering by hand | `transcript` |
| ☐ | `selective-rerecord` | Replace one segment; regenerate only what depended on it | `basic-edit`, `graph-staleness` |
| ☐ | `edit-aware-outputs` | Outputs follow the edited timeline, including speed. Cut footage is not rendered | `basic-edit` |

---

## Phase 5 — Launch video

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ☐ | `variants` | 16:9, 9:16, 1:1 — **re-framed against each variant's coverage, not cropped**. Even dimensions inside encoder limits | `framing-depth`, `timeline-core` |
| ☐ | `platform-profiles` | Duration and aspect as compile-time constraints. Reels needs 9:16 **and** 5–90 s, and the compiler says so rather than exporting something that will not appear | `variants` |
| ☐ | `title-scenes` | Core Animation text and shape scenes composited via `AVVideoCompositionCoreAnimationTool` | `render-core` |
| ☐ | `scene-transitions` | Whole-scene transitions between title and product-proof scenes | `title-scenes` |
| ☐ | `music-bed` | `AVAudioEngine` mixing with ducking. Spike Music Understanding before writing beat detection | `title-scenes` |
| ☐ | `launch-video` | Assemble a 15–25 s launch video from reviewed beats. **Every product-proof scene must reference real footage; with no valid proof it cannot be approved, and it never invents a shot** | `scene-transitions`, `variants` |
| ☐ | `written-steps` | Markdown walkthrough, each step citing the action and source interval it came from | `beat-segmentation`, `transcript` |
| ☐ | `post-draft` | Platform-specific copy. **Foundation Models guided generation phrases facts the graph established — never supplies facts it lacks.** Generated type carries citation fields, so `evaluations-harness` in Phase 6 can assert an uncited claim cannot be approved | `written-steps` |
| ☐ | `poster-frame` | Still export via `CGImageDestination` | `render-core` |
| ☐ | `output-pack` | All outputs planned from one graph revision so they cannot disagree. Progress, cancellation, atomic completion. Planning fails loudly rather than producing empty files | `launch-video`, `post-draft`, `poster-frame` |

---

## Phase 6 — CLI and AI editor

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ☐ | `mcp-server` | `NWListener` on `127.0.0.1`, MCP Swift SDK, tool registration | `app-shell` |
| ☐ | `agent-read-tools` | `get_*` returns state; `inspect_*` returns a rendered prose overview | `mcp-server`, `review-ui` |
| ☐ | `agent-review-tools` | `explain_framing`, `approve_beat`, `override_value`, `list_stale` — review posture, not generative | `agent-read-tools` |
| ☐ | `agent-edit-tools` | Mutations return deltas, not whole documents | `agent-review-tools`, `basic-edit` |
| ☐ | `cli-surface` | Swift Argument Parser. `soredemo record/derive/review/edit/pack/export/status`. **Every verb is also an MCP tool** | `agent-edit-tools` |
| ☐ | `agent-skills` | In-app skill catalogue and `read_skill` | `agent-read-tools` |
| ☐ | `evaluations-harness` | Evaluations framework: assert no claim without valid supporting evidence can reach an approvable state | `agent-review-tools` |
| ☐ | `agentic-threat-model` | External text (release notes, changelogs, PR titles) is attacker-controllable and flows toward publishing. Treat as quoted data, never instruction. Test that injection cannot manufacture an approvable claim | `agent-review-tools` |

---

## Phase 7 — Ship

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ☐ | `range-export` | In/out range export | `basic-edit` |
| ☐ | `custom-control-a11y` | Timeline, waveform, and transcript are custom controls and get no accessibility for free | `app-shell` |
| ☐ | `smoke-tests` | End-to-end: record → derive → review → edit → pack → export | `output-pack` |
| ☐ | `signing-notarization` | Entitlements, hardened runtime, signed and notarised disk image, Sparkle feed | `smoke-tests` |

---

## Phase 8 — The release loop

Core to the product, last in build order — it sits on top of everything else.
**Gate: use Phases 1–7 for one of your own real releases first.**

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ☐ | `github-watch` | Local polling of releases, tags, labelled PRs, changelog diffs. No webhook, no server. Token in Keychain | `app-shell` |
| ☐ | `release-evidence` | A GitHub release becomes evidence in the graph, so staleness and the producer-value rule apply unchanged | `github-watch`, `observation-ingest` |
| ☐ | `release-proposal` | Dismissable card. **Never opens the recorder unprompted** | `release-evidence` |
| ☐ | `pack-release-binding` | Every output pack carries the release ref and its evidence hash | `release-evidence`, `output-pack` |
| ☐ | `post-from-release` | Draft cites real PR titles and changelog entries, not a guess from the video | `pack-release-binding`, `post-draft` |
| ☐ | `prepare-post` | Render the right variant, stage text and media, open the platform's web composer. **No API, no OAuth, no cost — works day one on every platform** | `platform-profiles`, `post-from-release` |
| ☐ | `approval-gate` | Per-platform, per-post human approval bound to a content hash. **No auto-publish, no "approve all", no CI bypass** | `prepare-post` |
| ☐ | `coverage-metric` | Releases seen, demos recorded, posts published, per repo, over time. Swift Charts | `release-proposal`, `approval-gate` |
| ☐ | `publish-threads` | Threads API. Free, Tech Provider Verification, 250 posts/24h | `approval-gate` |
| ☐ | `publish-instagram` | IG Reels. **Start the Meta app review early — it is weeks of waiting** | `approval-gate` |
| ☐ | `publish-x` | X API. **Not shippable without visible per-post cost and a spend cap** — $0.015/post, $0.20 with a link | `approval-gate` |

---

## Explicitly not building

Full NLE (ripple, snapping, multicam, clip transitions) · camera/webcam overlay · region capture ·
colour grading and LUTs · FCPXML export · device frames · masks and redaction · cloud rendering ·
Windows, Intel, macOS < 26 · generative video or images · auto-publishing.

---

## Out of order

1. **Meta app review** for Instagram publishing takes weeks and is pure waiting. File it when Phase 5
   starts — the only long pole no engineering speed can shorten.
2. **`free-recorder-release`** ships in Phase 3, not at the end.
3. **`coverage-metric`** — instrument before optimising. Shipping the loop without the number leaves no
   evidence for the one claim the positioning rests on.
