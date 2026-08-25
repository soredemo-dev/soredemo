# Product

*What this is, what it deliberately is not, and how it is different from the recorders it was read
against.*

Features and the frameworks behind them are in `FEATURES.md`.

---

## What it is

**A screen recorder that keeps its reasons.**

A recording carries an observation log beside the video: where the pointer was, when it was clicked,
and what accessibility element was under each click. Everything the editor does afterwards is
derived from that log rather than guessed from the pixels — the drawn cursor, the zoom to whatever
was clicked, the reason a click was not zoomed to.

### The thesis, in one sentence

> One recording is treated as **evidence**, everything else is **derived** from it, and every
> derived value is **traceable and reviewable**.

That is why the feature list looks different from a screen recorder's. Most of what is built exists
to make a derivation inspectable, not to make editing powerful.

### The architectural point

A person can disagree with any derived value, and their answer wins and is never silently replaced.
That is architecture rule 7 — the producer-value rule — and it has boundary tests rather than a
convention.

---

## Scope — what is deliberately not built

Saying no is part of the definition. A refusal that is quietly reversed is worse than no table at
all, because the next reader trusts the rest of it — so a row that stops being true comes out.

| Not built | Why |
| --- | --- |
| **Full NLE** — ripple, multicam, clip transitions | Wrong product. A demo needs a handful of operations, and the ripple is free here because a clip's output position is the sum of what precedes it |
| **Colour grading, LUTs** | This is not a colourist's tool |
| **Generative video, images, audio** | Contradicts the thesis. Everything is derived from what happened |
| **Auto-publishing** | Never. Nothing leaves the machine without a person sending it — see `AGENTS.md` |
| **Cloud rendering, hosted projects** | Local by default is a product value |
| **HDR export** | Measured, not assumed: the pipeline is 8-bit sRGB end to end, so an HDR tag would ship a file claiming something its pixels cannot support. `docs/design/2026-08-24-colour-pipeline.md` is the measurement and the way in if it is ever wanted |
| **Watermarks** | It exists in the recorders that sell a paid tier, as the reason to buy it. That reason does not apply here |
| **Windows, Intel, macOS < 26** | See `ARCHITECTURE.md` D2 |
| **Keystroke logging** | Ordinary typing is never recorded — enforced by `noAppSourceReadsKeystrokeText`, not by intention |

---

## Against the recorders it was read against

Every one of these was read line by line; `NOTICE.md` records what came from where.

| | Soredemo | ScreenKite | a Rust recorder | a native editor | a Swift recorder |
| --- | --- | --- | --- | --- | --- |
| Auto-zoom | AX-anchored, **with the reason for every click** | cursor | ✅ | ❌ | cursor |
| Native macOS | ✅ | ✅ | ⚠️ Tauri | ✅ | ✅ |
| Camera overlay | ✅ with a live self-view before recording | ❌ | ✅ | ❌ | ❌ |
| Region capture | ✅ adjustable, remembered | ✅ | ✅ | ❌ | ✅ |
| Codec choice | H.264 / HEVC / ProRes 422 / **ProRes 4444** | ❌ | ⚠️ | ✅ | ✅ |
| **Chroma verified at runtime** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Refusals are named and reviewable** | ✅ | ❌ | ❌ | ❌ | ❌ |
| Full NLE | ❌ by choice | ⚠️ | ⚠️ | ✅ | ⚠️ |

**The row that is the product** is the last but one. Every one of these zooms; only this one can say
why it did not, and let a person disagree.

---

## Distribution

Free, MIT, local. `scripts/build-release.sh` signs and notarises a Developer ID copy; it publishes
nothing, and uploading is a human act.
