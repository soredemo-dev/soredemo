# What the other screen recorders do, and what this one does

Compiled 2026-08-27 from the vendors' own published material (Screen Studio, a Rust recorder,
Motionik, Borumi, ScreenKite), from ScreenKite's feature and guide pages, and from
reading the five open-source projects kept beside this repo. **The Soredemo column
was verified against this codebase on the day of writing, not assumed** — where a
row says "yes", a file is named for it.

Written in English because this repository is English throughout and is intended to
be published. Nothing here is copied code; it is a record of what exists elsewhere so
that a decision about what to build next is made against facts rather than memory.

---

## 1. The competitive field

| Product | Shape | Business model | Platform |
|---|---|---|---|
| **Screen Studio** | Opinionated recorder + automatic editor | Subscription (monthly / yearly) | macOS only |
| **a Rust recorder** | Three modes: Instant (upload-as-you-record), Studio (local + edit), Screenshot | Free tier; $29/yr desktop licence; $12/user/mo Pro | macOS, Windows, Chrome ext |
| **Motionik** | Screen Studio alternative, feature-maximal | Free w/ watermark; $59 once; $39/yr; $78/yr cloud | macOS 13.1+, Windows 10+ |
| **Borumi** | Scene-based: ideate → record → edit, retakes first-class | $79 lifetime | macOS, Windows |
| **ScreenKite** | Native Swift + Metal, "fastest export", agentic AI editing | Free w/ watermark; $79.99–99.99 once, 3 Macs | macOS 14+ (Win/Chrome "in development") |
| **Soredemo** (this) | Native Swift, local-only, no account, no upload | — | macOS 26+ |

**The one axis where this project is deliberately alone:** every product above has, or
is building, a share-link / cloud tier. This one does not and will not — nothing it
produces leaves the machine unless a person sends it. That is a product decision, not
a gap, and it removes an entire column from the comparison (Instant mode, viewer
analytics, password-protected shares, team workspaces, SSO, cloud storage).

---

## 2. Feature matrix

Legend: **✓** shipped · **·** absent · **↺** deliberately declined · **?** unverified claim

### Capture

| Capability | Screen Studio | a Rust recorder | Motionik | Borumi | ScreenKite | **Soredemo** |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Full display | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** |
| Window | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** `WindowTargets` |
| Region / area | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** `RegionPickerOverlay` |
| Window follow (moves with the window) | ? | · | · | · | ? | **✓** `WindowFollower` |
| Webcam | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** `CameraRecorder` |
| Microphone | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** `MicrophoneSource` |
| System audio | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** ScreenCaptureKit |
| Per-app system audio | ✓ | · | · | · | · | **·** |
| **iPhone / iPad over USB** | ✓ | · | ✓ | · | ✓ | **✓** `MobileScreen` |
| 4K / 60 fps | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** |
| **Hide desktop icons** | ✓ | · | · | · | · | **✓** `DesktopIcons` |
| Screenshot mode | · | ✓ | ✓ | · | ✓ | **·** |
| Scene-by-scene record + retakes | · | · | · | ✓ | · | **·** |
| Teleprompter / script on screen | · | · | · | ✓ | · | **·** |

### Cursor and zoom

| Capability | Screen Studio | a Rust recorder | Motionik | Borumi | ScreenKite | **Soredemo** |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Automatic zoom on activity | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** `Framing` |
| Manual zoom blocks on timeline | ✓ | ✓ | ✓ | · | ✓ | **✓** |
| Zoom re-fit for vertical export | ✓ | · | ✓ | ✓ | · | **✓** |
| Smooth cursor movement | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** `PointerPath` |
| Cursor size after recording | ✓ | ✓ | ✓ | · | ✓ | **✓** |
| High-resolution system cursors | ✓ | · | · | · | · | **✓** `SystemCursorShape` |
| Auto-hide idle cursor | ✓ | · | ✓ | · | · | **✓** |
| Loop cursor to start position | ✓ | · | · | · | · | **✓** `CursorLoop` |
| Click effect (ripple) | · | ✓ | ✓ | · | ✓ | **✓** `ClickTrack` |
| Click effect (cursor presses) | ✓ | ✓ | ✓ | · | ? | **✓** `CursorPress` |
| Click sound effects | · | · | ✓ | · | · | **·** |
| Cursor tilt while moving | · | · | · | · | · | **✓** *(nobody else has this)* |
| Motion blur | ✓ | ✓ | ✓ | · | · | **✓** `RenderPlan.motionBlur` |
| 3D / perspective zoom | · | · | ✓ | · | · | **·** |

### Camera

| Capability | Screen Studio | a Rust recorder | Motionik | Borumi | ScreenKite | **Soredemo** |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Overlay position / size | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** |
| Shape (circle / rounded) | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** |
| Shrinks during zoom | ✓ | · | ✓ | · | · | **✓** `scaleDuringZoom` |
| **Moves out of the cursor's way** | · | · | · | · | · | **✓** `CameraDodge` *(nobody else)* |
| Show / hide on a timeline | · | · | ✓ | ✓ | · | **·** |
| Background removal | · | · | ✓ | · | · | **✓** `PersonMask` |
| Zoom / crop / mirror the camera | · | · | ✓ | · | · | **·** |
| Full-screen camera moments | · | · | ✓ | ✓ | · | **·** |

### Editing

| Capability | Screen Studio | a Rust recorder | Motionik | Borumi | ScreenKite | **Soredemo** |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Audio while dragging the playhead** | ? | · | · | · | · | **✓** `ScrubGrain` + `ScrubAudio` |
| **Remove still stretches (dead air in the picture)** | · | · | · | · | · | **✓** `StillnessFinder` *(nobody else)* |
| Trim / cut / split | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** `EditTimeline` |
| Reorder clips | · | · | · | ✓ | ✓ | **✓** `moving(id:to:)` |
| Speed up / slow down | ✓ | ✓ | ✓ | · | ✓ | **✓** 0.25×–4×, video *and* audio via `scaleTimeRange` |
| Remove silences automatically | · | · | · | · | · | **✓** `SilenceFinder` *(nobody else)* |
| Transcript-based editing | · | · | · | ✓ | ✓ | **·** (transcript exists; deleting text does not cut) |
| Crop the frame | ✓ | · | ✓ | · | · | **✓** `CropRect` |
| Text overlays | · | · | ✓ | · | ✓ | **✓** `TextTrack` |
| Images / logos overlay | · | · | ✓ | · | ✓ | **·** |
| Arrows / shapes / highlights | · | ✓ *(screenshot mode)* | ✓ | · | · | **✓** `AnnotationTrack` |
| Content masks / redaction | · | ✓ | ✓ | · | · | **✓** `RedactionTrack` |
| Keyboard-shortcut badges | ✓ | · | · | · | ✓ *(zooms on keystroke)* | **✓** `KeystrokeBadge` |
| Background music | · | · | ✓ | · | ✓ | **✓** `MusicBed` |
| Music ducks under speech | · | · | · | · | · | **✓** `MusicDucking` *(nobody else)* |
| Markers / chapters | · | ✓ *(AI chapters)* | · | · | ✓ | **✓** Mark track |
| Scene transitions | · | · | · | ✓ | ✓ | **·** |
| B-roll library | · | · | · | · | ✓ | **·** |

### Appearance

| Capability | Screen Studio | a Rust recorder | Motionik | Borumi | ScreenKite | **Soredemo** |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Background blur (wallpaper)** | ✓ | · | · | · | · | **✓** `StageStyle.backgroundBlur` |
| Solid colour background | ✓ | ✓ | ✓ | · | ✓ | **✓** `StageBackground.solid` |
| Background: colour / gradient / wallpaper | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** `WallpaperGallery` |
| Padding / outer spacing | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** |
| Shadow | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** |
| Inset | ✓ | · | ✓ | · | · | **·** |
| Rounded corners | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** |
| Horizontal / vertical / square output | ✓ | · | ✓ | ✓ | · | **✓** |
| **Device frames (iPhone/iPad bezels)** | ✓ | · | ✓ | · | ✓ | **✓** `DeviceFrame` |
| Layout presets | · | · | · | ✓ | · | **·** |
| Saveable / shareable style presets | ✓ | · | · | · | · | **·** |

### Audio and AI

| Capability | Screen Studio | a Rust recorder | Motionik | Borumi | ScreenKite | **Soredemo** |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Voice volume normalisation | ✓ | · | · | · | · | **✓** `Loudness` *(was listed absent; it has shipped)* |
| **Background noise removal** | ✓ | · | ✓ | ✓ | · | **✓** `NoiseReduction` |
| Transcript generation | ✓ *(on-device)* | ✓ *(cloud)* | ✓ | ✓ | ✓ *(WhisperKit on-device; ElevenLabs cloud on Intel)* | **✓** `Transcript` |
| Burned-in captions | ✓ | ✓ | ✓ | ✓ | ✓ word-level | **✓** `CaptionStyle` |
| Subtitle file export | ? | ✓ | · | · | ✓ | **✓** `SubtitleFile` |
| AI titles / summaries / chapters | · | ✓ | · | · | ✓ | **·** ↺ *(would require upload)* |
| Agentic editing (Claude Code / Codex / Gemini) | · | · | · | · | ✓ | **·** |

### Export and sharing

| Capability | Screen Studio | a Rust recorder | Motionik | Borumi | ScreenKite | **Soredemo** |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Transparent export (alpha channel)** | · | · | · | · | · | **✓** `StageBackground.transparent` *(nobody else)* |
| MP4 up to 4K 60 | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** |
| GIF | ✓ | · | ✓ | · | · | **✓** `GIFExporter` |
| Export presets (web / social / editor) | ✓ | · | ✓ | · | ✓ | **✓** `.web` `.message` `.editing` |
| Copy video to clipboard | ✓ | · | · | · | · | **✓** `ExportQueue` |
| **Export an in/out range only** | **·** | · | · | · | ✓ | **✓** `EditTimeline.restricted` |
| FCPXML / hand-off to a real NLE | · | · | · | · | ✓ | **✓** `FinalCutXML` |
| Share link / cloud | ✓ | ✓ | ✓ | ✓ | ✓ | **↺ declined** |
| Password-protected / private shares | · | ✓ | ✓ | · | ✓ | **↺ declined** |
| Viewer analytics | · | ✓ | ✓ | · | ✓ | **↺ declined** |

---

## 3. What the open-source projects beside this repo actually contain

Read directly, not from their READMEs. Useful because a claim in a marketing page is
not a design, and these are the only places where a design can be read.

| Project | Language | Size | Architecture | Notable for us |
|---|---|---|---|---|
| **a Rust recorder** | Rust + TS | 596 rs, 1556 ts | Tauri; `apps/` + `crates/` | Three-mode product shape; upload-while-recording |
| **an Electron recorder-main** | TypeScript | 202 ts | Electron | — |
| **an Electron recorder-main** | TypeScript | 385 ts | Electron | `cursorClickBounce: 3.5` over 350 ms — the press curve's origin |
| **a native editor** | **Swift** | **534 swift** | SwiftPM, 26 feature groups | **FCPXML export (10 files), screenshot mode (9 files)**; `NSWindowController`-owned windows |
| **a Swift recorder** | **Swift** | **208 swift** | Xcode, layer groups | `clickScaleModifier`; `AVCaptureDevice` device discovery (6 files); motion blur (5 files) |

**Measured absence, stated carefully:** none of the five contains any of
`deviceFrame`, `noiseSupp`, or `backgroundRemoval`, and none references
`kCMIOHardwarePropertyAllowScreenCaptureDevices` or `AVCaptureDeviceTypeExternal`.
So for iOS capture, noise suppression, and camera background removal **there is no
reference implementation to read** — those three must be designed from Apple's
frameworks directly. (First pass of this scan reported zeros for everything because
zsh expanded the unquoted `--include=*.swift`; the numbers above are from the
quoted re-run. Recorded because the failure mode is invisible.)

---

## 3a. What a phone recording can and cannot carry, measured

Added 2026-08-29, because it decided a feature and contradicts a guess made earlier in this file.

**There is no touch data. Not for anyone.** Screen Studio's own guide says it plainly:

> Due to privacy limitations, Screen Studio cannot record your finger taps the same way it can
> record your mouse clicks and movement in desktop recordings — **automatic zooms are not
> supported** for iOS/iPadOS recordings.

iOS does not send touch coordinates over the CoreMediaIO screen-capture interface, and no
application on the Mac side can obtain them. Measured here too: a connected iPad exposes PTP,
Apple's USB multiplexor and two network-over-USB interfaces, and the capture device it becomes
carries video and audio.

So the field is: **nobody has automatic zoom on a phone recording.** Screen Studio, which ships
the most complete iOS support of the five, offers device frames, audio, and manual zoom, and
tells its users why the automatic kind is missing.

This project derives zooms from what CHANGES on screen instead (`MotionActivity`), which needs no
touch data. It is a weaker signal than a click — it knows something moved, not what was pressed —
and it is the only automatic answer any of these tools has for a phone.

**Screen Studio's own workaround is worth knowing**: connect a Bluetooth mouse to the iPad. A
cursor then appears in the recording, and everything that follows a cursor has something to
follow.

### Filler-word removal: refused, and the SDK says why

**2026-08-29.** ScreenKite ships "filler-word cleanup"; the research into what users ask for names
"removing filler words and silence" as a headline want. It is not built here, and the reason is a
hard fact rather than a judgement.

**macOS 26's `SpeechTranscriber.TranscriptionOption` has exactly one case:**
`.etiquetteReplacements`. There is no verbatim mode, no disfluency option, nothing to ask. The
recogniser's whole design is to produce clean readable text, and `etiquetteReplacements` and
automatic punctuation are what that intent looks like in an API.

Measured against synthesised speech saying *"So um I was uh thinking about this, er, feature. Hmm.
It is, like, useful."*:

    um    ->  transcribed as "am"     a real word
    uh    ->  no token at all
    er    ->  kept
    Hmm.  ->  no token at all
    like  ->  kept

So the fillers a word list could safely match are the ones the recogniser drops, and the one it
kept a token for came back as a **legitimate English word**. A dictionary approach would miss most
of them and would put "am" on a delete list.

The other half is worse and needs no measurement: the interesting fillers — *like*, *so*,
*actually*, *right*, *basically* — are real words. No list can tell "I like this" from "it is,
like, useful". That needs discourse analysis, not a lookup.

**What shipped instead: word-level cutting.** The transcript already carried per-word timings and
had never used them for anything. A sentence can now be opened into its words, any of them chosen,
and cut — adjacent choices merged so the breath between them goes too. The person decides which
word is a filler, which they can do at a glance and no dictionary can do at all.

The asymmetry that settled it is the same one that removed the phone auto-zoom: a missed "um"
costs nothing, and a deleted "am" is somebody's sentence changed without being asked.

### Reading the two projects that had only been skimmed

**2026-08-30.** The subsystem sweep read a Rust recorder and a Swift recorder closely and gave a native editor and
an Electron recorder a module listing. This closes that, and the useful outcome is a correction rather than
a technique.

**a native editor, by module** — 534 files, 100k lines. `Agent` is the largest at 13.7k and
`Generation` next at 6.5k; both are AI features that require a server and are declined here. What
was worth reading:

  * **`Preview/ScrubAudioEngine`** (643 lines) — audio while dragging the playhead, built as
    granular synthesis: 2400-frame grains with 144-frame fades, a 256-entry cache of 2-second PCM
    windows, forward and reverse, prefetch, and a meter. **This app has no scrub audio**, and it
    is the thing that makes finding a word in a recording fast. A real gap, and a large one.
  * **`Audio/AudioSyncCorrelator`** (318 lines) — aligning two recordings by correlating their
    envelopes, with a pyramid search for large lag ranges and a consensus across five 60-second
    chunks that must agree within a second. Its constants carry knowledge worth having: recorder
    crystals disagree by *tens of ppm*, so a fitted drift slope above 500 ppm means mismatched
    content rather than drift; and below about 2.5 minutes of span the slope is dominated by hop
    quantisation.

    **Not needed here**, and knowing why is the point: that machinery exists because two
    independent recorders drift apart. This app's camera and screen are written by one process on
    one machine, and the recorder measures the offset directly.
  * `Compositing/ColorScopes`, `ColorWheels`, `LUTLoader` — colour grading, which is a different
    product.

**The correction.** `FinalCutXML` said the camera could not be carried because its offset from the
screen was unknown. It is not unknown — `cameraStartOffsetNanos = cameraStart - screenStart`, from
the two recordings' own first-frame instants, and the preview has been compositing with it since
the camera shipped. The camera is on a connected lane now.

### A systematic read of the reference projects, and what it turned up

**2026-08-30.** Everything before this was read reactively — a project opened when something went
wrong. That is how an Electron recorder's fifth line went unread for weeks while the cursor drew as an arrow.
So the five recorders were read by SUBSYSTEM instead: 6.4 million lines across the folder, 770,000
in the recorders, mapped at module level and then read where the map showed something this app has
no equivalent of.

**What the map shows.** a Rust recorder has 46 crates including `automation`, `flags`, `output_validation`,
`timestamp/master_clock`, `frame-converter`, `gpu-converters`, `rendering-skia`, `cursor-info`.
a Swift recorder has `Analysis` and `Generators`. a native editor has `Agent`, `Generation`, `Search`,
`Telemetry`. an Electron recorder keeps written `docs/architecture` and `docs/engineering`. an Electron recorder has
`gpuSwitches`, `mediaServer`, `navigationPolicy`, `permissionPolicy`.

**Findings, ranked by what they would change here:**

| | Finding | State |
|---|---|---|
| 1 | **Validating the output file after a recording stops** (a Rust recorder `output_validation.rs`) | had nothing — **now built** |
| 2 | `VNGenerateImageFeaturePrintRequest` — perceptual frame similarity (a Swift recorder) | not used here |
| 3 | `VNGenerateOpticalFlowRequest` — real per-pixel motion (a Swift recorder) | not used here |
| 4 | `VNGenerateAttentionBasedSaliencyImageRequest` — where a viewer looks (a Swift recorder) | not used here |
| 5 | Spring-integrating the zoom's 0/1 `activity` channel (a Rust recorder `zoom_spring.rs`) | **not needed — ours is better** |

**On (5), checked rather than assumed.** a Rust recorder integrates a third spring channel because their
camera's shrink-during-zoom is driven by a binary "any zoom active", and a step there would pop.
This app's camera shrink is `scaleDuringZoom + (1 - scaleDuringZoom) / zoom` — a continuous
function of the live, already-smoothed zoom value. Same smoothness, one fewer channel.

**On (2) to (4), and this is the one worth returning to.** The phone auto-zoom was removed here
after measuring that pixel-change targeting was wrong, and two of the three reasons were
structural: transitions dominate the change signal, and the UI animates on its own. Optical flow
answers both — a transition is *coherent* flow across the whole frame, which is precisely what a
scroll/transition detector rejects — and saliency answers "where should this be framed" without
needing to know where the tap was. **That is a genuinely different method, not a tuning of the one
that failed.** It should not be rebuilt on this argument alone: it was removed with frame evidence
and it would have to come back with frame evidence, measured against the same iPad recording.

### The cursor was drawing as an arrow for weeks, and a comment was the reason

**2026-08-30.** Screen Studio's `auto-zoom-on-clicks` demo shows their rendered cursor becoming a
**pointing hand** over a menu item and a **crosshair** over a spreadsheet cell. This app records a
shape per pointer sample and draws six of them — and drew an arrow every time.

`SystemCursorShape.sampleOnMainActor` returned `.other` unconditionally, on the strength of a
comment that said the class cursors could not be compared against: *"those class images are 0×0
and their `tiffRepresentation` is `nil` … no comparison could ever succeed"*.

**That measurement was real and was taken in the wrong place.** AppKit populates the class cursors'
images when the application object is created, and in a bare command-line binary — which is what
the original measurement ran in — `NSCursor.arrow.image` really is 0×0.

`an Electron recorder-main/electron/native/SystemCursorAssets.swift` says so **on its fifth line**:

    // Force AppKit initialization so all system cursor images are populated
    let _ = NSApplication.shared

Re-measured inside an application, all seventeen class cursors have real images and distinct
digests. `arrow` is 28x40 / 583,248 bytes; `iBeam` 23x22 / 263,952; `pointingHand` 32x32 / 20,892;
`crosshair` 24x24 / 11,932. Size alone cannot discriminate — `pointingHand`, `openHand` and
`closedHand` are all 32x32 with the same byte count, and four arrow variants are all 28x40 with
the same — but the digests are distinct.

**The table is built from the running system, not written down.** a Rust recorder keeps two literal digest
tables, one for macOS 26 and one for everything before, because the artwork changed; a literal
table is a fact about an OS version pinned inside an application and it goes stale silently. Asking
the system means a macOS that redraws its cursors changes both sides of the comparison at once.

The measured digests match a Rust recorder's macOS 26 table exactly, which is as close to a second opinion as
this can get.

**The lesson is bigger than the feature.** A measurement taken in the wrong context became a
comment, and the comment became a wall. The rule this project already had — measure with the app's
own conditions — was written for compiler flags; it applies to frameworks too.

### What Screen Studio's own demo videos show, frame by frame

**2026-08-30.** Fourteen of their marketing videos, read as evidence rather than as advertising.
Most are OUTPUT — what their look produces — but three (`cut-and-speed-up`, `crop`,
`horizontal-and-vertical-output`) were recorded inside the editor and show the interface.

What their editor has:

  * **Timeline.** Amber clip blocks labelled inline with duration and speed (`7s 2x`); a purple
    Zoom lane below, labelled with magnification and whether it is automatic (`2x Auto`); amber
    scissors markers at every cut; a timeline zoom slider in the toolbar.
  * **Toolbar.** An aspect dropdown — `Auto`, `Wide 16:9`, `Vertical 9:16`, `Square 1:1`,
    `Classic 4:3`, `Tall 3:4` — plus Crop, transport, and a red scissors that cuts at the playhead.
  * **Crop** is a mode with drag handles on the preview and an explicit `Confirm` / `Reset crop`.
  * **Background inspector**, four tabs: `Wallpaper | Gradient | Color | Image`, a grid of ~18
    gradients credited to raycast.com, a **Background blur** slider, and Shape → Padding.

Checked one at a time against this app rather than assumed. Already here: clip labels with
duration and speed, a zoom lane, aspect variants, crop handles on the preview with a Reset,
gradient presets. **Genuinely missing: the background blur, and a way to pick a flat colour.**
Both are now built.

The blur is the one worth having. A desktop picture has a horizon, a face, a logo, and all of it
competes with the recording on top of it; blurred, the same picture keeps its colours and its
light and stops being a picture. It is expressed as a fraction of the frame's width rather than a
pixel count, so the slider means the same thing for a 720p export and a 4K one — a style that
looked different depending on what it was exported as would be worse than no style.

Two things still absent and worth noting rather than building blind: a **timeline zoom slider**,
and their `Tall 3:4` / `Classic 4:3` aspect rungs.

### Transparent export: two codecs carry it, and they are 107x apart

**2026-08-29.** Found by researching complaints rather than feature pages. Screen Studio's
reviewers name three gaps for product demos and app showcases — "device frames, transparent
export, and Simulator recording" — and two of the three are now closed here.

A transparent background is a property of the picture; whether it survives is a property of the
codec, and **nothing connects the two**. That is what makes this feature dangerous rather than
merely missing: `AVAssetWriter` accepts a transparent frame for H.264 without a word, encodes the
alpha away, and returns a file with a black rectangle where somebody asked for nothing. They find
out when they drop it onto a landing page.

Measured, one codec at a time, by writing a frame that is opaque on one half and fully transparent
on the other and reading the alpha back out of the file:

    ProRes 4444        left 255  right   0    carries it
    HEVC with Alpha    left 255  right   0    carries it
    ProRes 422         left 255  right 255    silently opaque
    HEVC               left 255  right 255    silently opaque

And the size, on sixty frames of 640x360 with a detailed card and a transparent margin:

    HEVC                    130,405 bytes   (no transparency)
    HEVC with Alpha         135,432 bytes   transparency for +3.9%
    ProRes 422            8,633,497 bytes   (no transparency)
    ProRes 4444          14,563,749 bytes   107x the HEVC-with-alpha file

**Every article on transparent video names ProRes 4444.** It is 107 times larger for the same
picture. HEVC with Alpha is offered first for that reason, and ProRes 4444 stays on the list
because an editor asking for ProRes is asking for ProRes.

Two more things that only measuring shows:

  * **HEVC with Alpha is `.mov` only.** `AVAssetWriter.canAdd(_:)` returns false for it in an MP4
    container — not a preference, the one container that works.
  * **It must not be given a profile.** The alpha is a second layer and `Main` describes only the
    first; the codec-probe helper keyed its profile on "takes a bit rate", which is true here, and
    would have handed an HEVC-alpha encoder an H.264 profile.

`ExportCodec.carriesTransparency` is a table because the export sheet has to narrow its format
list the instant somebody picks a transparent background. A table is a claim about hardware
written down somewhere else, so `CodecSupport.keepsTransparency` asks this machine and a test
compares the two — the day an OS changes what a codec carries, it is a red check rather than
somebody's landing page.

### Camera background removal: Vision beats the model everyone bundles

**2026-08-29.** Cutting the room out from behind a webcam — the one thing in this comparison that
people ask for by name and that this app did not have. Motionik ships it. Screen Studio does not.
Of the five open-source recorders beside this repo, exactly one does: **a Rust recorder**.

**a Rust recorder's approach, read line by line** (`crates/camera-effects`): MediaPipe's
`selfie_segmentation.onnx`, bundled as bytes, run through ONNX Runtime with the CoreML execution
provider, hunting `libonnxruntime.dylib` at three candidate paths on start-up. Model input:
**256x256**. They need it because a Rust recorder runs on Windows and Linux too.

**What ships here:** `VNGeneratePersonSegmentationRequest`. Measured on this machine:

    quality    per frame     mask         verdict
    fast        7.85 ms     256 x 192     under-sampled at any realistic card width — not offered
    balanced   21.32 ms     512 x 384     the default
    accurate   55.90 ms    2016 x 1512    earned only by a camera wider than 512 output px

So the platform framework gives a **higher-resolution mask than the model a Rust recorder bundles a whole
runtime for**, with no dependency, no model file and no per-platform dylib. On macOS the
dependency-free option is also the better one.

Three measurements changed the code:

  * **Mask size does not depend on input size.** 1280x720 and 640x360 both produce 512x384 and
    both take 21 ms. Downscaling before segmenting — the obvious optimisation — saves nothing.
  * **The mask does not preserve the input's aspect.** 1920x1080 gives 512x384; so does a square
    1000x1000. Only portrait flips it. It must be stretched over the whole extent with X and Y
    scaled *independently*; matching the aspect would put the silhouette a fifth of a frame off
    the person, silently.
  * **The first request of each level costs 1–2 seconds** loading the model. Warmed when the
    switch is turned on, not on the frame somebody is waiting for.

**Two of a Rust recorder's techniques were worth taking, and measuring killed both:**

`refine_mask_value` applies a sigmoid at contrast 4 to harden a mushy boundary. Plotted against a
0-to-255 ramp, that curve gives `0 -> 30` and `255 -> 225` — it never saturates, so it
*compresses* the mask rather than sharpening it, leaving background 12% opaque and the person 12%
transparent. Sound for MediaPipe's soft 256x256 output; unnecessary for Vision's, which is
decisive — a frame with nobody in it peaks at 2 to 5 out of 255, not at 128.

`smooth_mask_value` is a temporal EMA across frames (growth 0.25, shrink 0.12, stability band
0.025) that kills edge shimmer. Right for a Rust recorder and wrong here: a Rust recorder segments a **live** camera where
frames arrive in order, while this renders a timeline that is scrubbed, seeked and exported out of
order. An EMA would make a frame's appearance depend on how somebody arrived at it — different in
the preview than in the export, and different again on a second export. The cost of refusing it is
stated rather than hidden: the silhouette can shimmer slightly, and the deterministic fix if that
proves visible is a fixed window around the frame's own position, at 63 ms a frame.

**What is deliberately NOT built:** background *blur*. macOS ships Portrait mode, `CameraEffects`
already puts it one click away, and it runs inside the camera pipeline for free. A hand-written
blur would be slower and worse. The interface says so where somebody would look for it.

### Hiding macOS furniture: exclude it from the capture, do not change the Mac

**2026-08-29.** Two switches that sound alike and are built completely differently, because
measuring the obvious mechanism killed it.

**Hiding the Dock.** Every recipe online says `defaults write com.apple.dock autohide -bool true`.
Measured, that alone does **nothing** — the Dock does not watch the key. `NSScreen.main`'s usable
height was 105 pt short of the full frame before the write, after it, and after writing it back:
three identical readings. So the pref route needs the Dock killed and relaunched too.
`System Events`' `set autohide of dock preferences` *does* work live, with the Dock's pid
unchanged — but it needs an Apple Events grant, a second permission dialog, and it persists into
`com.apple.dock` anyway, so it still owes a restore.

Both of those change somebody's Mac in order to change a video. What ships instead is a
**capture-filter exclusion**: the Dock is left out of the picture and nothing on the machine
moves. The person can still click their Dock while recording; it is simply not in the file. No
preference, no killed process, no permission, and no state a crash can strand.

The trap, found by looking rather than reasoning: `com.apple.dock` owns **eleven** windows, and
five of them are titled `Wallpaper-<UUID>` — **the desktop picture is drawn by the Dock process**.
Excluding the application outright would risk taking the wallpaper with it. Exactly one window is
the Dock (`kCGDockWindowLevel`, 20); the wallpapers sit at -2147483624 and four full-screen
backdrops at -2147483622. So the application is excluded and every window of it except that one
is named in `exceptingWindows`. Both variants were shot and compared: Dock gone, wallpaper intact.

**Hiding the menu bar** is the easiest of the three and the only one with a documented API for
it: `SCContentFilter.includeMenuBar`. Measured, it takes the menu bar's **twelve status items with
it** — the menu bar is one window at `kCGMainMenuWindowLevel` (24) titled `Menubar`, and Clock,
Battery, WiFi, Sound, Siri, NowPlaying and the rest are separate windows one level above at
`kCGStatusWindowLevel` (25), all owned by `com.apple.controlcenter`. Turning the property off
removed all thirteen, and the top of the frame comes back showing the desktop rather than a black
strip. `contentRect` is 1512x982 either way, so it hides rather than crops.

Because it is a property rather than a list, it sidesteps the constraint that shapes the Dock's
implementation entirely: `SCContentFilter` allows exactly one exclusion list and this process
already occupies it.

Worth more than tidiness: a menu bar says what time it is, how much battery is left, which network
somebody is on, and — through its extras — which applications they run. For a recording that is
going to be published, that is a row of small disclosures nobody meant to make.

**Desktop icons** still use the older, heavier mechanism — Finder's `CreateDesktop` preference
plus a Finder restart — and the same capture-filter trick was measured to work for them too
(Finder's one window at -2147483603; the icon visible in the control shot is gone and the
wallpaper survives). It is not adopted yet because `SCContentFilter` allows one exclusion list and
this app must be on it at application granularity, so excluding Finder's desktop window means
excluding Finder — and a Finder window opened mid-recording would then vanish from the video.
Worth doing; needs the filter re-resolved as windows appear.

**Nobody else in the comparison set does either.** Screen Studio hides desktop icons; the five
open-source recorders beside this repo hide neither.

### Automatic zoom on a phone: built, measured, removed

**2026-08-29.** A pass that derived zooms from what CHANGES on screen shipped and was taken out
again the same day. The reason is worth more than the code was.

The method rests on "change means intent". On a phone that is false, and three frames from a real
iPad recording show how:

    3.09s   the target landed on a music widget on the home screen — animating by itself
    6.07s   on a promotional banner, mid-transition into another app
    8.42s   on empty space, while a sidebar slid in from the left

Three detections, three wrong. And wrong structurally rather than by a margin a threshold could
close:

  * **Transitions dominate.** Every navigation animates the whole screen, and the animation is
    always a larger change than the tap that caused it.
  * **The UI animates on its own.** Widgets, banners, badges, sidebars.
  * **The tap comes BEFORE the change.** By the time the change is at its largest, the finger has
    moved on and the screen is showing somewhere else.

Several honest attempts were made first — a peak-relative threshold instead of an average, a
fixed target instead of a bounding box, rejecting frame-wide changes as transitions, grouping
frames into bursts and framing from the clearest one. Each was a real improvement to a method
that cannot work.

Screen Studio, with far more resources, reached the same conclusion and says so publicly:
"automatic zooms are not supported" for iOS recordings. **Nobody has this feature**, and the
reason is not that nobody tried.

**What does work is their suggestion**: pair a Bluetooth mouse to the iPad. A real cursor then
appears in the recording, and everything that follows a cursor has something to follow.

A wrong zoom costs somebody a deletion; a missing zoom costs nothing. That asymmetry is what
settled it.

## 4. Where this project already leads

Not a boast — a list of things that would be lost if a feature were reworked without
knowing they were there.

1. **The camera moves out of the cursor's way** (`CameraDodge`). Screen Studio only
   *shrinks* the camera during a zoom. Nobody moves it to another corner.
2. **Music ducks under speech** (`MusicDucking`). Others offer a music track; none
   published automatic ducking.
3. **Automatic silence removal** (`SilenceFinder`).
4. **Cursor tilt while moving.**
5. **Window-follow capture** — the recording tracks a window that is moved or resized.
6. **Speed applies to audio too.** Easy to ship as video-only; this one calls
   `scaleTimeRange` on both tracks (`EditedAsset.swift:53,67`).
7. **Everything is local.** No account, no upload, no queue that can fail — which is
   the failure mode ScreenKite's entire blog is built on attacking in others.

---

## 5. The ranked gap list

Ordered by (value to a real workflow) ÷ (cost), with the reasoning stated so it can
be argued with.

| Rank | Gap | Why it ranks here | Cost |
|---|---|---|---|
| 1 | **In/out range export** | ScreenKite markets a whole article on Screen Studio *not* having it. `EditTimeline` already owns every coordinate transform (`sourceTime(atOutput:)`, `outputTime(atSource:)`, `survival(ofSource:)`), and the Mark track already exists to hang "export this marker" on. | Low |
| 2 | **Hide desktop icons** | One `defaults write com.apple.finder CreateDesktop` + `killall Finder`, but it mutates the user's machine and must be restored — the cost is entirely in doing that safely. | Low |
| 3 | **Saveable style presets** | `ProjectSnapshot` already encodes the whole style. Screen Studio sells this. | Low |
| 4 | **Noise suppression** | Every competitor but a Rust recorder and ScreenKite has it. Genuinely a capture-architecture decision: `AVAudioUnitEQ`/`AUVoiceProcessing` at capture time changes what is recorded; an offline pass keeps the master clean. | Medium |
| 5 | **iPhone / iPad capture** | Screen Studio, Motionik and ScreenKite all ship it, and it opens mobile-app demos as a use case. No reference to read. | Medium–High |
| ~~6~~ | ~~**Device frames**~~ | **Done 2026-08-29.** Drawn as proportions rather than artwork: a rounded body a known fraction larger than the screen, with the screen's own corner radius — no bundled images and nothing to go stale in September. No notch or island, because an iOS recording already contains whatever the system drew there. | ~~Medium~~ |
| ~~7~~ | ~~**Transcript-based editing**~~ | **Done.** Deleting a sentence cuts its span; as of 2026-08-29 individual words can be chosen and cut too. The row above was stale — it described the state before `TranscriptPanel` shipped, which is what a gap list does when it is not re-read. | ~~Medium~~ |
| 8 | **FCPXML export** | a native editor has a readable implementation. Turns this from a closed tool into one that hands off. | Medium |
| 9 | **Screenshot mode** | a Rust recorder and Motionik both treat it as a third pillar. It is a second product inside the app. | High |
| 10 | **Scene-based recording + retakes** | Borumi's entire thesis. Would restructure the capture tier. | High |

**Added 2026-08-29, from user research rather than from this list.** Reading what people
actually complain about turned up one named Screen Studio gap that this app did not fill —
"missing device frames, transparent export, and Simulator recording", written about product demos
and app showcases. Device frames shipped the same day; **transparent export** is now here, and it
was not on the ranked list at all because the list was built from competitors' feature pages
rather than from their reviews. Worth remembering: a gap list assembled from what rivals *sell*
misses what their users say is *missing*.

**Declined, on purpose:** share links, cloud storage, viewer analytics, team
workspaces, AI titles/summaries. All require sending a recording to a server.

---

## 6. Details worth keeping from ScreenKite's writing

Their blog is a competitive-attack channel, so the *claims about rivals* are
advertising. The *shapes of the problems* are still real and worth knowing:

- **Range export as a workflow, not a button.** Their sequence is: mark a coloured
  block on a marker track → right-click → "Export Range…" → the in/out is preset from
  the block. The insight is that a marker and an export range are the same object
  seen twice. Worth copying as a shape.
- **They read `.screenstudio` project files** to import rivals' projects. An import
  path is a real acquisition channel and costs a decoder.
- **On-device vs cloud transcription split by hardware** — WhisperKit on Apple
  Silicon, cloud on Intel. This repo's floor is macOS 26, so the split does not arise.
- **The export-speed claim (≈3×)** is against Electron pipelines. Not a claim about
  a native Metal compositor, which is what this project already is.

---

## 7. How to use this document

When picking the next feature, the question is not "what is missing" — §2 answers
that and the list is long. The question is which row moves a real recording session
forward. §5 is that argument, and it is meant to be disagreed with in writing rather
than replaced silently.
