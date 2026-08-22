# Notice

Soredemo — Copyright © 2026 Soredemo.

Soredemo is free software under the **GNU Affero General Public License v3.0**
(`LICENSE`). This file records why that licence and not another, and what in this
tree came from somewhere else.

---

## Why AGPLv3

The licence is not a preference. Soredemo incorporates work derived from
copyleft-licensed projects, and AGPLv3 is the licence that can hold all of it:

- **GPLv3 code may be combined into an AGPLv3 work.** GPLv3 §13 grants exactly
  this permission, and it is the reason a GPLv3 source can be used here at all.
- **AGPLv3 code may be combined directly.**

The direction does not reverse. Once a GPLv3- or AGPLv3-derived line is in this
tree, Soredemo cannot be distributed under a permissive or proprietary licence
without removing it and everything derived from it. That is a real constraint on
what this project can later be sold or dual-licensed as, and it was accepted
deliberately.

**AGPLv3 §13 adds an obligation GPLv3 does not have:** if a modified version is
made available to users over a network, its complete source must be offered to
those users. Soredemo is a local application today, so nothing triggers this yet
— but anything built on it that becomes a hosted service does.

---

## Derived work

Each entry names what was taken, from where, under what licence, and how far the
derivation goes. "Read for approach" means no code was copied; "ported" means
code was.

| From | Licence | What | How |
| --- | --- | --- | --- |
| [a native editor](https://github.com/a native editor/a native editor) | GPL-3.0 | Sticky snapping with per-target-kind thresholds — `SnapEngine` | **Ported.** `Sources/Timeline/SnapEngine.swift` reimplements the algorithm in this project's own types; the design is theirs. See that file's header. |
| [a Swift recorder](https://github.com/a Swift recorder) | Apache-2.0 | Sampling the pointer on a fixed cadence rather than from an event tap | Read for approach. `Sources/Capture/PointerSampler.swift` was written from scratch; the insight that a tap reports motion and a still pointer produces none is theirs. |
| [an Electron recorder](https://github.com/an Electron recorder) & [an Electron recorder](https://github.com/an Electron recorder) | AGPL-3.0 / MIT | The conditions a window capture has to handle: `desktopIndependentWindow` so nothing overlapping the window is captured, `ignoreShadowsSingleWindow`, `excludesCurrentProcessAudio`, an explicit 48 kHz/stereo, a deeper `queueDepth`, a host display found by centre THEN overlap, and even buffer edges | Read for approach. Each condition is applied in `CaptureSource`/`CaptureSession` with its own reason written at the site — several are things both projects set without saying why. |
| [a Rust recorder](https://github.com/a Rust recorder) | AGPL-3.0 (`cap-camera*`/`scap-*` are MIT) | Hashing the live cursor image against a table of known digests to classify it; `NSCursor.currentSystem` with a `current` fallback | Read for approach. a Rust recorder's implementation is Rust. `Soredemo/UI/SystemCursorShape.swift` explains why the classification is honestly `.other` here rather than pretending to a table it does not have. |
| a Rust recorder | AGPL-3.0 | The verbatim text of the GNU AGPLv3 in `LICENSE` | Copied. The licence text is itself freely copyable verbatim; copying it from a project that ships it is not a derivation of that project. |

### Read and deliberately not used

- **an Electron recorder** and **an Electron recorder** are Electron applications, but each ships a small native
  Swift helper for ScreenCaptureKit, and those helpers are where the conditions above came
  from. Nothing else in either is reachable from Swift.

---

## Applying the licence to new files

Contributors do not need a per-file header: the `LICENSE` at the root covers the
whole work, which is how AGPLv3 §5(c) expects it. A file that **ports** code from
another project must say so in its own header, name the source and its licence,
and be added to the table above in the same commit — the table is the record, and
a derivation that only exists in a commit message is a derivation nobody will find.
