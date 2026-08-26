# Handoff from `itsYoga/UIUX` to `main`

Written 2026-08-26, at the point that branch was merged and deleted. Everything below is on
`main` now. Read this before picking up the next piece of work — it is the part that is not
recoverable from the diff.

---

## What landed

Sixteen commits, from the picture-quality investigation through to the feature audit and the
gaps it found. The ROADMAP rows carry the detailed reasoning; these are the ones whose *shape*
you have to know before touching nearby code.

**Render and motion.** The master's buffer is declared sRGB on ingest and every export codec
carries Rec.709 primaries, transfer *and matrix*. `CameraMotion` bakes its path once per boot
epoch and answers by binary search — it used to integrate O(n²) per frame. `PointerPath`
resamples the recorded samples through a cardinal spline and follows them with an analytic
spring; the old constant was ω = 105 rad/s against a Rust recorder's shipped 12.5, which is why the cursor
read as a hand rather than a glide. Render cost was measured out of the smoothness question
first: the heaviest composed frame at 1920×1080 is 7.2 ms against a 16.7 ms budget.

**Zoom.** Depth now takes `coverage` and `intensity`, both with **no default**, both applied at
the point the depth is *derived*. Manual zooms can be placed where nobody clicked. Sentences can
be deleted out of the video from the transcript.

**Audio.** Loudness by BS.1770-4, a music bed with voice ducking. Noise suppression is the one
real gap and is **not** started — see the open decisions below.

---

## Invariants you can break without noticing

These are the ones that cost time on this branch.

**Run the four gates sequentially.** `swift test`, then `check-strict-memory-safety.sh`, then
`run-cross-boundary-probe.sh`, then `xcodebuild`. Running them in parallel wipes `.build`
underneath one another and looks like a hang, not a failure.

**Capture the script's own exit code.** `./script | tail -4` returns `tail`'s status, and in zsh
it is `$pipestatus[1]`, not `$PIPESTATUS[0]`. A gate was nearly reported clean off a pipeline
that had actually exited 1.

**Never conclude "absent" from one grep.** Twice on this branch a feature was about to be
written down as missing and existed: `Compositing/GIFExporter.swift` is fully wired, and the 54
hits for `arrow` are all the *cursor's* arrow shape. Read the whole block, or the whole file.

**`EpochAnchor.instant(atOffset:)` is THE offset-to-instant conversion.** Its header says so,
because `1a98402` was a caller doing that arithmetic by hand and dropping a term. A duplicate of
it was written into `FramingPlanReader` on this branch and deleted again. Do not add a second.

**A new app source must be added to `scripts/run-cross-boundary-probe.sh`.** The app target has
no test target, so the probe's `swiftc` invocation is the app tier's *only* executing
instrument. `ProbeCoverageTests` fails if you forget, which is how `TranscriptPanel.swift` got
caught.

**A public option with no test is a bug waiting.** `CameraOverlayStyle.borderOpacity` had never
drawn a pixel in any build — the ring was `CIBlendWithMask` over `CIImage.empty()`, which has
zero extent, so the pass evaporated silently. Nothing exercised it, so nothing said. That is
D6a-V, and it is worth taking literally.

**The clipboard is banned except at one line.** `noAppSourceReadsUserContent` bans `NSPasteboard`
because it *reads* what a person copied. Writing a finished export to it is allowed at exactly
one named, counted line in `ExportQueue.swift`; every reading member stays banned everywhere,
including there. If you need a second use, come and write down why.

**Two static seams must be published from the app or they lie.**
`StageCompositor.outputCoverage` and `StageCompositor.zoomIntensity` are plain `Double`s because
`Compositing` cannot name `AspectVariant`. `StageWindow` publishes both — coverage from the
**cropped** size, since a crop re-frames every zoom the way a variant change does. If you add a
third consumer of derived zooms, route it through `refreshDerivedZooms()` rather than calling
`ZoomBlock.blocks` again: a second derivation is how a lane comes to disagree with the picture.

---

## Open decisions — yours, not mine

**1. Noise suppression.** The largest real gap; both competitors ship it. `isVoiceProcessingEnabled`
lives on `AVAudioEngine`, and this recorder takes the microphone through ScreenCaptureKit
deliberately (`MicrophoneSource`). Reaching it means a **second parallel audio capture and a
second clock domain** — which this codebase treats as a serious cost, because one clock is the
thing `1a98402` was about. Decide whether it is worth the capture-architecture change *before*
any code. Do not start it as a small task.

**2. Hiding desktop icons — measured, not built.** The usual implementation writes
`com.apple.finder CreateDesktop false` and restarts Finder, mutating the machine with nothing to
restore it if the app dies. Measured instead: the desktop **is** a separately excludable window
(Finder, `windowLayer -2147483603`, full display extent, on screen; `excludingDesktopWindows(true)`
drops exactly it, 181 windows to 160). What could **not** be established is whether excluding it
removes the icons and keeps the wallpaper — both comparison captures were taken with the screen
covered by windows, so neither had a visible desktop. **One run with a visible desktop settles
it.** Note also that `CaptureSource` builds
`SCContentFilter(display:excludingApplications:exceptingWindows:)` — excluding one *window* of
one app is a different initialiser, so the filter shape changes too.

**3. Match Recording as the default shape.** Deliberately left as an option rather than the
default. The hazard is real: `.task(id: variant)` is what runs `load()`, so assigning `variant`
from inside it cancels the very run doing the assigning — and `restore(_:)`, which applies a
saved shape, is further down the same function. A first draft would have dropped a saved
Portrait on first open depending on where the cancellation landed. If you want it defaulted, do
it **where a new recording is first handed to the editor**, not in `load()`. `chosenShapeDeliberately`
is already set at both places that decide a shape, so it is one line there.

**4. Camera damping.** a Rust recorder's camera spring is ζ = 0.943 against this project's 1.0. The speeds
already match (ω 9.43 vs 10). The ROADMAP row promises "settles without overshoot" and a test
pins it, so changing it is a decision about what the row claims, not a tuning.

---

## What to build next, ranked

The three-way comparison against ScreenKite and Screen Studio is at
<https://claude.ai/code/artifact/79114e81-01d7-450a-a470-f5c69dfceeaa> — every Soredemo column
was checked by reading the source. Unknown ≠ absent there: a marketing page is evidence of what
a product advertises, not of what it lacks.

1. **Finish the desktop-icon measurement** (above). Cheap, and it decides whether a feature ships
   without touching anybody's Finder preferences.
2. **Annotation arrows and shapes.** Text overlays and redaction masks already ship; arrows and
   shapes are the rest of the set a Rust recorder offers.
3. **Loop cursor position.** Screen Studio's, and the last cursor row this app does not have.
4. **Noise suppression**, if and only if decision 1 above says yes.

Not gaps: shareable links (needs a server), iPhone capture and device frames (a product
decision and a different capture stack).

---

## House style, in one paragraph

Long comments are wanted — the user's standing instruction is best quality and design, not short
code. Say *why*, and say what was rejected and what it cost; several files on this branch record
a first draft that was wrong and why, and those are the paragraphs worth keeping. A measurement
has no safe default. Every refusal names its reason as a value, never a `nil`. Authored values
survive re-derivation (the producer-value rule). No `CGRect`/`CGPoint` outside the bridge (D6
rule 5), and every decodable type validates in `init(from:)` (rule 8). Reply to the user in
Traditional Chinese.
