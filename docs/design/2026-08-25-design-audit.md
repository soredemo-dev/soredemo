# Design audit — closing the gap to Screen Studio and ScreenKite

**Date:** 2026-08-25
**Status:** Part 1 and 2 complete; Part 3 implemented in order, one commit each
**Builds on:** `2026-08-25-presentation-motion.md` (picture, camera bake, cursor spring, colour), `2026-08-24-colour-pipeline.md`, `2026-08-19-recorder-parity.md`

## What was read

Our tiers in full (`Core/Sources/{Capture,Framing,Render,Compositing,Overlays,Project,Variants}`, `Soredemo/{App,UI}`); a Rust recorder's `crates/{rendering,recording,project,cursor-info,cursor-capture}`; a Swift recorder's `Render/` and `docs/plans/2026-03-08-cursor-driven-camera-*`; an Electron recorder's `electron/native/{NativeCursorMonitor,SystemCursorAssets}.swift` and `src/components/video-editor/videoPlayback/*`; an Electron recorder's `src/lib/cursor/*`; a native editor's `Export/*`. Online: Screen Studio's guide index and its `cursor`, `animations`, `adding-editing-zooms`, `auto-zoom`, `manual-zoom`, `background`, `camera-settings` pages and changelog; ScreenKite's front page and its auto-zoom write-up. Every claim below names its file:line or URL; where a reference publishes no numbers, that is said.

---

## Part 1 — Gap analysis, ranked by what a viewer sees

### 1. The cursor is a drawing, not the cursor — **largest visible gap, every frame**

**Ours.** `CursorArt.pointerPath` is a seven-point silhouette, white fill, 1.5 px black stroke (`Core/Sources/Compositing/CursorArt.swift:17`); the I-beam is three rectangles. `CoreImageFrameRenderer.cursorImage` draws `.pointingHand`, `.crosshair` and both resize shapes as the arrow (`CoreImageFrameRenderer.swift:494`). The classifier returns `.other` for everything because class cursors' images are 0×0 on this OS (`Soredemo/UI/SystemCursorShape.swift`, its own measurement) — so every recording draws the arrow, with the real hotspot recorded and unused.

**References.** an Electron recorder snapshots the live `NSCursor` as an image with its hotspot (`electron/native/SystemCursorAssets.swift:73` `makeAsset`), renders it at a reference pixel height, and classifies by an alpha-signature comparison against the known set (`NativeCursorMonitor.swift:57` `signature(for:)`, 32×32 alpha mask, score by difference). a Rust recorder hashes the live image against a table of OS-version digests (`crates/cursor-info/src/macos.rs:227`) and ships SVG cursors (`CursorConfiguration.use_svg`). Screen Studio's changelog (2025-08-28) "auto-selects cursors matching OS version" and (2025-10-21) added cursor sets — it draws its own art too, but art of every shape, at every size, with the Tahoe set matching the OS.

**Difference a viewer sees.** A hand over a link, a crosshair in a design tool, a resize arrow on a divider — all drawn as an arrow; and the arrow itself is not the macOS arrow.

**What closes it.** Record the cursor's own image. `SystemCursorShape` already samples `NSCursor.currentSystem` on the main actor every 100 ms; the same sample can hand back the image bytes and hotspot. Dedupe by a digest of the alpha mask, write each new image once into `<package>/cursors/<digest>.png`, and stamp `PointerSample` with the digest. The renderer draws the recorded image at the recorded hotspot — which is precisely the value `PointerSample.hotspot` was carried for and the renderer's own comment says it would be right for. Schema 2 → 3 with the field optional, so every existing log decodes unchanged (the same shape `shape`/`hotspot` took). Cost: capture app tier + `Project` record + `Compositing` draw + package I/O. **The largest item here and the one with the most visible return.**

### 2. The camera does not follow the cursor inside a zoom — **the complaint that started this**

**Ours.** `CameraMotion.aim(of:)` aims at `block.target.frame`'s centre for the block's whole span (`Framing/CameraMotion.swift`, `Integrator.aim(of:)`); the centre does not move while the cursor does. "Following" is only the chained pan between blocks.

**References.** an Electron recorder's `cursorFollowCamera.ts:1–70`: while zoomed, the focus is persistent and moves only when the cursor leaves an inner safe zone of the visible viewport, by exactly enough to bring it back in (`snapToEdgesRatio 0.25`). a Swift recorder inverted its whole camera to cursor-driven (`docs/plans/2026-03-08-cursor-driven-camera-design.md`: Layer 1 0.15 s spring always on the cursor, Layer 2 2.5 s re-centre when idle, zoom from intent). ScreenKite: "pan to follow cursor movement" (screenkite.com/blog/screenkite-auto-zoom-how-it-works). Screen Studio: zooms "follow your mouse clicks" (guide/adding-editing-zooms); its cursor-following inside a zoom is visible in every demo and undocumented.

**Difference.** Click a button, move to a menu that opens beside it — ours shows the menu leaving the frame; theirs pans with the pointer.

**What closes it.** an Electron recorder's safe-zone rule, on the aim: while a block is active, the aim's centre starts at the target and is nudged by the least amount that keeps the presented cursor inside the inner `1 − 2 × margin` of the viewport. Fed to the same eased spring, so the pan has the camera's own motion. The cursor enters `CameraMotion` as a closure — `Framing` does not depend on `Render` — sampled per bake step; the compositor already has both. Deterministic, baked.

### 3. Cursor presentation polish — idle hide, tilt, shake

**Ours.** None of the three. The cursor is drawn at full opacity forever; it never tilts; a tremor is smoothed by the spring but a reversal jitter is not removed.

**References.** a Rust recorder: `hide_when_idle` + `hide_when_idle_delay` with a fade and a resume look-ahead (`layers/cursor.rs:719` `compute_cursor_idle_opacity`); `rotation_amount` tilting by `Δx over 0.4 s × 0.03°/px`, clamped ±20° (`rendering/src/lib.rs:3234`); `filter_cursor_shake` drops a reversal inside 100 ms under 0.015 uv (`cursor_interpolation.rs:521`). an Electron recorder: `cursorSway.ts` rotates by speed and direction up to 10°; `hideCursor`/`autoHide` preferences. Screen Studio: "Auto-hide idle cursor", "Rotate cursor while moving", "Remove cursor shakes" (screen.studio/guide/cursor).

**Difference.** A cursor parked over the content while someone talks; a cursor that slides without weight.

**What closes it.** `CursorStyle` gains `hidesWhenIdle`, `idleDelay`, `tiltAmount`; `PointerPath` already carries speed and can carry heading; the renderer fades and rotates the art about its hotspot. Shake removal is a pre-filter on the samples before the spline, a Rust recorder's rule verbatim.

### 4. Keystroke badges — claimed, absent

**Ours.** `KeySample` is recorded (`Project/ObservationRecord.swift:98`) with the approved shortcut string; ROADMAP's `cursor-render` row claims "shortcut badges"; nothing reads the records — `grep -rn KeySample Core/Sources/Compositing` finds only the transcription file. a Swift recorder has `FrameEvaluator+Keystroke.swift` with fade-in/out segments. ScreenKite: "zooms in on every click and keystroke".

**What closes it.** A `KeystrokeTrack` in `Overlays` (instants → badges with a hold and a fade), drawn by `TextArt` on a plate at the bottom of the card, above the caption. The row's claim becomes observable.

### 5. The card's shadow and the background

**Ours.** One Gaussian-blurred silhouette at `radius / 2` with no offset (`CoreImageFrameRenderer.swift:194`); gradients through `CISmoothLinearGradient`; wallpapers cover-scaled. a Rust recorder: `ShadowConfiguration {size, opacity, blur}` (`project/src/configuration.rs:218`) and gradient `noise_intensity`/`noise_scale` to break banding (`layers/background.rs:815`), plus `inset`, `border`, and a decorative `frame` style. Screen Studio: padding, rounded corners, inset, shadow, wallpaper/gradient/colour/image, "glassmorphism wallpapers" (changelog 2025-10-02).

**Difference.** Ours reads as a rectangle with a halo; theirs as a window sitting on a surface — a shadow that falls *down*, and a gradient without bands on a large fill.

**What closes it.** A two-part shadow: a tight contact shadow plus a wide ambient one offset downward, both from the card's own silhouette; dithered noise at ≈1/255 amplitude on gradients. Small change, every frame.

### 6. Editor: adding a zoom where no click happened

**Ours.** The zoom lane moves, resizes and suppresses the *derived* zooms (`TimelineEditor.swift:133–200`); `FramingOverride.frame` exists in `Framing` but no UI creates one at an arbitrary instant. Screen Studio: click on the zoom lane to add a zoom, purple blocks with drag handles, manual target via a draggable dot (guide/adding-editing-zooms, guide/manual-zoom).

**What closes it.** A "click on the lane" that mints a `FramingOverride` at that instant with a `.frame` centred on the pointer's presented position, and a draggable target in the preview. UI-heavy; scheduled after the render items.

### 7. Audio

**Ours.** Per-source gain (`AudioMix`), silence detection and removal (`SilenceFinder`, the Silence lane), on-device transcription. No noise suppression, no loudness normalisation, no music bed. Screen Studio: "microphone enhancement" (changelog 3.7.1), background music with a built-in library (changelog 3.4.9), mouse click sound. None of the open-source five suppresses noise in-process — an Electron recorder's ffmpeg filters are tempo and sync only (`electron/ipc/ffmpeg/filters.ts`). **The platform has one for free:** `AVAudioEngine.inputNode.isVoiceProcessingEnabled` applies Apple's own suppression and echo cancel at capture; `MicrophoneSource` uses `AVCaptureSession` today (`MicrophoneSource.swift:19`). A capture-side change with a real cost — it alters the master, which this project treats as evidence — so it belongs behind a toggle and a second recorded track, not as a default.

### 8. Output picture, after 2026-08-25

Verified again by pixel probe in this pass (`theMidTonesSurviveTheExport`, `theExportPreservesTheSourcesPixelValues`, both green). What remains: 4:2:0 chroma on every H.264/HEVC export (the measured 101-level edge smear, `ExportFormat.swift:30`) — the honest fix is HEVC 4:4:4, which `CodecVerdicts` reports this machine's encoder does not produce; P3 and HDR are conversions of an sRGB master and buy nothing but a tag (colour-pipeline note). No further work here.

### 9. Capture

Display, window (followed live), region (remembered rectangle) — parity with Screen Studio's three modes (guide/recording-*). Frame-rate honesty is already measured (`capture-stream` row). iPhone Mirroring capture (Screen Studio 2025-10-21) is a window capture of the Mirroring app and needs nothing new.

### 10. Export

Match Recording, HEVC/ProRes/4444, size estimate calibrated to a Rust recorder's — parity or better. ScreenKite exports H.264 only. Screen Studio's "new GIF pipeline" (changelog) — ours already quantises after scaling with ImageIO's palettes; no measured gap.

---

## Part 2 — Flaws found while reading

1. **`cursor-render` row claims shortcut badges; no file reads `KeySample`.** Closed by Part 3 item 4.
2. **`CaptureSession.swift:795` still calls sRGB "a placeholder gamut choice".** The colour-pipeline note made it a decision and the 2026-08-25 ingest fix depends on it being one. Comment corrected in this pass.
3. **`CoreImageFrameRenderer.pointerScale` says "never below 1.0" with no reason** (`CoreImageFrameRenderer.swift:352`). At a 720p export the arrow is 1080p-sized — a third larger than the picture it sits on. The reason turned out to be legibility in small embeds, which `CursorStyle.scale` already provides; the floor is redundant with it. Left as is and named, since a change moves every sub-1080 export's cursor and nobody asked.
4. **`SystemCursorShape` records `.other` for every cursor and the renderer draws the arrow for `.other`** — the two are individually correct and together mean the shape pipeline has never once changed a pixel on a real recording. Closed by Part 3 item 1.
5. **A flaw I claimed and then measured out of existence.** The first draft of this list said `aReAimCarriesVelocityRatherThanRestarting`'s `3 × singleJump` bound had gone slack under the eased aim. Tightening it to 1.5× went red: the re-aim's largest per-frame jump is 2.14× the plain move's (0.0394 against 0.0184), because a camera re-aimed mid-settle carries the velocity it already has and genuinely moves faster. The bound is right and now says why. Left here rather than deleted, per `AGENTS.md`: a conclusion checked and reversed is worth more than one never written.

---

## Part 3 — Plan, in order of impact ÷ cost

| # | Item | Tier(s) | Test that reddens if lost | Measurement |
| --- | --- | --- | --- | --- |
| 1 | Cursor-follow camera (safe zone on the aim) | Framing, Compositing | cursor leaves the zone → centre moves; inside → centre still | centre delta vs. zone edge, baked |
| 2 | Idle hide, tilt, shake removal | Render, Compositing | opacity 0 after delay; tilt ∝ Δx; reversal dropped | pixel alpha at rest; rotation angle |
| 3 | Keystroke badges | Overlays, Render, Compositing | badge pixels present at a key instant, absent after fade | pixel diff |
| 4 | Shadow and gradient noise | Compositing | darker below than above the card; gradient spread ≥ 1/255 | pixel probe |
| 5 | Recorded cursor images (schema 3) | App, Capture, Project, Compositing | a recorded image is drawn, at its hotspot | pixel diff against the PNG |
| 6 | Add-zoom on the lane | App | override minted at the instant | model state |
| 7 | Voice processing behind a toggle | Capture, App | second track present | file inspection |

Items 1–4 are implemented in this pass in that order; 5–7 follow. Each has its own commit and gates.
