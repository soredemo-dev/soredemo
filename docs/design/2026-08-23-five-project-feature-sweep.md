# What the five reference recorders have, and what Soredemo does not

Read across `../opensource/Screen Record Opensource/` — a Rust recorder, an Electron recorder, an Electron recorder,
a Swift recorder, a native editor — by enumerating the surfaces that list features: settings
panels, inspector tabs, export options, tray menus, and the editor's own component
directories. A panel's label list is a better inventory than a README, because a
label exists only if something behind it works.

Legend: ● shipped, ◐ partial, ○ absent.

## Recording

| | a Rust recorder | an Electron recorder | an Electron recorder | a Swift recorder | a native editor | **Soredemo** |
|---|---|---|---|---|---|---|
| Menu bar item | ● | ● | ● | ○ | ○ | ● |
| Floating control bar | ● | ● | ● | ● | — | ● |
| Countdown before start | ● | ● | ● | ● | — | ● |
| Microphone selection | ● | ● | ● | ● | — | ● |
| System-audio toggle | ● | ● | ● | ● | — | ○ *(reason recorded in `MenuBarRecorderPanel.microphoneRow`)* |
| Global start/stop hotkey | ● | ● | ● | ● | — | ● |
| Pause / resume | ● | ● | ● | ● | — | ● |
| **Webcam overlay** | ● | ● | ● | ○ | ● | **○** |
| **Region / area capture** | ● | ● | ● | ○ | — | **○** |
| Screenshot mode | ● | ○ | ○ | ○ | — | ○ |
| Teleprompter | ● | ○ | ○ | ○ | — | ○ |

## The stage's look

| | a Rust recorder | an Electron recorder | an Electron recorder | a Swift recorder | a native editor | **Soredemo** |
|---|---|---|---|---|---|---|
| Solid background | ● | ● | ● | ● | ● | ● |
| Gradient background | ● | ● | ● | ● | ● | ● |
| **Image / wallpaper background** | ● | ● | ● | ● | ● | **○** |
| Padding, corner radius, shadow | ● | ● | ● | ● | ● | ● |
| Aspect variants | ● | ● | ● | ● | ● | ● |
| **Crop** | ● | ● | ● | ○ | ● | **○** |

## Cursor

| | an Electron recorder | an Electron recorder | a Swift recorder | **Soredemo** |
|---|---|---|---|---|
| Smoothing | ● spring | ● | ● presets: Subtle/Smooth/Snappy/Heavy | ◐ linear interpolation, no control |
| **Cursor size** | ● | ● | ● `Cursor Scale` | **○** |
| Click effect | ● ripple / spotlight / none | ● | ● | ◐ ripple only, no options |
| Effect colour / size / duration / opacity | ● | ● | ○ | ○ |
| Hide the cursor | ● | ● | ● | ● |

## Zoom and camera

| | an Electron recorder | a Swift recorder | **Soredemo** |
|---|---|---|---|
| Automatic zoom on click | ● | ● | ● |
| Draggable zoom blocks | ● | ● | ● |
| **Zoom threshold / tuning** | ● | ● `Adaptive Speed` | **○** |
| **Motion blur on pan** | ● `Pan max blur`, `Pan threshold` | ○ | **○** |
| **Connect neighbouring zooms** | ● | ○ | ◐ chained pan, no control |

## Audio

| | an Electron recorder | a native editor | **Soredemo** |
|---|---|---|---|
| Per-source gain and mute | ● | ● | ● |
| Live mix while previewing | ● | ● | ● |
| Waveform per track | ● | ● | ● |
| **Normalise** | ● | ● | **○** |
| **Noise / echo removal** | ● | ● `AudioEnhancer` | **○** |
| **Volume envelope over time** | ○ | ● `AudioEnvelope` | **○** |
| **Detach audio from a clip** | ● | ● | **○** |
| Level meter | ● | ● | ◐ reads the recording, not the mix |

## Captions and text

| | an Electron recorder | an Electron recorder | a native editor | **Soredemo** |
|---|---|---|---|---|
| Generate captions | ● | ● | ● | ● |
| Edit, restyle, burn in | ● | ● | ● | ● |
| Sidecar `.srt` / `.vtt` | ○ | ○ | ○ | ● |
| **Caption presets** | ● | ● | ● gallery | **○** |
| **Word-by-word highlight** | ● | ● | ● | **○** — word timings are stored and unused |
| Text overlays | ● | ● | ● | ● |
| **Text animations** | ● fade/rise/pop/slide/typewriter | ● | ● `TextAnimator` | **○** |
| **Arrows and shapes** | ● | ● `FigureData` | ● | **○** |
| **Image annotations** | ● | ● | ● | **○** |
| Custom fonts | ● | ○ | ● | ○ |

## Clips

| | an Electron recorder | a native editor | **Soredemo** |
|---|---|---|---|
| Split, trim, delete, reorder | ● | ● | ● |
| Undo / redo | ● | ● | ● |
| **Per-clip speed** | ● | ● | **○** |
| **Dead-air removal** | ● | ● | **○** |
| Snapping with an indicator | ● | ● | ● |
| Filmstrip thumbnails | ● | ● | ● |

## Export

| | a Rust recorder | an Electron recorder | a native editor | **Soredemo** |
|---|---|---|---|---|
| MP4 | ● | ● | ● | ● |
| GIF | ● | ● | ○ | ● |
| Progress and cancel | ● | ● | ● | ● |
| **Export queue** | ○ | ○ | ● | **○** |
| **FCPXML / project interchange** | ○ | ○ | ● | **○** |

## Around the edges

| | a Rust recorder | an Electron recorder | an Electron recorder | a Swift recorder | a native editor | **Soredemo** |
|---|---|---|---|---|---|---|
| **Settings / preferences window** | ● | ● | ● | ● | ● | **○** |
| **Keyboard-shortcut help** | ● | ● | ● | ● | ● | **○** |
| **Recent projects** | ● | ● | ● | ● | ● | **○** |
| **Onboarding / tour** | ● | ● | ● | ● | ● | **○** |
| **Localisation** | ● | ● 10+ | ● | ● | ● 10+ | **○** English only |

## What this says to do next, in order

1. **Webcam overlay.** Three of five ship it and a talking head is the commonest
   demo format. It is also the largest single thing missing.
2. **Image backgrounds.** All five have them; it is the look people recognise
   from Screen Studio, and our compositor already takes a `StageBackground`.
3. **Cursor size and click-effect options.** Cheap, visible on every frame, and
   the ScreenKite thread has a user asking specifically about cursor behaviour.
4. **Text animations and word-by-word captions.** We already store the word
   timings; nothing reads them.
5. **Per-clip speed and dead-air removal.** The two edits that make a demo
   watchable.
6. **Localisation, starting with 繁體中文.** Five of five are localised and we
   are not, and this project's own user is reading Chinese.
7. Settings window, shortcut help, recent projects.
