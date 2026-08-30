# Taking the room out

*Code: `Core/Sources/Overlays/NoiseReduction.swift`. Moved out of that file's header
2026-08-30 — it had four section headings, which is a document written in the wrong place.*

**Takes the room out of a recording, using the silences this app already knows how to find.**

A demo recorded in an ordinary room carries the room: a fan, a laptop under load, the hum of a
building's air handling. It is quiet enough to ignore while recording and loud enough to hear
on playback, and it is the single most common reason a good take sounds amateur.

### Why this is written here rather than taken from a package

Apple ships nothing usable. Measured, in this order:

  * `AVAudioInputNode.setVoiceProcessingEnabled(true)` is **refused in manual-rendering
    mode** — `-10863` — and enabled only on a live device-rendering engine. An offline pass is
    manual rendering by definition.
  * The microphone arrives through **ScreenCaptureKit** (`captureMicrophone = true`), not
    through `AVCaptureSession` or `AVAudioEngine`, so there is no graph to insert an audio
    unit into even if one were allowed.
  * `AVCaptureDevice`'s `voiceIsolation` microphone mode is a **system** setting. An app may
    read it and may ask macOS to show the picker; it may not set it.

The obvious package — `soniqo/speech-swift` — was resolved
and measured rather than trusted. Its own page says the CoreML backend needs no MLX; its
manifest says `SpeechEnhancement` depends on `MLX` and `MLXNN` unconditionally, and resolving
it pulled **39 transitive packages** including an HTTP server framework, the whole NIO stack,
TLS, WhisperKit and a HuggingFace downloader. It also fails this package's own build:
`ARCHITECTURE.md` D6 rule 4 forbids any package dependency, because a dependency is the back
door around rule 1's import allow-list — and MLX plus an HTTP server is exactly what would
have come through it.

### What this does, and what it cannot

Spectral subtraction. The recording is cut into overlapping windows; each is transformed;
an estimate of the noise's magnitude is subtracted from each bin; the phase is kept; the
windows are added back together.

**It removes STATIONARY noise — sound that is there the whole time and does not change
much.** Fans, hum, hiss, air conditioning. It does **not** remove a door slamming, a keyboard,
a cough, or someone talking in the next room: those are not in the profile, so they are not
subtracted, and a system that claimed otherwise would be lying about what it measured. This is
the honest limit of doing it without a trained model, and it is stated here rather than
discovered by somebody whose dog barked.

### The profile comes from measured silence, not from the first half-second

The usual shortcut is to assume the first 500 ms is noise. It very often is not — people start
talking immediately, and the countdown means the first moment of a Soredemo recording is
whatever was on screen when they pressed record.

This app already knows where the quiet is: `SilenceFinder` finds it, for the feature that cuts
dead air. The same spans are the right place to measure a room, and they are spread across the
whole recording rather than concentrated at one end — so a fan that starts up halfway through
is still in the estimate.

**A recording with no measurable silence gets no profile and no processing**, and says so with
a `nil` rather than inventing a noise estimate from speech and subtracting it — which is how
this kind of code makes a voice sound like a robot.

### Deterministic, and therefore in the pure tier

No clock, no randomness, no platform framework — D6 rule 3 and rule 1. The transform is
written out below rather than taken from Accelerate, because `Overlays` imports Foundation
only and because a transform that can be read is a transform that can be checked against a
direct DFT, which `NoiseReductionTests` does.
