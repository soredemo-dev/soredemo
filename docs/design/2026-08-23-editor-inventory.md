# Editor inventory — what the five recorders have, what Soredemo has, and what to move

2026-08-23. Written before any porting, because "move the editor" is not one task and the
order matters more than the total.

Measured, not recalled: every file count and line count below came from walking the trees in
`../opensource/Screen Record Opensource/`.

---

## 1. What Soredemo's editor is today

Six things, and it is worth being precise because the inventory is a diff against this.

| | Where | What it does |
| --- | --- | --- |
| Cut / trim | `Core/Sources/Timeline/EditTimeline.swift` | Integer-nanosecond output↔source mapping. `removing(sourceRange:)`, `trimmed(toSource:)`, `merged()` |
| Timeline strip | `Soredemo/UI/TimelineEditor.swift` | Kept spans filled, cut spans hollow, playhead, drag-to-select, "Remove selection" / "Keep only selection" / "Undo all edits" |
| Snapping | `Core/Sources/Timeline/SnapEngine.swift` | Sticky snapping, ported from a native editor |
| Framing review | `Soredemo/UI/FramingReview.swift` | Per-click origin / review state / gate reason, and first-class overrides |
| Look | `Soredemo/UI/StageStylePicker.swift` | Background preset, padding, corner radius, shadow |
| Output | `Soredemo/UI/StageWindow.swift` | 16:9 / 9:16 / 1:1, MP4 export |

**What that means concretely.** One video track. No clips as objects — the timeline is a list of
kept spans, not a list of things a person can select, move, or reorder. No undo beyond "undo
all edits". No keyframes. No text. No captions. No audio waveform. No second media source.

---

## 2. The five projects, measured

| Project | Language | Editor surface | Notes |
| --- | --- | --- | --- |
| **a native editor** | Swift, 534 files | **A complete NLE.** Editor 10,106 lines · Timeline 5,972 · Preview 5,501 · Inspector 5,351 · MediaPanel 4,633 · Export 3,857 · Compositing 2,136 · Audio 2,135 | GPL-3.0. No capture at all |
| **a Swift recorder** | Swift, 208 files | A recorder's editor. Views 8,359 lines · Render 8,355 · Generators 5,111 | Apache-2.0. Closest in shape to what Soredemo is |
| **an Electron recorder** | TypeScript | A recorder's editor with captions, annotations, webcam | AGPL-3.0. No Swift to port; read for UX |
| **an Electron recorder** | TypeScript | Similar, plus blur and background images | MIT. Same |
| **a Rust recorder** | Rust + TypeScript | Captions, gradients, clip transitions, audio library | AGPL-3.0. Editor is TS |

**Only a native editor and a Swift recorder have Swift to move.** The other three are read for *what the
surface should be*, not for code — and that is not a lesser contribution: three independent
teams converging on the same panel is stronger evidence about UX than one team's source.

---

## 3. The inventory

Ranked by what a person recording a product demo actually reaches for. "Have" is Soredemo.

### Tier 1 — the editor is not an editor without these

| Feature | Who has it | Have? | Where it would come from | Effort |
| --- | --- | --- | --- | --- |
| **Clips as objects** — select, move, delete, reorder | all four | ✗ | a native editor `Models/Timeline.swift`, `Editor/ViewModel/+ClipMutations`, `+Selection` | large — changes `EditTimeline`'s shape |
| **Undo / redo** | all four | ✗ (only "undo all") | a native editor `Editor/EditorUndo.swift`, 79 lines, `UndoManager` wrapper | small |
| **Split at playhead** | all four | ✗ | a native editor `OverwriteEngine.swift`, 78 lines, "pure functions" by its own header | small |
| **Ripple delete** — close the gap | a native editor, a Rust recorder | ✗ | a native editor `RippleEngine.swift`, 84 lines, pure | small |
| **Trim handles on the clip** | all four | ✗ (sliders only) | a Swift recorder `Views/Timeline/TrimHandleView.swift` | medium |
| **Zoom the timeline** | all four | ✗ | a Swift recorder `TimelineView+Gestures`, a native editor `TimelineGeometry` (168 lines, has a pure init) | small |
| **Keyboard shortcuts** | all four | ✗ | an Electron recorder/an Electron recorder `ShortcutsConfigDialog`, a Swift recorder `KeyboardShortcutHelpView` | medium |

### Tier 2 — what makes the output look produced

| Feature | Who has it | Have? | Where | Effort |
| --- | --- | --- | --- | --- |
| **Keyframes** — animate any property | a native editor | ✗ | `Models/Keyframe.swift` 241 lines + `Inspector/Keyframes/` | medium |
| **Manual zoom regions** — author a zoom, not just review one | all four | ✗ | an Electron recorder `zoomRegionUtils`, a Rust recorder `zoom.rs` | medium |
| **Motion blur during camera moves** | an Electron recorder | ✗ | an Electron recorder `zoomMotionBlur*` (read only) | medium |
| **Speed / time-remap** | a native editor, an Electron recorder, a Rust recorder | ✗ | an Electron recorder `clipSpeedChange.ts` (read), a native editor `Models/Timeline` | medium |
| **Background images / gradients** | an Electron recorder, a Rust recorder | partial (gradients only) | an Electron recorder `backgroundImageUpload`, a Rust recorder `GradientEditor.tsx` | small |
| **Blur regions** — hide a password | an Electron recorder | ✗ | `BlurSettingsPanel.tsx` (read) | medium |
| **Crop** | an Electron recorder, an Electron recorder, a Rust recorder | ✗ | `CropControl.tsx` (read) | medium |
| **Text / titles** | a native editor, a Rust recorder | ✗ | a native editor `Models/TextStyle`, `TextLayout`, `TextAnimation`, `Compositing/TextFrameRenderer` | large |
| **Annotations** — arrows, boxes | an Electron recorder, an Electron recorder | ✗ | `AnnotationOverlay.tsx`, `ArrowSvgs.tsx` (read) | medium |

### Tier 3 — audio

| Feature | Who has it | Have? | Where | Effort |
| --- | --- | --- | --- | --- |
| **Waveform on the timeline** | a native editor, a Rust recorder | ✗ | a native editor `Audio/WaveformExtractor.swift`, 62 lines | small |
| **Level meters** | a native editor | ✗ | `Audio/AudioMeter.swift`, `AudioMeterView.swift` | small |
| **Per-track volume / mute** | all four | ✗ | a native editor `Inspector/Tabs/AudioTab.swift` | small |
| **Dead-air removal** | a native editor | ✗ | `EditorViewModel+DeadAir.swift` | medium |
| **Audio enhance / denoise** | a native editor | ✗ | `Audio/AudioEnhancer.swift` | medium |
| **Transport-latency compensation** | a Rust recorder | ✗ | `crates/audio/src/latency.rs`, 1189 lines (read — it is Rust) | large |

### Tier 4 — captions and transcript

| Feature | Who has it | Have? | Where | Effort |
| --- | --- | --- | --- | --- |
| **Transcription** | a native editor, a Rust recorder, an Electron recorder | ✗ | a native editor `Transcription/` 732 lines, `SpeechAnalyzer` | medium |
| **Caption editing** | an Electron recorder, a Rust recorder | ✗ | an Electron recorder `captionEditing.ts`, `captionOps.ts` (read) | medium |
| **Caption styling and layout** | an Electron recorder, a Rust recorder | ✗ | an Electron recorder `captionStyle.ts`, `captionLayout.ts` (read) | medium |

### Tier 5 — project and UX shell

| Feature | Who has it | Have? | Where | Effort |
| --- | --- | --- | --- | --- |
| **Save / reopen a project** | all four | ✗ (scratch only) | `ProjectDocument.swift` exists but is unwired; a native editor `Project/`, 1,517 lines | medium |
| **Unsaved-changes guard** | an Electron recorder | ✗ | `UnsavedChangesDialog.tsx` (read) | small |
| **Dirty-state tracking** | an Electron recorder | ✗ | `projectDirtyState.ts` (read) | small |
| **Media panel** — more than one source | a native editor | ✗ | `MediaPanel/` 4,633 lines | large |
| **Export presets + progress + cancel** | all four | partial (no progress, no cancel) | an Electron recorder `exportProgressState.ts`, `exportStatusModel.ts` (read) | medium |
| **GIF export** | a Swift recorder, an Electron recorder, an Electron recorder | ✗ | a Swift recorder `Render/GIFEncoder.swift`, `ExportEngine+GIFExport.swift` | small |
| **Design tokens** | a Swift recorder, a native editor | ✗ | a Swift recorder `DesignSystem/` — Spacing, Typography, DesignColors, CornerRadius, AnimationTokens, Accessibility | small |
| **Onboarding / tour** | a Swift recorder, a native editor, an Electron recorder | ✗ | a Swift recorder `Views/Onboarding/`, a native editor `Editor/Tour/` | medium |

### Deliberately out of scope unless asked

a native editor's `Agent` (13,727 lines — an AI agent shell), `Account`, `Backend`, `Search`,
`Telemetry`, `Generation` (6,498 lines of cloud video generation), `Multicam`, `Nesting`,
`Speakers`, `ChromaKey`, `Matte`, `ColorWheels`/`ColorScopes`/`LUTLoader`. These are a
general-purpose NLE and a commercial product's plumbing. They are listed so the omission is a
decision rather than an oversight — say the word and they go in the plan.

---

## 4. Proposed order

Each block is one commit with all four gates green, and each is chosen so the thing before it
is not wasted work.

1. **Clips as objects.** Everything in Tier 1 needs it, and it changes `EditTimeline`'s shape —
   doing it after the small wins would mean redoing them. This is the one large piece that
   cannot be deferred.
2. **Undo/redo, split, ripple delete.** Three small pure engines from a native editor (241 lines
   together) that only make sense once clips exist.
3. **Timeline UX**: trim handles, timeline zoom, keyboard shortcuts, design tokens.
4. **Waveform + level meters + per-track volume.** Small, and audio is invisible on the
   timeline today.
5. **Keyframes**, then the properties worth animating: manual zoom regions, crop, blur.
6. **Project save/reopen** with dirty state and an unsaved-changes guard.
7. **Export**: progress, cancel, presets, GIF.
8. **Captions**: transcription, then editing, then styling.
9. **Text/titles** — the largest remaining, and the least specific to a screen recorder.

---

## 5. Two things worth saying before starting

**Line-by-line reading has already paid for itself three times.** an Electron recorder's
`CGS_REQUIRE_INIT` comment unblocked a probe; a Swift recorder's audio architecture named the writer
deadlock; an Electron recorder's own copy of the per-sample-duration bug explained why ours was fatal and
theirs is not (they encode, we pass through). The inventory above is worth less than the
reading that produced it.

**Porting UI is not porting code.** a native editor's timeline is 5,972 lines welded to its
`EditorViewModel`, `Timeline`, `Track` and `Clip`. Taking it wholesale means taking its model
layer, which is a different architecture from this one — three enforced tiers with a build
graph that holds them apart. What moves cleanly is what is already pure: `RippleEngine`,
`OverwriteEngine`, `SnapEngine`, `TimelineGeometry`'s non-view initialiser, `Keyframe`,
`WaveformExtractor`. What does not is the view layer, which gets rebuilt against our own model
with their behaviour as the specification.
