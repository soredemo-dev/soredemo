# Notice

Soredemo — Copyright © 2026 Soredemo.

Soredemo is free software under the **MIT License** (`LICENSE`). This file records why
that licence and not another, and what in this tree came from somewhere else.

---

## Why MIT, and what it took to get here

**This tree was AGPLv3 until 2026-08-25, and the licence was not a preference — it was
a consequence.** One file, `Sources/Timeline/SnapEngine.swift`, was a structural port of
a native editor's `Timeline/SnapEngine.swift`, which is GPL-3.0. Its own header said so. A
GPLv3-derived file can be combined into an AGPLv3 work (GPLv3 §13 grants exactly that
permission) and the direction does not reverse: once such a line is in the tree, the
whole tree is copyleft.

That port is gone. `SnapEngine.swift` is now written from the behaviour
`Tests/TimelineTests/SnapEngineTests.swift` pins — the same ten tests, unchanged, all
passing, so nothing a person can observe about the app has moved. What changed is the
expression: the first version shared their two-phase control flow, their variable roles
and their accumulator shape, and this one does not.

**The idea is still theirs and is still credited**, in the table below and in the file's
own header: sticky snapping with a hold threshold, an easier reach for the playhead than
for a clip edge, and one probe per edge of the thing being dragged. Copyright attaches to
expression, not to ideas — which is why crediting the idea and re-expressing the code are
the same act rather than opposite ones.

**What is left, stated so a reader can judge it rather than trust it.** Every other entry
below is "read for approach": the design or the insight came from elsewhere and the code
was written here. Several measured constants are carried over rather than re-guessed —
an Electron recorder's 1350 ms chained-pan gap, a Rust recorder's bits-per-pixel table and its 0.7 camera scale
during zoom, Apple's published ProRes data rates. A single measured number is a fact; a
table of them is closer to a line, and that is written down here rather than left for
somebody to find.

**Not legal advice.** This section is what the code says, checked by reading both sides.
Anyone whose plans depend on the answer should have a lawyer read it.

---

## Derived work

Each entry names what was taken, from where, under what licence, and how far the
derivation goes. "Read for approach" means no code was copied. **Nothing in this tree is
a port any more** — the one entry that was is marked with what replaced it and when.

| From | Licence | What | How |
| --- | --- | --- | --- |
| [a native editor](https://github.com/a native editor/a native editor) | GPL-3.0 | The shape of a waveform envelope: mono float32, a fixed slice rate with a total cap, `vDSP_maxmgv` per hop, a −50 dB floor — `WaveformExtractor` | Read for approach. `Sources/Compositing/WaveformEnvelope.swift` is written here; the rate and floor are theirs. The orientation is deliberately reversed and the file says why. |
| [a native editor](https://github.com/a native editor/a native editor) | GPL-3.0 | Sticky snapping with per-target-kind thresholds — `SnapEngine` | **Was ported; re-expressed 2026-08-25.** The first version shared their control flow, their variable roles and their two-phase structure, and said so. `Sources/Timeline/SnapEngine.swift` is now written from the behaviour `SnapEngineTests` pins — same behaviour, all ten tests unchanged and passing, no line derived from theirs. The IDEA is still theirs and is credited here; ideas are not what a licence attaches to. |
| [a Swift recorder](https://github.com/a Swift recorder) | Apache-2.0 | Sampling the pointer on a fixed cadence rather than from an event tap | Read for approach. `Sources/Capture/PointerSampler.swift` was written from scratch; the insight that a tap reports motion and a still pointer produces none is theirs. |
| [an Electron recorder](https://github.com/an Electron recorder) & [an Electron recorder](https://github.com/an Electron recorder) | AGPL-3.0 / MIT | The conditions a window capture has to handle: `desktopIndependentWindow` so nothing overlapping the window is captured, `ignoreShadowsSingleWindow`, `excludesCurrentProcessAudio`, an explicit 48 kHz/stereo, a deeper `queueDepth`, a host display found by centre THEN overlap, and even buffer edges | Read for approach. Each condition is applied in `CaptureSource`/`CaptureSession` with its own reason written at the site — several are things both projects set without saying why. |
| [an Electron recorder](https://github.com/an Electron recorder) & [an Electron recorder](https://github.com/an Electron recorder) | MIT / AGPL-3.0 | Naming the microphone with `microphoneCaptureDeviceID`, and probing `responds(to:)` for the capture selectors instead of gating on an OS version | Read for approach. `MicrophoneSource`/`MicrophoneInventory` are written here; an Electron recorder's degrade-with-a-warning shape is theirs. |
| [a Swift recorder](https://github.com/a Swift recorder) | Apache-2.0 | The claim that ScreenCaptureKit cannot select a microphone device — **checked and no longer true**, which is why Soredemo keeps one capture instead of a second `AVCaptureSession` | Read, measured, and NOT followed. Recorded because the reasoning is the useful part. |
| [an Electron recorder](https://github.com/an Electron recorder) | AGPL-3.0 | **Chained zoom** — panning between two zoom blocks whose gap is short instead of returning to rest, at a 1350 ms threshold | Read for approach. `ZoomBlock.chainedPanGap` carries their constant rather than re-guessing it; the implementation is a change to `CameraMotion.aim`, not a port. |
| [a Rust recorder](https://github.com/a Rust recorder) | AGPL-3.0 | Snapping the camera centre to its target while the zoom is still ~1, so a zoom scales straight toward its focus instead of drifting sideways | Read for approach. `CameraMotion.identityZoomBound` follows the same argument their `zoom_spring.rs` gives. |
| [a Rust recorder](https://github.com/a Rust recorder) | AGPL-3.0 (`cap-camera*`/`scap-*` are MIT) | Hashing the live cursor image against a table of known digests to classify it; `NSCursor.currentSystem` with a `current` fallback | Read for approach. a Rust recorder's implementation is Rust. `Soredemo/UI/SystemCursorShape.swift` explains why the classification is honestly `.other` here rather than pretending to a table it does not have. |

### Read and deliberately not used

- **an Electron recorder** and **an Electron recorder** are Electron applications, but each ships a small native
  Swift helper for ScreenCaptureKit, and those helpers are where the conditions above came
  from. Nothing else in either is reachable from Swift.

---

## Applying the licence to new files

Contributors do not need a per-file header: the `LICENSE` at the root covers the
whole work.

**A file that ports code from another project cannot be added to this tree.** That is a
harder rule than the one this file carried under AGPLv3, and it is what MIT costs: a
copyleft-derived line makes the whole tree copyleft, and the licence at the root would
then be false. Reading another project for its approach is welcome and is how most of
the table above came to exist — the code has to be written here.

If something is read for approach, say so in the file's own header, name the source and
its licence, and add it to the table above **in the same commit**. The table is the
record, and a derivation that only exists in a commit message is a derivation nobody
will find. That is exactly how the one port this tree did have was caught: its own
header said what it was.
