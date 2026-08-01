# Architecture

*Binding decisions. Changing one is a deliberate act, not a drift.*

---

## D1 — SwiftPM packages, Xcode app target

Pure logic lives in a SwiftPM package. The app is an Xcode target that consumes it.

```
Packages/SoredemoCore/     Foundation only — derivation graph, framing, timeline, variants, project
Soredemo.xcodeproj         App bundle, entitlements, Info.plist, assets, Sparkle, signing
```

The boundary is load-bearing, not cosmetic: a package that *cannot* import AppKit or ScreenCaptureKit
is a build-enforced version of the pure-domain rule. The enforcement is a build-tool plugin, not the
compiler — the compiler permits any system framework in any target. See D6.

*Rejected:* pure SwiftPM — Info.plist, icons, and asset catalogues all need excluding and stitching by
script. *Rejected:* pure Xcode project — the package manifest is what carries the target graph the plugin
enforces, so without it the pure/impure boundary is a convention rather than a build failure.

---

## D2 — macOS 26, Apple Silicon, Swift 6.4, no fallbacks

`platforms: [.macOS(.v26)]`. Strict concurrency. No availability branches.

**Four version numbers, deliberately not the same.** They get conflated, and conflating them makes
correct settings look stale:

| | Value | Means |
| --- | --- | --- |
| Deployment target | **26.0** | the oldest macOS that runs the app |
| SDK | **27.0** | the API ceiling available at compile time |
| `swift-tools-version` | **6.3** | manifest format version |
| Swift compiler | **6.4** | language version |

Building against the newest SDK and deploying to an older system is the normal arrangement, so
`otool -l` reporting `minos 26.0 / sdk 27.0` is correct, not a leftover. Likewise "Swift 6.4 strict
concurrency" is current — only the *manifest format* is 6.3, because Xcode 26.6 ships SwiftPM 6.3.3
and refuses a 6.4 manifest.

macOS 27 is Apple Silicon only — Intel and Rosetta 2 are ended, so this is Apple's position rather
than just ours. It is a stability release, so adoption risk is low. This project ships when 27 is
roughly a year old.

What the floor buys: no two-tier material code, no `if #available` on ScreenCaptureKit, Speech, or
Accessibility, and full access to Liquid Glass, the Document API, and `SpeechAnalyzer`.

**Known cost:** a macOS-27-only free tier cannot be a mass-market distribution channel. See
`PRODUCT.md` § Distribution — the channels are built deliberately instead.

---

## D3 — Coordinates: normalised, one conversion point

`NormalizedPoint` is 0–1 with a **bottom-left origin**, matching Core Image and `NSScreen.frame` so
the render path never flips. `NormalizedFrame` additionally carries a `geometryRevision`.

That origin claim is right about rendering and misleading about everything else: `CGDisplayBounds`,
`CGEventGetLocation`, and AX `kAXPositionAttribute` are all **top-left**. There *is* a flip — the
obligation is not that it never happens, but that it happens in exactly **one** place, on entry, and
never again. `NormalizationContext` is that one place, converting display-local top-left pixels (never
global ones, which would silently compute a plausible wrong answer) to normalised bottom-left. Routing
a global point to its display happens first, via `DisplayArrangement.route`.

This is the decision most likely to fail silently. Two rules make it loud:

1. **No raw `CGPoint` or `CGRect` crosses a module boundary.** Capture converts on entry, through
   `NormalizationContext`; render converts on exit. Nothing in between speaks in pixels.
2. **Comparing frames across `geometryRevision` is a precondition failure**, never a silent coercion.
   Displays get reconfigured mid-recording; a comparison that quietly succeeds against a stale
   revision lands a zoom on the wrong control with no error anywhere.

---

## D4 — Automatic framing: targets from evidence, motion from springs

Two stages that answer different questions, and they must not be collapsed.

```
observations (clicks + the AX control under each)
   ↓  framing            where to look, how deep, and why
zoom blocks               target, depth, pre-roll, hold, merge
   ↓  camera
spring simulation         how the camera actually gets there
```

**Framing decides *where*.** The AX control under a click, when it passes the gates. Otherwise the
pointer — and it records which gate rejected the control. Named rejections: confidence absent,
confidence low, observation stale, does not contain the click, degenerate rectangle, partly offscreen,
too large.

**Springs decide *how*.** Settle without overshoot, carry velocity across a re-aim, and use a safe zone
so small cursor movement does not move the camera.

### Three calibration risks, named up front

**The size gate decides whether this works at all.** A threshold that is too loose accepts a 20–28%
editor pane or terminal as a "control" and zooms confidently at the wrong thing with no diagnostic —
which is worse than a rejection, because named rejection reasons do not help when the failure is a
false accept. Measure real control sizes before choosing the threshold. The honest number is closer to
**5% of screen area than 60%**.

**Merge can swallow the whole feature.** With a 2.5 s hold and a 2.5 s merge gap, any two clicks under
~5.3 s apart land in one zoom block. Demo clicks are typically 1–3 s apart, so a naive merge turns an
entire demo into a single zoom and every framing decision after the first is computed and discarded.
Tune against real click cadence, and **make it an error when the storyboard reports six beats and the
camera reports one block.** Two derivations that disagree must say so.

**Depth must actually vary.** If depth only changes across a narrow band of control sizes, and real
controls cluster outside that band, "adaptive depth" collapses into two constants. Fit the curve to
measured sizes, or drop the claim.

### The hand-off must have exactly one consumer

The framing decision is produced in one place and read in one place, and there is a test that fails if
nothing reads it. A framing origin that nothing consumes is a pure function with no caller — see the
completion rule. This is also what `explain_framing` and the review UI read, so it has to be durable,
not recomputed.

---

## D5 — Project format: a document, not a database

A versioned `Codable` document with a schema number and an explicit upgrade path. Atomic writes.
Relative paths only, so a project folder can move. Media lives beside the project file as sidecars.

**I/O:** `WritableDocument`/`ReadableDocument` — asynchronous, incremental disk operations with
`Subprogress` reporting. For a package holding multi-gigabyte recordings that is the difference
between a responsive open and a beachball. `DocumentCreationSource` maps onto the entry points: new
from recording, new from a release, new empty.

*Verify first* that these handle a **package** — a directory with large media sidecars — and not only
single-file documents.

*Rejected:* SwiftData. The project is a document users open, move, and version — not a store.

---

## D6 — Architecture rules, enforced by the build

Rules that are not executable stop being true. Three mechanisms, in descending order of strength.

**1. A build-tool plugin — not the compiler.** `SoredemoCore` imports Foundation only. `import AppKit`
in the package is a build failure, not a review comment — but the *compiler does not produce that
failure*. The compiler constrains edges **between package targets** (F2), and even there SwiftPM
degrades an undeclared-target import to a warning on a warm `.build`; it places no restriction
whatever on system frameworks (F1). A target with zero declared dependencies can `import AppKit` and
`import ScreenCaptureKit` and compile cleanly, and `.treatAllWarnings(as: .error)` does not close the
gap, because the diagnostic comes from the dependency scanner rather than the compiler frontend.

What actually enforces the rule is `Plugins/ArchitectureCheck`, a SwiftPM build-tool plugin attached
to all six library targets. It runs `architecture-checker` over each target's sources on every build —
clean or incremental — and exits non-zero with `file:line: error:` on any import outside the target's
allowed set. Its allow-list is not a copy of the dependency edges — the plugin reads each target's
**declared** dependencies out of `PluginContext` and passes them on the command line, so the
allow-list *is* the manifest, and it enforces F2 as an error on warm builds too. Direct edges only:
the transitive closure would silently permit `Framing → Timeline` and `Variants → Geometry`, which
are precisely the undeclared edges SwiftPM downgrades to a warning.

The checker reads source text through a file-scoped lexical scan, so comments, string literals of
every flavour, and string-interpolation bodies are classified correctly; `public import AppKit` and
the other SE-0409 access-level spellings are caught, as is `#if canImport(AppKit)`. It tokenises by
maximal *identifier* run rather than by a list of separators, because Swift accepts space, tab,
newline, CR, form feed, vertical tab, NUL and U+00A0 between `import` and the module name, and ends a
token at any punctuation besides — a form feed is invisible in every diff viewer, so an enumerated
separator list is a standing invitation. A backtick both closes and opens a run, because Swift
terminates the keyword there: `` import`AppKit` `` needs no space and typechecks. Every one of the
128 ASCII code points and 22 Unicode oddities has been swept as a separator against `swiftc` and the
checker together; Swift accepts exactly eight, and all eight are caught. SE-0451 raw identifiers and
extended regex literals `#/…/#` are modelled as their own lexical spans, because a `"` inside either
is ordinary content — without that, `` @Test func `rejects import AppKit`() `` is reported as a
violation, which is the failure that actually occurs, sentence-shaped test names being the reason raw
identifiers exist.

`codeViewLines` is a hand-rolled lexer, and therefore a list of Swift's literal forms — one that will
be a version behind each time the language gains another. Deriving it from SwiftSyntax is the durable
fix if this area is ever revisited. Every I/O failure is a hard error: a missing sources
directory, a directory with no `.swift` files, and an unreadable or undecodable file all fail the
build. Unreadable must never mean compliant. Verified to fail the build under **both** `swift build`
and `xcodebuild`.

**This constrains the package, not the app.** The app target uses ScreenCaptureKit, AVFoundation,
AppKit, and Metal freely — that is where recording, rendering, and UI live.

```
Soredemo.xcodeproj   Capture/ Render/ Editor/ Agent/ UI/   ← ScreenCaptureKit, AVFoundation, Metal
     │  captures, writes an observation log
     ▼
observation log → evidence (plain data)
     │
     ▼
Packages/SoredemoCore   Graph/ Framing/ Timeline/ Variants/ Project/   ← Foundation only
```

**The core does not record; it reasons about a recording.** Three reasons this line matters:

- Pure logic tests with no screen, no permissions, and no display — so the derivation suite runs in CI
  in milliseconds.
- Derivation must be a deterministic function of its input. A framing stage that could call
  ScreenCaptureKit could observe the world mid-derivation, and then staleness, `isCurrent`, and
  content-hash approval all stop meaning anything.
- The boundary cannot be violated by accident, only by deleting the rule.

**2. `Plugins/ArchitectureCheck`** for what the compiler cannot see: no `CGPoint`/`CGRect` in the
package's public API; exactly one owner for the log→graph join; the timeline consumer allow-list.

**3. Tests as specification.** Two forms are mandatory and are the ones most likely to be skipped:

> **Producer-value rule.** Supply a value the producer could not have derived; assert the supplied
> value wins. Write it for every producer.
>
> **Cache pairing.** Every cache-hit test is paired with an invalidation test. A cache never proven to
> invalidate is a correctness bug waiting for a demo.

---

## D7 — Liquid Glass: native only, never custom

App chrome is 100% standard SwiftUI. `.glassEffect()` is never called to build chrome.
`NSGlassEffectView` is never touched. Content surfaces are deliberately opaque.

Standard components — `NavigationSplitView`, `Inspector`, `.toolbar`, `.sheet` — adopt Liquid Glass
automatically, and **the glass tint responds to the system-level Liquid Glass slider without any
code**. That slider is the decisive argument: a hand-rolled glass surface does not respond to it, so it
looks correct on your machine and wrong for every user who has moved that control.

| Layer | Approach |
| --- | --- |
| Window, sidebar, inspector, toolbar, sheets, menus | 100% standard SwiftUI. Zero glass code |
| Video preview, timeline canvas, waveform, transcript | Custom drawing, deliberately **opaque** |

Glass is for controls floating above content, and a timeline is content. `NavigationSplitView` +
`Inspector` gives the three-pane editor shape with system glass for free.

A video editor's instinct is heavy custom chrome — bespoke timeline header, custom transport bar.
**That instinct forfeits native Liquid Glass and has to be resisted.**

---

## D8 — One render path for preview and export

Preview and export call the same renderer. Same time, same project, same output size produces an
identical frame within a documented tolerance.

This is not an optimisation — it is what makes "what you review is what ships" true. Prove it with
golden-image tests that fail the build, not with care.

The renderer is an `AVVideoCompositing` implementation over Core Image and Metal. Preview drives it
with `CADisplayLink`; export drives it with `AVAssetWriter` frame pacing.

*Rejected:* a fast preview path plus a separate accurate export path. Two renderers means two sets of
bugs and a class of "it looked different when I exported it" reports that cannot be reproduced.

---

## Module map

```
Packages/SoredemoCore/           Foundation only
  Geometry/                      NormalizedPoint, NormalizedFrame, geometryRevision
  Graph/                         observations → actions → beats → outputs; origin + review state
  Framing/                       AX targets, named rejections, depth, zoom blocks
  Timeline/                      integer-nanosecond output↔source mapping
  Variants/                      16:9 · 9:16 · 1:1 re-framing, platform profiles
  Project/                       versioned document model, upgrades, atomic save

Soredemo/                        Xcode app target
  Capture/                       ScreenCaptureKit, audio, permissions
  Observation/                   CGEventTap, AXUIElement, the one clock, the log writer
  Render/                        AVVideoCompositing, Core Image, Metal, cursor and effects
  Editor/                        trim, cut, speed, transcript editing
  Launch/                        title scenes, transitions, music, poster
  Agent/                         MCP server, tool surface
  CLI/                           Swift Argument Parser
  UI/                            SwiftUI shell, native Liquid Glass
```

---

## Agentic security

Any text arriving from outside the app — release notes, changelogs, PR titles — is
attacker-controllable in a repository that accepts contributions, and it flows toward a publish action.

```
release notes → evidence → post draft → publish
 (untrusted)     (graph)   (model phrases it)  (public, permanent)
```

Three mitigations, and the design already provides two:

1. **The approval gate.** Per-post human approval bound to a content hash. Injected text cannot publish
   itself. This is why refusing an auto-publish convenience is a security property, not only a
   philosophical one.
2. **The citation requirement.** Text with no valid supporting evidence cannot be approved, so an
   injected instruction cannot manufacture an approvable claim.
3. **Framing, which must be built deliberately.** The prompt treats external text as quoted material to
   summarise, never as instruction to follow — with a test that proves it.

---

## To verify against the SDK

Taken from documentation, not from running code. Two of these change decisions.

- [ ] Do `WritableDocument`/`ReadableDocument` handle a **package** (directory with large media
      sidecars), or only single-file documents? *(If single only, D5 needs a hand-written package
      coordinator.)*
- [ ] Does `SpeechAnalyzer` accept an `AVAssetReader` audio track for offline transcription of a
      finished recording, or only live input? *(If live only, the transcript work grows.)*
- [ ] Is `SCRecordingOutput` sufficient for the master, or is per-frame `AVAssetWriter` control needed
      for the pointer-free requirement and the one-clock guarantee?
- [ ] Does `AVCaptionRenderer`'s style preview work against a custom compositor, or does it assume
      `AVPlayerLayer`?
- [ ] Is on-device subtitle **translation** exposed to apps, or only inside the system player?
- [ ] Foundation Models Private Cloud Compute free-tier eligibility — Apple's own pages state it two
      different ways.
- [ ] Does standard SwiftUI chrome pick up Liquid Glass correctly in a document-based app with a
      hosted `NSView` content area? That combination is what this project needs and the least-trodden
      path in the guidance.
