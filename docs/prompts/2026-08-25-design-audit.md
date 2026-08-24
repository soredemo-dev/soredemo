# Design audit: close the gap between Soredemo's output and Screen Studio / ScreenKite

Reply in Traditional Chinese. Work in `~/orca/workspaces/soredemo-main/UIUX` (a git worktree — do not `cd` to the main checkout, never bare `git stash`). Read `AGENTS.md` first and follow its rules: measure before claiming, verify the reasoning under every conclusion, and never let a measurement fail into a legal-looking default. I want the best-quality, best-designed result; the number of lines written is not a constraint, and a "minimal" variant is not what I am asking for.

## Context you must load before doing anything

1. **This codebase, completely.** `Core/Sources/{Capture,Framing,Render,Compositing,Overlays,Project,Variants,Timeline,Geometry}` and `Soredemo/{App,UI}`. Read implementations, not summaries.
2. **`docs/design/2026-08-25-presentation-motion.md`** — the most recent change. It fixed: the 1080p export default, bilinear → Lanczos resampling, card pixel snapping, the O(n²) camera integration (now baked), the step-target lurch (two-stage eased aim), motion blur, a pixel-density zoom ceiling, a spring-followed cursor (`PointerPath`), the 709/sRGB transfer-curve mismatch on ingest, the 601-matrix writer inference, and the master's missing bit rate. Do not redo these; build on them. `git log -1 --stat` shows what landed.
3. **`ROADMAP.md` and `docs/FEATURES.md`** — what is claimed done, partial, and planned. Treat every ◐ row as a candidate gap.
4. **The five open-source recorders** in `~/Documents/opensource/Screen Record Opensource/`:
   - `a Rust recorder` (Rust/wgpu, `crates/rendering`, `crates/recording`, `crates/project`) — zoom_spring, cursor_interpolation, layers, transitions, project format
   - `a Swift recorder` (Swift/CoreImage, `a Swift recorder/Render`, `a Swift recorder/Generators`, `docs/plans`) — the closest architecture to ours; read its render pipeline and its cursor-driven-camera design
   - `an Electron recorder-main` and `an Electron recorder-main` (Electron/TS) — editor UX, timeline, zoom lanes, export presets, cursor assets
   - `a native editor` (Swift) — HDR export, colour handling, codec ladder
   Read code, not READMEs. Note file:line for anything you cite.
5. **Online research** on Screen Studio (screen.studio) and ScreenKite (screenkite.com): their guides, changelogs, feature pages, and any technical write-ups or teardowns. Specifically find out how each handles: cursor smoothing/size/rotation/auto-hide/shake removal, click effects, zoom depth and timing, "follow cursor" camera modes, motion blur, keystroke badges, backgrounds/wallpapers/padding/shadows, window vs area capture, retina/export presets, colour and codec choices, audio (noise removal, silence trimming), captions, aspect variants, and their editor timeline design. Cite URLs.

## What to produce

A single design document at `docs/design/<today>-design-audit.md`, then implementation. Structure:

### Part 1 — Gap analysis (measured, not felt)
For each area below, state what Soredemo does today (file:line), what the best reference does (file:line or URL), and the concrete difference a viewer would see. Rank by visible impact. Areas:

- **Output picture**: resampling, sharpening, supersampling, edge/shadow rendering, corner AA, background gradients/wallpapers, card shadow realism, colour management end-to-end (the 2026-08-25 doc fixed values — verify with a pixel probe, then look at what remains: P3, HDR, 10-bit, chroma).
- **Camera**: zoom depth curve, pre-roll/hold timing, chained pans, cursor-following modes (Screen Studio's "follow cursor", a Swift recorder's cursor-driven camera), easing curves vs springs, re-framing for 9:16/1:1 variants, edge handling, manual zoom keyframes on the timeline.
- **Cursor**: size, native cursor bitmaps vs drawn art (we draw a 7-point arrow and an I-beam; everything else falls back to the arrow — compare with a Rust recorder's `cursor-info`/`cursor-capture` crates and an Electron recorder's `SystemCursorAssets.swift`), rotation while moving, auto-hide when idle, shake removal, click effect variety, keystroke badges (claimed in the ROADMAP row, absent in code).
- **Audio**: what we have (`AudioMix`, `SilenceFinder`, `SpeechTranscription`) vs noise suppression, loudness normalisation, silence auto-cut, background music.
- **Editor UX**: `StageWindow`, `TimelineEditor`, `Filmstrip`, inspector panels vs an Electron recorder/an Electron recorder/Screen Studio: zoom lane editing, drag handles, transcript-based editing, presets, live preview responsiveness.
- **Capture**: window/area/display modes, camera overlay quality, frame-rate honesty, retina scale, multi-display.
- **Export**: presets by destination, size estimate accuracy, GIF quality (palette, dithering), sidecar captions, HDR/P3 options.

### Part 2 — Flaws found while reading
Anything in our code that is wrong, inconsistent, or claimed-but-not-observable, with the evidence. Follow `AGENTS.md`'s "read the implementation, not the summary" and "verify the reasoning under the conclusion" — the 2026-08-25 work found that the colour chain's tags all agreed while every mid tone was 10 levels off, and that a doc comment's "residual 21" had a false explanation. Look for the same shape elsewhere: a test that passes for a reason unrelated to the code, a constant whose stated reason no longer holds, a default that disagrees with its own comment.

### Part 3 — Plan and implementation
Order by visible impact ÷ cost. For each item: design, files, tests that would go red if the property were lost, and the measurement that proves it. Implement in that order, one commit per coherent change, running the gates before each commit: `cd Core && swift test`, `./scripts/check-strict-memory-safety.sh`, `./scripts/run-cross-boundary-probe.sh`, and `xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug -destination 'platform=macOS' build`. Update `ROADMAP.md` rows and write a design doc for each substantive change, in the style of the existing ones under `docs/design/`.

## Rules of engagement
- Pure logic lives in `Core`; AppKit stays in `Soredemo/`. The architecture checker enforces this — read `docs/ARCHITECTURE.md` before adding files.
- Every constant you introduce is named, has a stated reason, and says "uncalibrated" if no measurement chose it.
- When a reference project's approach is borrowed, say so in the doc comment with the path, as the codebase already does.
- Do not weaken an existing test to make new behaviour pass without explaining, in the test, why the old expectation was wrong.
- Report faithfully: if a gate fails, show the output; if something is left undone, say so.
