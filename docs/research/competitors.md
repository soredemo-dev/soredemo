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
| **Automatic zoom on a PHONE recording** | **·** | · | · | · | · | **✓** `MotionActivity` *(nobody else)* |
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
| Background removal | · | · | ✓ | · | · | **·** |
| Zoom / crop / mirror the camera | · | · | ✓ | · | · | **·** |
| Full-screen camera moments | · | · | ✓ | ✓ | · | **·** |

### Editing

| Capability | Screen Studio | a Rust recorder | Motionik | Borumi | ScreenKite | **Soredemo** |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
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
| Voice volume normalisation | ✓ | · | · | · | · | **·** |
| **Background noise removal** | ✓ | · | ✓ | ✓ | · | **✓** `NoiseReduction` |
| Transcript generation | ✓ *(on-device)* | ✓ *(cloud)* | ✓ | ✓ | ✓ *(WhisperKit on-device; ElevenLabs cloud on Intel)* | **✓** `Transcript` |
| Burned-in captions | ✓ | ✓ | ✓ | ✓ | ✓ word-level | **✓** `CaptionStyle` |
| Subtitle file export | ? | ✓ | · | · | ✓ | **✓** `SubtitleFile` |
| AI titles / summaries / chapters | · | ✓ | · | · | ✓ | **·** ↺ *(would require upload)* |
| Agentic editing (Claude Code / Codex / Gemini) | · | · | · | · | ✓ | **·** |

### Export and sharing

| Capability | Screen Studio | a Rust recorder | Motionik | Borumi | ScreenKite | **Soredemo** |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| MP4 up to 4K 60 | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** |
| GIF | ✓ | · | ✓ | · | · | **✓** `GIFExporter` |
| Export presets (web / social / editor) | ✓ | · | ✓ | · | ✓ | **✓** `.web` `.message` `.editing` |
| Copy video to clipboard | ✓ | · | · | · | · | **✓** `ExportQueue` |
| **Export an in/out range only** | **·** | · | · | · | ✓ | **✓** `EditTimeline.restricted` |
| FCPXML / hand-off to a real NLE | · | · | · | · | ✓ | **·** |
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
| 7 | **Transcript-based editing** | The transcript exists; deleting a line does not yet cut the video. Borumi and ScreenKite both lead with it. | Medium |
| 8 | **FCPXML export** | a native editor has a readable implementation. Turns this from a closed tool into one that hands off. | Medium |
| 9 | **Screenshot mode** | a Rust recorder and Motionik both treat it as a third pillar. It is a second product inside the app. | High |
| 10 | **Scene-based recording + retakes** | Borumi's entire thesis. Would restructure the capture tier. | High |

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
