# What the market ships, and what this does not

*Researched 2026-08-30. Sources are each product's own changelog, feature page or
release notes; where a claim came from a review rather than the vendor it says so.*

The five reference implementations read from source are covered by
`2026-08-23-five-project-feature-sweep.md`. This document covers the five
**commercial** products a person choosing a screen recorder in August 2026
actually compares — which is a different question, because a shipped product's
feature list is a claim about what a person will expect to find.

Legend: ● shipped, ◐ partial, ○ absent, — not applicable.

## Recording

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| macOS native | ● | ● | ● | ● | ● | ● |
| Windows | ○ | ● | ● | ● | ○ | ○ |
| Web | ○ | ○ | ● | ○ | ○ | ○ |
| Region / area capture | ● | ● | ● | ● | ● | ○ |
| Window capture | ● | ● | ● | ● | ● | ● |
| iPhone / iPad capture | ● | ● | ◐ | ○ | ◐ | ● |
| Webcam capture | ● | ● | ● | ● | ● | ● |
| System audio | ● | ● | ● | ● | ● | ◐ *(recorded, no toggle)* |
| Microphone selection | ● | ● | ● | ● | ● | ● |
| Pause / resume | ● | ● | ● | ● | ● | ● |
| Multiple takes per scene | ○ | ○ | ● | ○ | ○ | ○ |
| Teleprompter | ● | ○ | ○ | ○ | ○ | ○ |
| Screenshot mode | ● | ○ | ○ | ● | ○ | ○ |

## Cursor

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Smoothed path | ● | ● | ● | ● | ● | ● |
| Size / scale | ● | ● | ● | ● | ● | ● |
| Click ripple | ● | ● | ● | ● | ● | ● |
| Motion blur | ○ | ● | ○ | ● | ○ | ● |
| Hide when idle | ● | ○ | ○ | ○ | ○ | ○ |
| Shape follows the target under it | ● | ○ | ○ | ○ | ○ | ● |
| **Kinetic — points toward the next click** | ○ | ○ | ○ | ● | ○ | **○** |
| **Elevation — always above overlays** | ○ | ○ | ○ | ● | ○ | **○** |

## Framing and the stage

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Auto zoom on clicks | ● | ● | ● | ◐ | ● | ● |
| Manual zoom keyframes | ● | ● | ● | ● | ● | ● |
| Wallpaper / gradient / solid | ● | ● | ● | ● | ● | ● |
| Padding, radius, shadow | ● | ● | ● | ● | ● | ● |
| Crop | ● | ● | ● | ● | ● | ● |
| Aspect presets per platform | ● | ● | ● | ● | ● | ● |
| Built-in scene layouts | ○ | ○ | ● | ● | ○ | ○ |
| Green screen / background removal | ○ | ○ | ○ | ● | ● | ◐ *(camera only)* |

## Sound

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Noise removal | ◐ | ● | ◐ | ● | ● *(on-device)* | ● *(on-device)* |
| Loudness normalisation | ◐ | ● | ○ | ◐ | ◐ | ● |
| Silence removal | ● | ○ | ○ | ◐ | ● | ● |
| Music bed with ducking | ○ | ● | ● | ● | ○ | ● |
| Per-track placement | ◐ | ● | ● | ● | ● | ● |
| Scrub audio | ● | ○ | ○ | ● | ○ | ● |

## Text on the picture

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Transcription | ● | ● | ● | ● | ● | ● |
| Captions burnt in | ● | ● | ● | ● | ● | ● |
| Edit the video by editing text | ○ | ○ | ○ | ● | ◐ | ● |
| Karaoke-style captions | ○ | ● | ○ | ● | ○ | ○ |
| Keystroke overlay | ● | ○ | ○ | ○ | ● | ● |
| Annotations / shapes | ○ | ● | ● | ● | ● | ● |
| **Freehand sketch** | ○ | ○ | ○ | ● | ● | **○** |
| Redaction / blur a region | ○ | ● | ○ | ● | ○ | ● |

## Cutting

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Timeline with clips | ● | ● | ● | ● | ● | ● |
| Speed / time remap | ● | ● | ● | ● | ● | ● |
| **Transitions between clips** | ● | ● | ● | ● | ● | **○** |
| Remove dead air (picture) | ○ | ○ | ○ | ○ | ○ | ● |
| Remove silence (sound) | ● | ○ | ○ | ◐ | ● | ● |
| Export a range | ● | ● | ● | ● | ● | ● |

## Out

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| MP4 / H.264 | ● | ● | ● | ● | ● | ● |
| 4K 60 | ● | ● | ● | ● | ● | ● |
| GIF | ● | ● | ● | ● | ● | ○ |
| Transparent video | ○ | ○ | ○ | ● *(WebM)* | ○ | ● *(HEVC/ProRes)* |
| Hand off to a real NLE | ○ | ○ | ○ | ◐ | ○ | ● *(FCPXML)* |
| Export progress with an ETA | ● | ● | ● | ● | ● | ● |
| **Share link / cloud** | ● | ● | ● | ● | ◐ | **○ — by design** |

## What this reading changes

**Three gaps worth taking seriously.**

*Region capture* is on every one of the five. It is the only recording-side
capability that is universal and absent here, and the machinery is present —
`SCStreamConfiguration.sourceRect` is already set for window capture, so a
region is the same code with a rectangle a person drew.

*Transitions* are on all five. A cut with no transition is a defensible default
and an editor that cannot make one at all is a missing feature, not a stance.

*A system-audio toggle.* Soredemo records system audio unconditionally. Every
product here lets a person turn it off, and the reason is not preference: a
person recording a call, or a screen with a notification sound, needs it off
before they record, not muted afterwards.

**Two ideas nobody else has that are worth keeping.** Removing dead air from the
*picture* appears on none of the five — every product that trims does it from the
sound. And handing the edit to Final Cut as FCPXML is the only escape hatch in
the list; everything else is a closed pipeline ending in an upload.

**One idea from Camtasia worth stealing.** *Kinetic cursor* — the cursor points
toward where it is about to click. It is a real reading aid rather than a
flourish, and the data it needs is already recorded: `AXObserver` writes the
click chain, so the next click's position is known at render time. `Cursor
elevation` — the cursor always drawn above annotations — is the same shape and
one line of z-order.

**The one row where being different is the product.** Share links and cloud
storage are on every product here. Soredemo has none and will have none: nothing
this app produces leaves the machine without a person sending it. That row is
not a gap.
