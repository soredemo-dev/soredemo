# Notice

Soredemo — Copyright © 2026 Soredemo.

Soredemo is free software under the **MIT License** (`LICENSE`). This file records what in this
tree came from somewhere else.

---

## Derived work

Five macOS screen recorders were read closely while this was built. **Every entry below is "read
for approach": the design or the insight came from elsewhere and the code was written here.**
Nothing in this tree is a port.

Ideas are credited because that is right, not because a licence compels it — copyright attaches to
expression, and none of the expression below is anyone else's.

| From | Licence | What | How |
| --- | --- | --- | --- |
| [a native editor](https://github.com/a native editor/a native editor) | GPL-3.0 | The shape of a waveform envelope: mono float32, a fixed slice rate with a total cap, `vDSP_maxmgv` per hop, a −50 dB floor | `Sources/Compositing/WaveformEnvelope.swift` is written here; the rate and floor are theirs. The orientation is deliberately reversed and the file says why. |
| [a native editor](https://github.com/a native editor/a native editor) | GPL-3.0 | Sticky snapping with a hold threshold, an easier reach for the playhead than for a clip edge, and one probe per edge of the thing being dragged | `Sources/Timeline/SnapEngine.swift` is written from the behaviour `SnapEngineTests` pins. The idea is theirs; the 1.5 multipliers are numbers, and the file argues for them rather than citing them. |
| [a native editor](https://github.com/a native editor/a native editor) | GPL-3.0 | An export queue: FIFO, one running, cancel per job, and a destination reservation so two exports cannot race for one file | `Soredemo/UI/ExportQueue.swift`. Their `destinationInUse` names the file in the refusal, which is the only way somebody works out which of their jobs collided. |
| [a Swift recorder](https://github.com/a Swift recorder) | Apache-2.0 | Sampling the pointer on a fixed cadence rather than from an event tap | `Sources/Capture/PointerSampler.swift` was written from scratch; the insight that a tap reports motion and a still pointer produces none is theirs. |
| [a Swift recorder](https://github.com/a Swift recorder) | Apache-2.0 | Refreshing the device list on `AVCaptureDevice.wasConnected`/`wasDisconnected` rather than only when a menu opens | Applied in `MenuBarRecorder`; a device missing from a list reads as one the app cannot see. |
| [an Electron recorder](https://github.com/an Electron recorder) & [an Electron recorder](https://github.com/an Electron recorder) | AGPL-3.0 / MIT | The conditions a window capture has to handle: `desktopIndependentWindow`, `ignoreShadowsSingleWindow`, `excludesCurrentProcessAudio`, an explicit 48 kHz/stereo, a deeper `queueDepth`, a host display found by centre THEN overlap, and even buffer edges | Each condition is applied in `CaptureSource`/`CaptureSession` with its own reason written at the site — several are things both projects set without saying why. |
| [an Electron recorder](https://github.com/an Electron recorder) & [an Electron recorder](https://github.com/an Electron recorder) | MIT / AGPL-3.0 | Naming the microphone with `microphoneCaptureDeviceID`, and probing `responds(to:)` for the capture selectors instead of gating on an OS version | `MicrophoneSource`/`MicrophoneInventory` are written here; an Electron recorder's degrade-with-a-warning shape is theirs. |
| [an Electron recorder](https://github.com/an Electron recorder) & [an Electron recorder](https://github.com/an Electron recorder) | MIT / AGPL-3.0 | Stepping the export bit rate by pixel count — 10 Mbps to 720p, 20 to 1080p, 30 above | Two independent tables agreeing is the evidence; `ExportQuality` uses a Rust recorder's bits-per-pixel form instead, because a table has to be re-guessed at every new resolution. |
| [an Electron recorder](https://github.com/an Electron recorder) | AGPL-3.0 | **Chained zoom** — panning between two zoom blocks whose gap is short instead of returning to rest, at a 1350 ms threshold | `ZoomBlock.chainedPanGap` carries their measured constant rather than re-guessing it; the implementation is a change to `CameraMotion.aim`. |
| [an Electron recorder](https://github.com/an Electron recorder) | AGPL-3.0 | A floating self-view with a drag threshold and a rectangle clamped to the screen on every drag frame, and a recorded start offset between the camera and the screen | `CameraSelfView` applies the first two; `CameraComposition` aligns the camera by the offset the recorder measures. |
| [a Rust recorder](https://github.com/a Rust recorder) | AGPL-3.0 | Snapping the camera centre to its target while the zoom is still ~1, so a zoom scales straight toward its focus instead of drifting sideways | `CameraMotion.identityZoomBound` follows the same argument their `zoom_spring.rs` gives. |
| [a Rust recorder](https://github.com/a Rust recorder) | AGPL-3.0 (`cap-camera*`/`scap-*` are MIT) | Hashing the live cursor image against a table of known digests to classify it; `NSCursor.currentSystem` with a `current` fallback | a Rust recorder's implementation is Rust. `Soredemo/UI/SystemCursorShape.swift` explains why the classification is honestly `.other` here rather than pretending to a table it does not have. |
| [a Rust recorder](https://github.com/a Rust recorder) | AGPL-3.0 | A camera that is hidden rather than deleted, a preset position beside an optional manual one, and a scale applied while the stage is zoomed | `CameraOverlayStyle` carries all three; the 0.7 zoom scale is their measured value. |
| [a Rust recorder](https://github.com/a Rust recorder) | AGPL-3.0 | A remembered area-selection rectangle, validated against the displays still attached before it is offered again | `RememberedRegion` applies the same two checks plus finiteness. |
| [a Rust recorder](https://github.com/a Rust recorder) | AGPL-3.0 | Bits-per-pixel export quality with the frame rate tapered above 30, and a size estimate shown before the export | `ExportQuality` carries the 0.3 / 0.15 / 0.08 figures and the 0.6 taper as measured values. |

### Read and deliberately not used

- **a Swift recorder** states that ScreenCaptureKit cannot select a microphone device. Checked on this
  machine and no longer true, which is why Soredemo keeps one capture instead of a second
  `AVCaptureSession`. Recorded because the reasoning is the useful part.
- **a Swift recorder** offers a five-way output colour-space picker over an 8-bit sRGB pipeline, and its
  transfer function returns Rec.709 for every case including BT.2020. Four of the five change a
  label and not a pixel. See `docs/design/2026-08-24-colour-pipeline.md`.
- **an Electron recorder** and **an Electron recorder** are Electron applications, but each ships a small native Swift
  helper for ScreenCaptureKit, and those helpers are where the capture conditions above came from.
  Nothing else in either is reachable from Swift.

### Measured constants carried over

Several numbers below are other projects' measurements rather than this project's. A single
measured value is a fact; a table of them is closer to a line, and it is written down here rather
than left for somebody to find.

- an Electron recorder's 1350 ms chained-pan gap
- a Rust recorder's 0.3 / 0.15 / 0.08 bits per pixel, its 0.6 taper above 30 fps, and its 0.7 camera scale
  during zoom
- Apple's published ProRes data rates: 147 Mbps for 422 and 330 for 4444, both at 1080p29.97

**Not legal advice.** This file is what the code says. Anyone whose plans depend on the answer
should have a lawyer read it.

---

## Applying the licence to new files

Contributors do not need a per-file header: the `LICENSE` at the root covers the whole work.

**A file that ports code from another project cannot be added to this tree.** A copyleft-derived
line would make the licence at the root false. Reading another project for its approach is welcome
and is how the table above came to exist — the code has to be written here.

When something is read for approach, say so in the file's own header, name the source and its
licence, and add it to the table above **in the same commit**. The table is the record, and a
derivation that only exists in a commit message is a derivation nobody will find.
