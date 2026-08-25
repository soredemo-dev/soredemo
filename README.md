# Soredemo

**A screen recorder that keeps its reasons.**

Soredemo records a demo and edits it into something worth watching — the pointer drawn from what
actually happened, the camera moving to whatever was clicked, and every one of those decisions
reviewable by the person who made the recording.

Every recorder zooms. This one can say why it did not, and let you disagree.

macOS 26 · Swift 6.4 · Apple Silicon · local by default · MIT

> **Status: the free recorder is feature-complete; the derivation pipeline is not.** The app lives
> in the menu bar. A person can record a display, a window they point at, or a rectangle they drag
> out, with system audio, a chosen microphone and a camera whose self-view is on screen before the
> countdown starts. The preview draws the pointer from real observations and zooms the camera to
> the control under each click; they can see why every click was or was not zoomed to and disagree
> with any of it.
>
> They can then choose the stage's look and background, cut and split and reorder and re-speed the
> clips, remove dead air, crop, place a camera overlay by dragging it, add titles and redactions,
> transcribe on-device and burn word-timed captions, pick 16:9 / 9:16 / 1:1, and export — MP4 in
> H.264 or HEVC, MOV in ProRes 422 or 4444, or a GIF — at a chosen resolution, frame rate and
> quality, with the file size estimated first and several exports queued at once. Projects save and
> reopen. The interface is English and Traditional Chinese.
> `scripts/build-release.sh` signs and notarises a Developer ID copy.
>
> **What is not built:** the derivation graph, titles and transitions, and the CLI. Framing
> decisions are made per click but are not yet graph-provenanced, and a portrait export still
> inherits landscape's zoom decisions — both named in `ROADMAP.md` on rows that stay `◐` rather than
> being rounded up.

---

## Start here

**Coding agent:** read [`AGENTS.md`](AGENTS.md) first — it governs everything.

**Person returning to this repo:** [`docs/PRODUCT.md`](docs/PRODUCT.md) for why, then
[`ROADMAP.md`](ROADMAP.md) for what is next.

---

## The documents

| Document | What it settles |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | **Working agreement.** Method, rules, the publishing rule |
| [`ROADMAP.md`](ROADMAP.md) | **The only ordered work list.** Take the first unblocked row |
| [`docs/PRODUCT.md`](docs/PRODUCT.md) | What this is, what is deliberately not built, and how it differs from the recorders it was read against |
| [`docs/FEATURES.md`](docs/FEATURES.md) | **Every feature and the Apple framework behind it.** Four pillars: record, edit, launch video, CLI + agent |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Eight binding decisions (D1–D8) and the module map |
| [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md) | Xcode 27 setup. A macOS 27 volume is **not** required at the 26.0 floor |

`docs/design/` holds one document per phase — the questions asked, the alternatives rejected, and
why. Those are the durable record of *why*; `git log` is the rest.

---

## The rules that matter most

**The completion rule.** A row is not complete while the behaviour its name claims is not observable in
the product. A pure function with no caller does not satisfy a row that claims a product behaviour.

**The producer-value rule.** An authored override always wins over a derived value and is never
silently replaced. Test it by supplying a value the producer could not have derived.

**The publishing rule.** Nothing this app produces leaves the machine without a person sending it.
There is no auto-publish, no "approve all", and no share button — and any that is ever proposed
answers to this rule first.

**Native Liquid Glass only.** App chrome is 100% standard SwiftUI. Never `.glassEffect()`, never
`NSGlassEffectView`. Content surfaces are deliberately opaque.

---

## Layout

Three tiers, and the boundary between each pair is enforced by the build graph rather than by a rule
someone has to remember. `docs/ARCHITECTURE.md` has the full module map.

```
soredemo-main/            ← this repo
├── AGENTS.md             the rules
├── ROADMAP.md            the work list
├── LICENSE NOTICE.md     MIT, and what in this tree came from where
├── docs/                 PRODUCT · FEATURES · ARCHITECTURE · TOOLCHAIN · design/
│
├── Core/                 THE SWIFTPM PACKAGE. Its own directory since 2026-08-23:
│   │                     the package root and the repository root used to be the
│   │                     same folder, so Xcode showed `dist/`, `docs/`, `scripts/`
│   │                     and the app target itself inside the package node.
│   ├── Package.swift
│   ├── Sources/          eleven targets, three tiers
│   │   ├── Geometry Timeline Graph Project Render Framing Variants
│   │   │                 DETERMINISTIC: same input, same output. No GPU, no clock,
│   │   │                 no window. Guard: ArchitectureCheck
│   │   ├── Capture/      READS THE WORLD: ScreenCaptureKit, event taps, accessibility,
│   │   │                 the microphone, the clock. Guard: HeadlessCheck
│   │   └── Compositing/  TURNS A PLAN INTO PIXELS: GPU, Core Image, AVFoundation.
│   │                     Guard: HeadlessCheck
│   ├── Tests/            CaptureTests and CompositingTests depend on their own target
│   │                     only; the deterministic suites cannot link either
│   └── Plugins/          ArchitectureCheck (pure tier) · HeadlessCheck (runnable tier)
│
├── Soredemo/             the Xcode app target — ONLY a running app can reach it.
│                         SwiftUI, NSDocument, the app lifecycle
├── Soredemo.xcodeproj/   references Core/ as a local package
└── scripts/              the gates a person runs — no CI in this repo yet
```

**Two roots, and the tests know the difference.** `Core/` is the package root; the repository
root is its parent. A scan of the package's own sources reports paths like
`Sources/Capture/CaptureSession.swift` — the file's name *within its package* — while a scan
of the app reports `Soredemo/UI/…`. `pathRelativeToRepositoryRoot` strips whichever root owns
the file, which is why the sixty-odd path literals in those scans did not have to move.

**`Capture` and `Compositing` do not depend on each other and may not.** They were one target through
Phase 3A-3 and referenced each other zero times; splitting them turned a fact nothing checked into one
the compiler holds. If something is genuinely needed by both, it belongs in a pure target both can
depend on.

Sibling directories, outside the repo:
`../soredemo-web/` (design research) and `../opensource/` (comparable projects — **read for ideas, not
for code**).

The app icon is built from `soredemo-brand-kit/` with Icon Composer.

---

## The gates

Nothing runs automatically — there is no CI here yet, so these are gates a person runs.

| Command | What it holds |
| --- | --- |
| `swift test --package-path Core` | the whole suite; `--split` reports the deterministic and runnable populations separately, with the partition verified. **`--package-path Core`** since the package moved there — a bare `swift test` at the repository root now finds no manifest and says so |
| `scripts/check-strict-memory-safety.sh` | zero unmarked unsafe sites, over a full clean compile of every target |
| `xcodebuild -project Soredemo.xcodeproj -scheme Soredemo` | the app target, which `swift build` never compiles |
| `scripts/run-cross-boundary-probe.sh` | the checks that need a real display, a real file and a person |

`scripts/count-tests.sh` is where a test count comes from. A number written into prose is a number
that drifts, and three documents once carried three different wrong ones.
