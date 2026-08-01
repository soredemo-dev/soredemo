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
| ◐ | `architecture-plugin` | `Plugins/ArchitectureCheck`. Rule 1 (imports) **done and capped** — enforced under both `swift build` and `xcodebuild`. Rules 2 (CG types) and 4 (manifest dependencies) next. Rule 3 (determinism) waits for Task 6; rule 5 (CG bridge) waits for Task 18 — both would be vacuous today | `repo-skeleton` |
| ☐ | `geometry` | `NormalizedPoint` (0–1, bottom-left), `NormalizedFrame` with `geometryRevision`; all conversion in one place; cross-revision comparison is a precondition failure | `repo-skeleton` |
| ☐ | `project-format` | Versioned `Codable` document, atomic save, relative paths, upgrade path. Hand-written **`NSDocument`** package coordinator — `ReadableDocument`/`WritableDocument` are SwiftUI types requiring macOS 27, above our floor. The row spans the package/app boundary | `geometry`, `derivation-graph` |
| ☐ | `derivation-graph` | Observations → actions → beats → outputs. Every derived value carries an origin (`generated`/`authored`) and a review state. **The producer-value rule with its boundary tests** | `geometry` |

---

## Phase 2 — Record

Goal: a build that records and plays back. Nothing derived yet. **This phase alone is a shippable free recorder.**

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ☐ | `capture-source` | `SCShareableContent` enumeration; **`SCContentSharingPicker` for the picker — do not build a custom one first** | `repo-skeleton` |
| ☐ | `capture-stream` | `SCStream` + `SCStreamConfiguration`, `showsCursor = false`, `capturesAudio`. Evaluate **`SCRecordingOutput`** for the master before writing an `AVAssetWriter` path | `capture-source` |
| ☐ | `capture-permissions` | Screen Recording, Microphone, Input Monitoring, Accessibility — each degrading precisely | `capture-stream` |
| ☐ | `one-clock` | `CMClock.hostTimeClock` taken once; every timestamp derived from it. A sample before the origin or moving backwards is an error | `capture-stream` |
| ☐ | `audio-tracks` | System audio and microphone as independent tracks, retimed across pause | `capture-stream`, `one-clock` |
| ☐ | `input-observation` | `CGEvent.tapCreate` pointer and click stream, listen-only. **Keyboard filtered to approved shortcuts; secure input suppresses capture entirely** | `one-clock` |
| ☐ | `ax-observation` | `AXUIElementCopyElementAtPosition` for the control under each click, with role, frame, and a preference for well-bounded descendants | `input-observation` |
| ☐ | `observation-log` | Versioned on-disk log joining video, audio, pointer, click, key, and AX records on the one clock | `audio-tracks`, `ax-observation` |
| ☐ | `render-core` | `AVVideoCompositing` custom compositor over Core Image + Metal. Background, card, shadow, corner radius | `repo-skeleton` |
| ☐ | `cursor-render` | Cursor drawn at composite time, spring-smoothed, with click ripples and shortcut badges | `render-core`, `observation-log` |
| ☐ | `export-basic` | `AVAssetWriter` + VideoToolbox: MP4 H.264/HEVC, MOV ProRes, GIF via `CGImageDestination` | `render-core` |
| ☐ | `app-shell` | SwiftUI `NavigationSplitView` + `Inspector`, **native Liquid Glass only**, `@Observable`, `DocumentGroup`. Record → play back → export | `capture-stream`, `render-core`, `project-format` |
| ☐ | `preview-playback` | `CADisplayLink`-driven preview. **Not `CVDisplayLink` — deprecated** | `render-core`, `app-shell` |
| ☐ | `render-parity` | Golden-image tests proving preview and export produce identical frames for the same input | `preview-playback`, `export-basic` |

---

## Phase 3 — Frame it automatically

The first thing that is not a screen recorder.

| State | Row | Outcome | Depends on |
| --- | --- | --- | --- |
| ☐ | `timeline-core` | Integer-nanosecond output↔source mapping, three distinct timestamps: source, camera, output | `derivation-graph` |
| ☐ | `observation-ingest` | Observation log becomes graph evidence — **wired into the recording lifecycle, not a free-floating function** | `observation-log`, `derivation-graph` |
| ☐ | `graph-staleness` | `isCurrent` from version plus input hash. Every cache-hit test paired with an invalidation test | `observation-ingest` |
| ☐ | `framing-targets` | Zoom target from the AX control under each click when it passes the gates; pointer fallback otherwise. **Every rejection names its reason** | `observation-ingest` |
| ☐ | `framing-gates` | Named rejection cases with stable codes: confidence absent, confidence low, observation stale, does not contain the click, degenerate rectangle, partly offscreen, **too large**. Calibrate the size threshold against real measurements — a pane is not a control | `framing-targets` |
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
Windows, Intel, macOS < 27 · generative video or images · auto-publishing.

---

## Out of order

1. **Meta app review** for Instagram publishing takes weeks and is pure waiting. File it when Phase 5
   starts — the only long pole no engineering speed can shorten.
2. **`free-recorder-release`** ships in Phase 3, not at the end.
3. **`coverage-metric`** — instrument before optimising. Shipping the loop without the number leaves no
   evidence for the one claim the positioning rests on.
