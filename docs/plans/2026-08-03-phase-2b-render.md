# Phase 2B — Render and export: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use a skill chain:subagent-driven-development
> (recommended) or a skill chain:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** a person records a few seconds, sees that recording in the app's preview framed on a
background with a card, shadow and rounded corners with a drawn pointer moving through it, exports,
and plays the exported MP4 in QuickTime.

**Architecture:** every *decision* — card rectangle, corner radius, pointer position at output time
*t*, whether *t* lies in a blind interval — is a pure function of `(ProjectSnapshot, Nanoseconds)`
computed in a new Foundation-only package target `Render`. Every *drawing* happens in
`Soredemo/Render/` behind a protocol that names neither Core Image nor Metal. One
`AVVideoComposition`, built from `AVVideoComposition.Configuration`, drives both the preview
(`AVPlayer`) and the export (`AVAssetReader` → `AVAssetWriter`).

**Tech stack:** Swift 6.4, macOS 26 floor, SwiftUI, AVFoundation, Core Image (Metal-backed
`CIContext`), Swift Testing.

## Global constraints

Copied verbatim from `docs/design/2026-08-03-phase-2b-render-design.md`, `ARCHITECTURE.md` and
`AGENTS.md`. Every task's requirements implicitly include this section.

- **A row is not complete while the behaviour its name claims is not observable in the product.**
  Tests passing is not completion. Somebody must see a frame.
- **`export-basic` produces one playable MP4 (H.264). Full stop.** No GIF, no ProRes, no poster
  frame, no written steps, no post copy, no platform variants. Those are Phase 5.
- **The package (`Sources/`) imports Foundation only.** No AppKit, no AVFoundation, no CoreGraphics.
  Enforced by the `ArchitectureCheck` plugin on every build.
- **No `CGRect`, `CGPoint`, `CGSize` or `CGFloat` anywhere in the package.** Enforced by the plugin.
- **No ambient time, randomness or hashing in the package.** In the app they enter only through
  `Soredemo/Support/Minting.swift`. Enforced by `Tests/DeterminismTests` and
  `Tests/AppSourceTests`.
- **The compositor protocol must not name a winner.** No `CIImage`, `CIContext`, `CIFilter`,
  `MTLTexture`, `MTLDevice` or `MTLCommandBuffer` in `FrameRenderer.swift`. **`CVPixelBuffer` is
  allowed and is the point**: it is CoreVideo, the neutral currency both a Core Image path and a
  Metal path already speak, so it names no winner. Erasing it to `AnyObject` would buy nothing and
  cost every implementation a cast.
- **New media-writing code uses the successor stack** — `AVAssetWriter.start()`,
  `inputReceiver(for:)`, `appendImmediately(_:)`. The existing capture path stays on
  `LegacyMasterWriter`. See `Soredemo/Capture/MasterWriter.swift`.
- **`AVMutableVideoComposition`, `AVAssetWriterInput.append(_:)`, `addInput:` and `startWriting` are
  deprecated at macOS 27.0.** Use `AVVideoComposition.Configuration` and the receiver APIs. Run
  `scripts/scan-sdk-deprecations.py` if in doubt; a clean `xcodebuild` must report zero deprecation
  warnings.
- **Preview may drop frames and must count them; export may never drop.** The dropped count is a
  value stored with the project, not a console line.
- **Blind intervals: no new camera target is acquired; a motion already in flight completes; the
  interval is recorded with its duration and cause; every interval is surfaced in the UI** until a
  measured threshold exists.
- **The drawn pointer is a derived value with origin "drawn, not captured".** Draw wherever the
  pointer track has a position. A person may switch the cursor off over a range in review, and that
  override is permanent.
- **Every derived value carries its origin.** Nothing is invented that cannot point back at
  evidence.
- **App chrome is 100% standard SwiftUI. `.glassEffect()` is never called.** Content surfaces are
  deliberately opaque (D7).
- **Capture output goes to temporary directories and is deleted; never write to `$HOME`.** No
  recording, log or frame dump is ever committed. `Tests/**/*.mov|mp4|gif` are the committed-fixture
  exception, already negated in `.gitignore`.
- **Never `git add -A`.** Stage named paths only.

---

## File structure

**Created:**

| Path | Responsibility |
| --- | --- |
| `Sources/Render/RenderPlan.swift` | the value a frame is drawn from: background, card rect, radius, shadow, pointer |
| `Sources/Render/StagePlanner.swift` | `(ProjectSnapshot, Nanoseconds) -> RenderPlan`; card geometry and letterboxing |
| `Sources/Render/PointerTrack.swift` | pointer samples indexed by time; `position(at:)`; `BlindInterval` |
| `Sources/Render/BlindInterval.swift` | the blind-region record and its cause vocabulary |
| `Sources/Render/CursorOverride.swift` | the permanent per-range "cursor off" edit |
| `Soredemo/Render/FrameRenderer.swift` | the compositor seam — the protocol, and nothing else |
| `Soredemo/Render/CoreImageFrameRenderer.swift` | today's implementation, Core Image on a Metal-backed context |
| `Soredemo/Render/StageCompositor.swift` | `AVVideoCompositing` conformance; owns no policy |
| `Soredemo/Render/CompositionBuilder.swift` | builds one `AVVideoComposition` for preview and export |
| `Soredemo/Render/CursorArt.swift` | the drawn pointer and click ripple, as vector paths |
| `Soredemo/Export/MP4Exporter.swift` | `AVAssetReader` → successor `AVAssetWriter`, never drops |
| `Soredemo/Capture/SuccessorMasterWriter.swift` | the second `MasterWriting` conformance |
| `Soredemo/UI/PreviewView.swift` | the `AVPlayer` preview surface, opaque |
| `Soredemo/UI/StageWindow.swift` | `NavigationSplitView` shell: recording list, preview, inspector |
| `Tests/RenderTests/…` | the pure half: planner, pointer track, blind intervals, overrides |
| `Tests/AppSourceTests/RenderSeamTests.swift` | the seam must not name Core Image or Metal |

**Modified:** `Package.swift` (new `Render` target), `Tests/DeterminismTests`'s `libraryModules`,
`scripts/run-cross-boundary-probe.sh` (new app sources), `Soredemo/UI/ContentView.swift`,
`docs/ARCHITECTURE.md` (D6a rows), `ROADMAP.md`.

---

## Task 1: the `Render` package target and `RenderPlan`

**Files:**
- Create: `Sources/Render/RenderPlan.swift`, `Sources/Render/StagePlanner.swift`
- Create: `Tests/RenderTests/StagePlannerTests.swift`
- Modify: `Package.swift`, `Tests/DeterminismTests/DeterminismTests.swift`

**Interfaces:**
- Consumes: `NormalizedPoint` (Geometry), `Nanoseconds`, `HostRange` (Timeline), `ProjectSnapshot`,
  `MasterSegment` (Project).
- Produces: `RenderPlan`, `StagePlanner.plan(for:at:outputSize:)`.

**Why a new target rather than `Framing`.** `Framing` is Phase 3's (AX targets, gates, zoom blocks)
and does not depend on `Timeline`. The render plan needs `Timeline` and `Project`. A target whose
name matches its contents is worth one line of manifest.

- [ ] **Step 1: add the target, and put it under the plugin**

In `Package.swift`, after the `Project` target line:

```swift
        .target(name: "Render", dependencies: ["Geometry", "Timeline", "Project"],
                swiftSettings: strict, plugins: archCheck),
```

Add `"Render"` to the `SoredemoCore` library's `targets:` array, and add a test target beside the
existing ones:

```swift
        .testTarget(name: "RenderTests", dependencies: ["Render", "Geometry", "Timeline", "Project"],
                    swiftSettings: strict),
```

- [ ] **Step 2: make the determinism scan actually cover it**

`Tests/DeterminismTests/DeterminismTests.swift:35` holds a hand-written list, and the check that
uses it is `#require(Set(names).isSuperset(of: libraryModules))` — a **superset** test, so a target
missing from this list is silently unchecked rather than failing. Add `"Render"`:

```swift
let libraryModules = ["Geometry", "Timeline", "Graph", "Framing", "Variants", "Project", "Render"]
```

- [ ] **Step 3: write the failing test**

`Tests/RenderTests/StagePlannerTests.swift`:

```swift
import Testing
import Geometry
import Timeline
import Project
@testable import Render

@Test func theCardIsInsetAndCentredInsideTheOutput() {
    let plan = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1600, sourceHeight: 1000,
                                 style: .default)
    // The card keeps the SOURCE aspect ratio, is centred, and never touches the edge.
    #expect(plan.card.width / plan.card.height == 1.6)
    #expect(plan.card.x > 0 && plan.card.y > 0)
    #expect(plan.card.x + plan.card.width < 1920)
    #expect(plan.card.y + plan.card.height < 1080)
    #expect(abs((plan.card.x + plan.card.width / 2) - 960) < 0.5)
    #expect(abs((plan.card.y + plan.card.height / 2) - 540) < 0.5)
}

@Test func aTallerSourceIsFittedByHeightNotStretched() {
    let wide = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1000, sourceHeight: 1600, style: .default)
    #expect(abs(wide.card.width / wide.card.height - 0.625) < 0.001)
    #expect(wide.card.height <= 1080)
}

@Test func theCornerRadiusIsClampedToHalfTheShorterSide() {
    let style = StageStyle(insetFraction: 0.04, cornerRadius: 10_000,
                           shadowRadius: 24, shadowOpacity: 0.35,
                           background: .solid(red: 0.1, green: 0.1, blue: 0.12))
    let plan = StagePlanner.plan(outputWidth: 400, outputHeight: 400,
                                 sourceWidth: 400, sourceHeight: 400, style: style)
    #expect(plan.cornerRadius == min(plan.card.width, plan.card.height) / 2)
}
```

- [ ] **Step 4: run it and watch it fail**

Run: `swift test --filter RenderTests`
Expected: FAIL — `cannot find 'StagePlanner' in scope`.

- [ ] **Step 5: write `RenderPlan.swift`**

```swift
import Foundation

/// A rectangle in OUTPUT PIXELS, bottom-left origin.
///
/// Not `CGRect`: the package may not name Core Graphics types (D6 rule 2, enforced by the
/// plugin on every build), and the reason is not stylistic — `CGRect` in the package is how a
/// pixel value crosses a module boundary without anyone converting it.
public struct StageRect: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        precondition(x.isFinite && y.isFinite && width.isFinite && height.isFinite,
                     "StageRect requires finite components, got \(x) \(y) \(width) \(height)")
        precondition(width >= 0 && height >= 0,
                     "StageRect requires non-negative extent, got \(width)x\(height)")
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum StageBackground: Hashable, Codable, Sendable {
    case solid(red: Double, green: Double, blue: Double)
}

public struct StageStyle: Hashable, Codable, Sendable {
    public let insetFraction: Double
    public let cornerRadius: Double
    public let shadowRadius: Double
    public let shadowOpacity: Double
    public let background: StageBackground

    public static let `default` = StageStyle(
        insetFraction: 0.06, cornerRadius: 18, shadowRadius: 32, shadowOpacity: 0.35,
        background: .solid(red: 0.09, green: 0.09, blue: 0.11))

    public init(insetFraction: Double, cornerRadius: Double, shadowRadius: Double,
                shadowOpacity: Double, background: StageBackground) {
        precondition(insetFraction >= 0 && insetFraction < 0.5,
                     "insetFraction must be in [0, 0.5), got \(insetFraction)")
        self.insetFraction = insetFraction
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.background = background
    }
}

/// Everything a renderer needs to draw one frame, and nothing about HOW.
///
/// The pointer is optional because the track can be silent — see `PointerTrack.position(at:)`
/// and `BlindInterval`. A `nil` pointer means "draw none", never "draw the last one".
public struct RenderPlan: Hashable, Sendable {
    public let outputWidth: Int
    public let outputHeight: Int
    public let card: StageRect
    public let cornerRadius: Double
    public let style: StageStyle
    public let pointer: NormalizedPointerPlacement?

    public init(outputWidth: Int, outputHeight: Int, card: StageRect, cornerRadius: Double,
                style: StageStyle, pointer: NormalizedPointerPlacement?) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.card = card
        self.cornerRadius = cornerRadius
        self.style = style
        self.pointer = pointer
    }
}

/// Where the drawn pointer goes, in OUTPUT pixels, with the click state that decides the ripple.
public struct NormalizedPointerPlacement: Hashable, Sendable {
    public let x: Double
    public let y: Double
    /// 0 at the click instant, rising to 1 as the ripple finishes. `nil` when not clicking.
    public let ripplePhase: Double?

    public init(x: Double, y: Double, ripplePhase: Double?) {
        self.x = x; self.y = y; self.ripplePhase = ripplePhase
    }
}
```

- [ ] **Step 6: write `StagePlanner.swift`**

```swift
import Foundation

/// Turns an output size and a source size into the rectangle the recording is drawn in.
///
/// Pure, and deliberately takes sizes rather than a `ProjectSnapshot`: the geometry question has
/// nothing to do with the document, and a function that takes the document cannot be tested
/// without building one.
public enum StagePlanner {
    public static func plan(outputWidth: Int, outputHeight: Int,
                            sourceWidth: Int, sourceHeight: Int,
                            style: StageStyle,
                            pointer: NormalizedPointerPlacement? = nil) -> RenderPlan {
        precondition(outputWidth > 0 && outputHeight > 0,
                     "output must be positive, got \(outputWidth)x\(outputHeight)")
        precondition(sourceWidth > 0 && sourceHeight > 0,
                     "source must be positive, got \(sourceWidth)x\(sourceHeight)")

        let output = (w: Double(outputWidth), h: Double(outputHeight))
        let inset = style.insetFraction
        let available = (w: output.w * (1 - 2 * inset), h: output.h * (1 - 2 * inset))

        // Fit, never fill: the recording is evidence and must not be cropped.
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        let cardWidth = min(available.w, available.h * sourceAspect)
        let cardHeight = cardWidth / sourceAspect

        let card = StageRect(x: (output.w - cardWidth) / 2, y: (output.h - cardHeight) / 2,
                             width: cardWidth, height: cardHeight)
        // A radius larger than half the shorter side is not a rounder rectangle, it is an
        // undefined one. Clamped here so no renderer has to decide.
        let radius = min(style.cornerRadius, min(cardWidth, cardHeight) / 2)
        return RenderPlan(outputWidth: outputWidth, outputHeight: outputHeight,
                          card: card, cornerRadius: radius, style: style, pointer: pointer)
    }
}
```

- [ ] **Step 7: run the tests**

Run: `swift test --filter RenderTests`
Expected: PASS, 3 tests.

- [ ] **Step 8: prove the plugin covers the new target**

Add `import AppKit` temporarily to `Sources/Render/RenderPlan.swift`, run `swift build`, and confirm
it FAILS with the architecture checker's message naming `Render`. Remove the import. This is the
project's standing rule: a guard nobody has seen fail is not a guard.

- [ ] **Step 9: commit**

```bash
git add Package.swift Sources/Render Tests/RenderTests Tests/DeterminismTests
git commit -m "Render target: the pure half of the stage, with the plugin observed refusing it"
```

---

## Task 2: the pointer track and the blind-interval policy

**Files:**
- Create: `Sources/Render/PointerTrack.swift`, `Sources/Render/BlindInterval.swift`,
  `Sources/Render/CursorOverride.swift`
- Create: `Tests/RenderTests/PointerTrackTests.swift`

**Interfaces:**
- Consumes: `PointerSample`, `HostInstant`, `Nanoseconds`, `GapSite` (Project/Timeline).
- Produces: `PointerTrack.init(samples:blindIntervals:overrides:)`,
  `PointerTrack.position(at: Nanoseconds) -> PointerReading`,
  `BlindInterval`, `CursorOverride`, `PointerReading`.

**The three clauses this task implements**, from the design doc § 2.1 and § 2.2:

1. In a blind interval, **no new target is acquired**; a motion already in flight completes.
   (Camera motion is Phase 3, so what this task ships is the *reading* the camera will consume —
   `PointerReading.blind(BlindInterval)` — and the guarantee that it is never confused with a
   position.)
2. The cause reuses `GapSite`. No second vocabulary.
3. A `nil` position is never silently replaced by the previous one.

- [ ] **Step 1: write the failing test**

`Tests/RenderTests/PointerTrackTests.swift`:

```swift
import Testing
import Geometry
import Timeline
import Project
@testable import Render

private let epoch = BootEpoch(rawValue: 7)
private func at(_ ns: Int64) -> HostInstant { HostInstant(epoch: epoch, hostTime: Nanoseconds(ns)) }
private func sample(_ ns: Int64, _ x: Double, _ y: Double) -> PointerSample {
    PointerSample(instant: at(ns), position: NormalizedPoint(x: x, y: y),
                  revision: GeometryRevision(id: 1))
}

@Test func aPositionBetweenTwoSamplesComesFromTheEarlierOne() {
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1), sample(1_000, 0.9, 0.9)],
                             blindIntervals: [], overrides: [])
    #expect(track.position(at: Nanoseconds(400)) == .drawn(NormalizedPoint(x: 0.1, y: 0.1)))
}

@Test func aTimeInsideABlindIntervalReadsAsBlindAndCarriesTheCause() {
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300),
                              cause: .tapDisabled)
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1), sample(1_000, 0.9, 0.9)],
                             blindIntervals: [blind], overrides: [])
    #expect(track.position(at: Nanoseconds(600)) == .blind(blind))
}

@Test func blindNeverDegradesToTheLastKnownPosition() {
    // The whole point of the policy: `.blind` and `.drawn` are different cases, so a caller
    // cannot accidentally treat a gap as "the pointer stayed there". A test that only checked
    // "some position came back" would pass under hold-last-known, which is the rejected option.
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300),
                              cause: .tapDisabled)
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [blind], overrides: [])
    let reading = track.position(at: Nanoseconds(600))
    if case .drawn = reading { Issue.record("a blind interval produced a drawn position") }
}

@Test func anOverrideSuppressesTheCursorAndSaysSo() {
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [],
                             overrides: [CursorOverride(start: Nanoseconds(0),
                                                        duration: Nanoseconds(1_000))])
    #expect(track.position(at: Nanoseconds(500)) == .suppressedByReviewer)
}

@Test func silenceBeforeTheFirstSampleIsNotBlindAndIsNotAPosition() {
    let track = PointerTrack(samples: [sample(1_000, 0.5, 0.5)], blindIntervals: [], overrides: [])
    #expect(track.position(at: Nanoseconds(0)) == .noObservationYet)
}

@Test func theBlindFractionIsOverTheSpanAskedAbout() {
    let track = PointerTrack(
        samples: [sample(0, 0.1, 0.1)],
        blindIntervals: [BlindInterval(start: Nanoseconds(200), duration: Nanoseconds(300),
                                       cause: .tapDisabled)],
        overrides: [])
    #expect(track.blindFraction(over: Nanoseconds(0) ..< Nanoseconds(1_000)) == 0.3)
}
```

- [ ] **Step 2: run it and watch it fail**

Run: `swift test --filter PointerTrackTests`
Expected: FAIL — `cannot find 'PointerTrack' in scope`.

- [ ] **Step 3: write `BlindInterval.swift`**

```swift
import Foundation
import Project
import Timeline

/// A stretch of output time for which the observation track has nothing, **and why**.
///
/// The `cause` is a `GapSite` — Task 11's existing vocabulary — and not a new enum. Two
/// vocabularies for one fact is how two instruments start disagreeing, which this project has
/// already paid for once (`AGENTS.md`, the definite-singular audit's row 3).
public struct BlindInterval: Hashable, Codable, Sendable {
    public let start: Nanoseconds
    public let duration: Nanoseconds
    public let cause: GapSite

    public init(start: Nanoseconds, duration: Nanoseconds, cause: GapSite) {
        precondition(duration.rawValue >= 0,
                     "BlindInterval duration must be non-negative, got \(duration.rawValue)")
        self.start = start
        self.duration = duration
        self.cause = cause
    }

    public var end: Nanoseconds { Nanoseconds(start.rawValue + duration.rawValue) }

    public func contains(_ time: Nanoseconds) -> Bool {
        time.rawValue >= start.rawValue && time.rawValue < end.rawValue
    }
}
```

- [ ] **Step 4: write `CursorOverride.swift`**

```swift
import Foundation
import Timeline

/// A reviewer's permanent decision to draw no pointer over a range.
///
/// First-class and stored with the project, like every other override. It exists because the one
/// thing the automatic path cannot know is whether the real screen showed a cursor: macOS hides
/// the pointer while the user types, keyboard events are deliberately not captured, so "the user
/// is typing" is absent from this app's data by design. Spike E measured that the hidden state is
/// not readable — `NSCursor.currentSystem` is identical hidden and visible, and both CG
/// cursor-visibility functions are unavailable at the 26.0 floor.
public struct CursorOverride: Hashable, Codable, Sendable {
    public let start: Nanoseconds
    public let duration: Nanoseconds

    public init(start: Nanoseconds, duration: Nanoseconds) {
        precondition(duration.rawValue >= 0,
                     "CursorOverride duration must be non-negative, got \(duration.rawValue)")
        self.start = start
        self.duration = duration
    }

    public func contains(_ time: Nanoseconds) -> Bool {
        time.rawValue >= start.rawValue && time.rawValue < start.rawValue + duration.rawValue
    }
}
```

- [ ] **Step 5: write `PointerTrack.swift`**

```swift
import Foundation
import Geometry
import Project
import Timeline

/// What the pointer track says about one output time. **Four cases, not an optional**, because an
/// optional collapses three different silences into one and a caller cannot tell them apart:
/// a gap that was measured, a reviewer's decision, and time before anything was ever seen.
public enum PointerReading: Hashable, Sendable {
    case drawn(NormalizedPoint)
    case blind(BlindInterval)
    case suppressedByReviewer
    case noObservationYet
}

public struct PointerTrack: Sendable {
    private let samples: [PointerSample]      // sorted by instant
    private let blindIntervals: [BlindInterval]
    private let overrides: [CursorOverride]

    public init(samples: [PointerSample], blindIntervals: [BlindInterval],
                overrides: [CursorOverride]) {
        self.samples = samples.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
        self.blindIntervals = blindIntervals
        self.overrides = overrides
    }

    /// The reviewer's decision wins, then a measured gap, then the most recent sample at or before
    /// `time`. **No interpolation and no hold-last-known across a gap**: both produce footage that
    /// looks fine, and looking fine is what deletes the signal saying someone should look.
    public func position(at time: Nanoseconds) -> PointerReading {
        if overrides.contains(where: { $0.contains(time) }) { return .suppressedByReviewer }
        if let interval = blindIntervals.first(where: { $0.contains(time) }) {
            return .blind(interval)
        }
        var latest: PointerSample?
        for sample in samples where sample.instant.hostTime.rawValue <= time.rawValue {
            latest = sample
        }
        guard let latest else { return .noObservationYet }
        return .drawn(latest.position)
    }

    /// The share of `span` covered by blind intervals. Clamped to the span, so an interval that
    /// starts before it or ends after it contributes only its overlap.
    public func blindFraction(over span: Range<Nanoseconds>) -> Double {
        let total = Double(span.upperBound.rawValue - span.lowerBound.rawValue)
        guard total > 0 else { return 0 }
        var blind = 0.0
        for interval in blindIntervals {
            let lower = max(interval.start.rawValue, span.lowerBound.rawValue)
            let upper = min(interval.end.rawValue, span.upperBound.rawValue)
            if upper > lower { blind += Double(upper - lower) }
        }
        return blind / total
    }

    /// Every interval, for the review UI. **All of them, unconditionally** — the threshold at which
    /// a recording is marked has to be chosen against a real recording, and until that number
    /// exists "no threshold yet" must not become "no behaviour yet". Ship loud, tune down later.
    public var intervalsToSurface: [BlindInterval] { blindIntervals }
}
```

- [ ] **Step 6: make `Nanoseconds` usable in a `Range`**

`Range<Nanoseconds>` needs `Comparable`. Check `Sources/Timeline/Nanoseconds.swift`; if it does not
already conform, add `Comparable` there with a test in `Tests/TimelineTests`:

```swift
@Test func nanosecondsOrderByRawValue() {
    #expect(Nanoseconds(1) < Nanoseconds(2))
    #expect(!(Nanoseconds(2) < Nanoseconds(2)))
}
```

- [ ] **Step 7: run the tests**

Run: `swift test --filter RenderTests`
Expected: PASS, 9 tests total in `RenderTests`.

- [ ] **Step 8: commit**

```bash
git add Sources/Render Tests/RenderTests Sources/Timeline Tests/TimelineTests
git commit -m "The pointer track: four readings, because an optional hides three silences"
```

---

## Task 3: the compositor seam and its first implementation

**Files:**
- Create: `Soredemo/Render/FrameRenderer.swift`, `Soredemo/Render/CoreImageFrameRenderer.swift`
- Create: `Tests/AppSourceTests/RenderSeamTests.swift`
- Modify: `scripts/run-cross-boundary-probe.sh`

**Interfaces:**
- Consumes: `RenderPlan`, `StageRect`, `StageStyle` (Render).
- Produces: `protocol FrameRendering { func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws }`,
  `CoreImageFrameRenderer`.

**The seam is built before either implementation, and it must not name a winner.** "Core Image or
Metal, measure at 4K and decide later" is only a real deferral if the seam exists first; otherwise
whichever is written first wins, because replacing the other becomes a rewrite and the cost of the
rewrite becomes the argument against it. `MasterWriting` settled the same shape and *was* re-decided
on evidence hours later, precisely because the seam existed.

- [ ] **Step 1: write the scan that keeps the seam honest**

`Tests/AppSourceTests/RenderSeamTests.swift`:

```swift
import Testing
import Foundation
import CheckerLexer

/// **The compositor protocol may not name Core Image or Metal.**
///
/// A seam that speaks `CIImage` has already chosen Core Image, and the Metal implementation behind
/// it would be a translation layer rather than an alternative — at which point the 4K frame-time
/// measurement can no longer change the answer, which is the only reason the choice was deferred.
@Test func theFrameRendererProtocolNamesNeitherCoreImageNorMetal() throws {
    let url = repositoryRoot.appending(path: "Soredemo/Render/FrameRenderer.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    let code = codeViewLines(of: source).joined(separator: "\n")
    // CVPixelBuffer is deliberately NOT banned: it is CoreVideo, which both a Core Image path
    // and a Metal path already speak, so it names no winner. Banning it would force `AnyObject`
    // and a downcast in every implementation — cost with no property bought.
    for banned in ["CIImage", "CIContext", "CIFilter", "MTLTexture", "MTLDevice",
                   "MTLCommandBuffer"] {
        #expect(!code.contains(banned),
                """
                FrameRenderer.swift names '\(banned)'. The seam must not name a winner: a
                protocol that speaks one framework's vocabulary has chosen it, and the
                alternative becomes a translation layer. Express the frame as a CVPixelBuffer,
                which both paths already speak.
                """)
    }
}
```

- [ ] **Step 2: run it and watch it fail**

Run: `swift test --filter theFrameRendererProtocolNamesNeitherCoreImageNorMetal`
Expected: FAIL — the file does not exist yet.

- [ ] **Step 3: write `FrameRenderer.swift`**

```swift
import CoreMedia
import CoreVideo
import Foundation

public enum FrameRenderingError: Error {
    case noRenderDevice
}

/// Draws one frame from a plan. **No Core Image type, no Metal type, no pixel-buffer type in this
/// file** — that is enforced by a test, not by care.
nonisolated protocol FrameRendering: Sendable {
    /// `CVPixelBuffer` in and out. CoreVideo, not Core Image and not Metal — the one vocabulary
    /// both candidate implementations already speak, so the signature chooses neither.
    func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws
}
```

`RenderPlan` comes from the package: add `import Render` at the top.

- [ ] **Step 4: run the scan**

Run: `swift test --filter theFrameRendererProtocolNamesNeitherCoreImageNorMetal`
Expected: PASS.

- [ ] **Step 5: write `CoreImageFrameRenderer.swift`**

```swift
import CoreImage
import CoreVideo
import Foundation
import Metal
import Render

/// Today's implementation: Core Image on a Metal-backed context.
///
/// Chosen first because the card, shadow and corner radius are three built-in filters and one
/// composite. It is **not** chosen permanently — the alternative is a hand-written Metal pass, and
/// the decision belongs to a measured 4K frame time. Both sit behind `FrameRendering`, which is why
/// that measurement can still change the answer when it arrives.
nonisolated final class CoreImageFrameRenderer: FrameRendering {
    private let context: CIContext

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FrameRenderingError.noRenderDevice
        }
        // `.workingColorSpace` pinned, not defaulted: uncontrolled colour handling is the failure
        // that cost this project an evening, and a default is a value nobody chose.
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let background = backgroundImage(plan)
        let card = cardImage(plan, source: source)
        let composed = card.composited(over: background)
            .cropped(to: CGRect(x: 0, y: 0,
                                width: CGFloat(plan.outputWidth),
                                height: CGFloat(plan.outputHeight)))
        context.render(composed, to: destination,
                       bounds: composed.extent,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private func backgroundImage(_ plan: RenderPlan) -> CIImage {
        switch plan.style.background {
        case let .solid(red, green, blue):
            return CIImage(color: CIColor(red: red, green: green, blue: blue))
        }
    }

    private func cardImage(_ plan: RenderPlan, source: CVPixelBuffer) -> CIImage {
        let image = CIImage(cvPixelBuffer: source)
        let scaleX = plan.card.width / image.extent.width
        let scaleY = plan.card.height / image.extent.height
        let placed = image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: plan.card.x, y: plan.card.y))
        return rounded(placed, plan: plan)
    }

    /// Rounded corners as a mask, not as a crop: a crop gives square corners and a mask gives the
    /// radius the plan asked for.
    private func rounded(_ image: CIImage, plan: RenderPlan) -> CIImage {
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(x: plan.card.x, y: plan.card.y,
                                    z: plan.card.width, w: plan.card.height),
            "inputRadius": plan.cornerRadius,
            "inputColor": CIColor.white,
        ])?.outputImage ?? image
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
    }
}
```

- [ ] **Step 6: write a pixel test that proves a frame was drawn**

`Tests/AppSourceTests` cannot import the app target. Add the renderer to the cross-boundary probe
instead — that is the mechanism this project already uses to test app sources. Append a section to
`scripts/cross-boundary-digest-probe.swift` that builds a 320×180 destination, renders a plan whose
source is a solid red buffer, and asserts:

```swift
// the centre of the card is the source colour
check(centrePixel == (r: 255, g: 0, b: 0), "the card shows the source frame's pixels",
      actual: "\(centrePixel)")
// a pixel in the inset margin is the background colour, not the source
check(marginPixel == (r: 23, g: 23, b: 28), "outside the card is the background",
      actual: "\(marginPixel)")
// the extreme corner of the card is background — the radius cut it
check(cardCornerPixel == (r: 23, g: 23, b: 28), "the corner radius removed the card's corner",
      actual: "\(cardCornerPixel)")
```

Add `Soredemo/Render/FrameRenderer.swift` and `Soredemo/Render/CoreImageFrameRenderer.swift` to the
`xcrun swiftc` source list in `scripts/run-cross-boundary-probe.sh` — that list is authoritative, and
a file missing from it fails the probe rather than excusing itself.

- [ ] **Step 7: run the probe**

Run: `./scripts/run-cross-boundary-probe.sh`
Expected: PASS, with three more checks than before.

- [ ] **Step 8: commit**

```bash
git add Soredemo/Render Tests/AppSourceTests/RenderSeamTests.swift \
        scripts/run-cross-boundary-probe.sh scripts/cross-boundary-digest-probe.swift
git commit -m "The compositor seam, built before either implementation can win"
```

---

## Task 4: a window with a rendered frame in it

**This is the task that satisfies the completion condition's first half, and it is deliberately
fourth rather than last.** Everything before it is unobservable; if the phase reaches its end before
anything is on screen it has repeated Phase 2's shape with new vocabulary.

**Files:**
- Create: `Soredemo/Render/StageCompositor.swift`, `Soredemo/Render/CompositionBuilder.swift`,
  `Soredemo/UI/PreviewView.swift`, `Soredemo/UI/StageWindow.swift`
- Modify: `Soredemo/UI/ContentView.swift`, `scripts/run-cross-boundary-probe.sh`

**Interfaces:**
- Consumes: `FrameRendering`, `CoreImageFrameRenderer`, `StagePlanner`, `RenderPlan`.
- Produces: `StageCompositor: NSObject, AVVideoCompositing`, `CompositionBuilder.composition(for:plan:)`,
  `PreviewView`, `StageWindow`.

- [ ] **Step 1: write `StageCompositor.swift`**

```swift
import AVFoundation
import CoreVideo
import Foundation
import Render

/// The `AVVideoCompositing` conformance. **Owns no policy**: it asks the planner for a plan and
/// hands it to a renderer. Everything it decides is which frame is being drawn and when.
nonisolated final class StageCompositor: NSObject, AVVideoCompositing {
    /// Set once before the composition is handed to AVFoundation. `nonisolated(unsafe)` for the
    /// same reason `CaptureSession`'s writer references are: AVFoundation calls back on its own
    /// queue and the value is published before any callback can see it.
    nonisolated(unsafe) static var renderer: (any FrameRendering)?
    nonisolated(unsafe) static var style: StageStyle = .default

    let sourcePixelBufferAttributes: [String: any Sendable]? =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    private nonisolated(unsafe) var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let trackID = request.sourceTrackIDs.first?.int32Value,
              let source = request.sourceReadOnlyPixelBuffer(byTrackID: trackID),
              let context = renderContext,
              let destination = context.newReadOnlyPixelBuffer(),
              let renderer = Self.renderer else {
            request.finish(with: CompositorError.notConfigured)
            return
        }
        let plan = StagePlanner.plan(
            outputWidth: Int(context.size.width), outputHeight: Int(context.size.height),
            sourceWidth: CVPixelBufferGetWidth(source), sourceHeight: CVPixelBufferGetHeight(source),
            style: Self.style)
        do {
            try renderer.render(plan, source: source, into: destination)
            request.finish(withComposedPixelBuffer: destination)
        } catch {
            request.finish(with: error)
        }
    }

    enum CompositorError: Error { case notConfigured }
}
```

If `AVVideoCompositionRenderContext.newReadOnlyPixelBuffer()` does not exist at the 26.0 floor, use
`newPixelBuffer()` and note it: `newPixelBuffer` is deprecated at 27.0 with
`newReadOnlyPixelBuffer()` named as its successor, so this is a D6b-27 row and a scan hit, not a
free choice. Verify with `python3 scripts/scan-sdk-deprecations.py --floor`.

- [ ] **Step 2: write `CompositionBuilder.swift`**

```swift
import AVFoundation
import Foundation
import Render

/// Builds ONE composition, handed to both the preview and the export.
///
/// `AVVideoComposition.Configuration` and not `AVMutableVideoComposition`: the mutable class is
/// deprecated at macOS **26.0**, this project's own floor, so it was never available here. The
/// value type is also what makes D8's "one render path" a fact about a type rather than a rule two
/// call sites must remember.
enum CompositionBuilder {
    static func composition(for asset: AVAsset, outputWidth: Int, outputHeight: Int,
                            frameDuration: CMTime) async throws -> AVVideoComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw BuilderError.noVideoTrack }
        let duration = try await asset.load(.duration)

        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        var instruction = AVVideoCompositionInstruction.Configuration(
            backgroundColor: nil, enablePostProcessing: false,
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            requiredSourceSampleDataTrackIDs: [],
            timeRange: CMTimeRange(start: .zero, duration: duration))

        var configuration = AVVideoComposition.Configuration(
            for: asset,
            prototypeInstruction: AVVideoCompositionInstruction(configuration: instruction))
        configuration.customVideoCompositorClass = StageCompositor.self
        configuration.renderSize = CGSize(width: outputWidth, height: outputHeight)
        configuration.frameDuration = frameDuration
        return AVVideoComposition(configuration: configuration)
    }

    enum BuilderError: Error { case noVideoTrack }
}
```

- [ ] **Step 3: write `PreviewView.swift`**

```swift
import AVKit
import SwiftUI

/// The preview surface. **Deliberately opaque** — D7: glass is for controls floating above
/// content, and a video preview is content.
struct PreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
```

- [ ] **Step 4: write `StageWindow.swift`**

```swift
import AVFoundation
import SwiftUI

/// `NavigationSplitView` + `Inspector`, 100% standard SwiftUI, zero glass code — D7. The system
/// gives these components Liquid Glass automatically and, decisively, makes them respond to the
/// system-level Liquid Glass slider, which a hand-rolled surface does not.
struct StageWindow: View {
    @State private var player: AVPlayer?
    @State private var failure: String?
    let mediaURL: URL

    var body: some View {
        NavigationSplitView {
            List { Text(mediaURL.lastPathComponent) }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            Group {
                if let player {
                    PreviewView(player: player)
                } else if let failure {
                    ContentUnavailableView("Could not build the preview", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView()
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            StageCompositor.renderer = try CoreImageFrameRenderer()
            let asset = AVURLAsset(url: mediaURL)
            let composition = try await CompositionBuilder.composition(
                for: asset, outputWidth: 1920, outputHeight: 1080,
                frameDuration: CMTime(value: 1, timescale: 60))
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = composition
            player = AVPlayer(playerItem: item)
        } catch {
            failure = "\(error)"
        }
    }
}
```

- [ ] **Step 5: point `ContentView` at it**

Replace `ContentView`'s body with a `StageWindow(mediaURL:)` for the document's first segment, and
add an "Open Recording…" command that runs a capture through the existing `CaptureSession` and opens
the resulting file.

- [ ] **Step 6: build both ways**

Run: `swift build && xcodebuild -scheme Soredemo -configuration Debug build`
Expected: `BUILD SUCCEEDED`, zero deprecation warnings.

- [ ] **Step 7: THE HUMAN STEP — look at it**

Run `scripts/build-app-for-verification.sh`, launch the app, record five seconds of any window, and
**look at the preview**. Required to be true, and each is a thing a person confirms:

1. a frame appears;
2. the recording sits in a card, inset from the edge, not filling the window;
3. the corners of the card are rounded;
4. the area outside the card is the background colour, not black and not the desktop;
5. the aspect ratio is not stretched.

Record the result in the ledger with the OS build (`sw_vers -buildVersion`). **A screenshot is not
committed** — no frame dump is ever committed; the ledger records what was seen.

- [ ] **Step 8: commit**

```bash
git add Soredemo/Render Soredemo/UI scripts/run-cross-boundary-probe.sh
git commit -m "A window with a rendered frame in it — the first observable row"
```

---

## Task 5: the drawn pointer and click ripple

**Files:**
- Create: `Soredemo/Render/CursorArt.swift`
- Modify: `Soredemo/Render/CoreImageFrameRenderer.swift`, `Soredemo/Render/StageCompositor.swift`
- Create: `Tests/RenderTests/PointerPlacementTests.swift`

**Interfaces:**
- Consumes: `PointerTrack`, `PointerReading`, `NormalizedPointerPlacement`.
- Produces: `StagePlanner.placement(for:in:)`, `CursorArt.pointerPath(scale:)`,
  `CursorArt.ripplePath(phase:)`.

- [ ] **Step 1: write the failing placement test**

```swift
@Test func aNormalisedPointBecomesOutputPixelsInsideTheCard() {
    let plan = StagePlanner.plan(outputWidth: 1000, outputHeight: 1000,
                                 sourceWidth: 1000, sourceHeight: 1000, style: .default)
    let placement = StagePlanner.placement(for: NormalizedPoint(x: 0.5, y: 0.5), in: plan)
    #expect(abs(placement.x - 500) < 0.5)
    #expect(abs(placement.y - 500) < 0.5)
}

@Test func aPointerAtTheSourceOriginLandsAtTheCardsBottomLeft() {
    let plan = StagePlanner.plan(outputWidth: 1000, outputHeight: 1000,
                                 sourceWidth: 1000, sourceHeight: 1000, style: .default)
    let placement = StagePlanner.placement(for: NormalizedPoint(x: 0, y: 0), in: plan)
    #expect(abs(placement.x - plan.card.x) < 0.5)
    #expect(abs(placement.y - plan.card.y) < 0.5)
}
```

- [ ] **Step 2: run it, watch it fail, implement `placement(for:in:)`**

```swift
extension StagePlanner {
    /// A normalised point (bottom-left origin, 0…1 over the SOURCE) placed in output pixels.
    /// `NormalizedPoint` is already bottom-left — D3 — so there is no flip here, and there must
    /// not be one: the single conversion point is `NormalizationContext`, on entry.
    public static func placement(for point: NormalizedPoint, in plan: RenderPlan,
                                 ripplePhase: Double? = nil) -> NormalizedPointerPlacement {
        NormalizedPointerPlacement(x: plan.card.x + point.x * plan.card.width,
                                   y: plan.card.y + point.y * plan.card.height,
                                   ripplePhase: ripplePhase)
    }
}
```

- [ ] **Step 3: write `CursorArt.swift`**

A `CGPath` arrow (the classic pointer silhouette, white fill, black stroke) sized in output pixels,
and a ripple as a stroked circle whose radius grows and whose alpha falls with `ripplePhase`. Draw
both into a `CIImage` with `CIContext`'s `createCGImage`-free path: build a `CGContext` bitmap once
per distinct size, cache it, and composite.

- [ ] **Step 4: draw it in the renderer**

In `CoreImageFrameRenderer.render`, after the card composite, if `plan.pointer != nil` composite
the cursor art at the placement.

- [ ] **Step 5: feed the pointer from the track in `StageCompositor`**

Read the segment's observation log once, build a `PointerTrack`, and in `startRequest` compute
`track.position(at:)` for the request's composition time, mapping:

- `.drawn(p)` → `StagePlanner.placement(for: p, in: plan)`
- `.blind`, `.suppressedByReviewer`, `.noObservationYet` → `nil`, i.e. **no pointer drawn**

- [ ] **Step 6: THE HUMAN STEP — see the pointer move**

Record five seconds, move the mouse in a large circle, click twice. Confirm: the drawn pointer
follows the real motion, the ripple appears at each click, and the pointer is *not* drawn before the
first sample.

- [ ] **Step 7: commit**

```bash
git add Soredemo/Render Tests/RenderTests
git commit -m "cursor-render: a pointer we draw, and the four readings that decide whether to"
```

---

## Task 5.5: the first production caller of five things at once

**Added after Task 5, because Task 5's fix round proved the row it belongs to cannot be finished
without it.** `StageWindow`'s observation-log wiring is correct and finds nothing, because no
recording this app makes has a log. `cursor-render`'s name claims a drawn pointer; the product does
not draw one.

**Files:**
- Modify: `Soredemo/Capture/CaptureSession.swift`, `Soredemo/Capture/CapturePermissions.swift`,
  `Soredemo/UI/ContentView.swift`, `Soredemo.xcodeproj/project.pbxproj`
- Create: `Tests/AppSourceTests/ProductionCallerTests.swift`

**Interfaces:**
- Consumes: `InputObserver`, `AXObserver`, `ObservationWriter`, `NormalizationContext`,
  `CapturePermissions`.
- Produces: an observation log beside every recording, and the first executed path through all of
  the above.

**WHY THIS IS NOT A WIRING TASK, and must not be estimated like one.** Measured, right now:

| Type | Executed production call sites |
| --- | --- |
| `InputObserver` | **0** |
| `AXObserver` | **0** |
| `ObservationWriter` | 1, added by Task 5, read-only (`expectedLogURL`) |
| `NormalizationContext` | **0** — zero non-comment mentions anywhere outside its own file |
| `CGGeometryBridge`'s AX/input half | **0** — its render and capture halves do execute; the two call sites in `InputObserver.swift` and the two in `AXObserver.swift` never have |

Every previous time this project wrote a first production caller, that path produced a defect only
it could produce: `LiveAXElementSource`, `ObservationWriter`'s `@MainActor` trap, `CGGeometryBridge`,
and `dryRun()` writing where nothing read. Four for four. This task writes **five at once**, so a
high defect count is the expected outcome and not a sign the task went badly.

**Attach to `CaptureSession`, not to `RecordingCoordinator`.** The ROADMAP row says observation is
"`app-shell`'s job and there is no app shell yet", and taken literally that defers this forever.
`CaptureSession` already owns the stream, the clock and the sink. Wiring there means `app-shell`
inherits it; wiring into the UI means `app-shell` rewrites it, and that rewrite cost becomes the
argument for never doing it.

- [ ] **Step 1: make recording possible at all — the microphone entitlement**

Measured at the Task 4 human step: `CaptureSession.swift:727` sets
`configuration.captureMicrophone = true` unconditionally, the committed project declares neither
`ENABLE_RESOURCE_ACCESS_AUDIO_INPUT` nor `NSMicrophoneUsageDescription`, and under the hardened
runtime `tccd` says verbatim:

```
service: kTCCServiceMicrophone requires entitlement
com.apple.security.device.audio-input but it is missing
Policy disallows prompt
access to kTCCServiceMicrophone denied
```

The whole recording then fails. Add both build settings to `project.pbxproj` for both
configurations. Verify with `codesign -d --entitlements -` on the built app that
`com.apple.security.device.audio-input` is present.

- [ ] **Step 2: correct the degradation model, which currently states a consequence that does not happen**

`CapturePermissions.degradation(for: .microphone)` returns `noMicrophoneTrack`. The measured
consequence is that recording does not start at all. That file's own doc comment (line 9) demands
"a stated, distinct consequence that is what actually happens", so this row is presently the exact
thing the file forbids.

Fix the row to match measurement. Add a test in `Tests/AppSourceTests/ProductionCallerTests.swift`
that pins the mapping, and say in the test which measurement it encodes.

- [ ] **Step 3: ask for Screen Recording, once**

`CGRequestScreenCaptureAccess` occurs zero times in this repository. `SCStream` and
`SCContentSharingPicker` do not prompt. A first-run user is told "the user declined" by an API that
never asked them.

Call it before the picker opens. **Do not guard it with `status(of: .screenRecording) != .granted`**
— D6b row 18: `CGPreflightScreenCaptureAccess()` returned `granted` immediately after
`tccutil reset ScreenCapture`, and the next `SCStream.startCapture()` refused with `-3801`. That
guard never fires here, so a path behind it is dead code that reads like protection. The call is
idempotent: it prompts only in the never-asked state.

A previous attempt at this line exists at
`a skill chain/sdd/2026-08-03-phase-2b-render/orphan-screen-recording-prompt.diff` — read it for its
reasoning, then write your own.

- [ ] **Step 4: ask for Accessibility, once**

`AXIsProcessTrusted()` is read in `CapturePermissions.swift:185`. `AXIsProcessTrustedWithOptions`
with the prompt option occurs **zero** times. Same absence as Step 3, third service of the night.
Prompt once, before the AX walk's first use.

- [ ] **Step 5: construct the observers and the writer, in `CaptureSession`**

Open an `ObservationWriter` per segment beside the media, start an `InputObserver` and an
`AXObserver`, and route their records into it. The log's name must be the one
`ObservationWriter.expectedLogURL` already derives — Task 5 wired the reader against that
convention, and two naming schemes here is the two-instruments failure this project has paid for.

- [ ] **Step 6: measure what D6b row 14 was voided for**

Row 14 — *a pointer-only `.listenOnly` tap needs no Input Monitoring grant* — is **VOID, never
measured**: it was inferred from which spike step failed first, and every one of those steps ran
under an identity that already held both grants.

**Assume neither answer.** This task creates the first path that can settle it: a real first run
under the product's own identity, which has never asked for Input Monitoring. Record what actually
happens when the pointer tap is created without that grant — the tap's creation result and whether
pointer records appear — and report it verbatim. Do not request Input Monitoring pre-emptively to
make the run succeed; a grant spent to avoid a measurement spends the one never-asked state that
can answer this.

- [ ] **Step 7: the completion condition, and it is not "the observers were called"**

```
record five seconds
  → a log exists under observations/ beside the media
  → it contains a non-zero count of pointer readings and at least one AX chain
  → the drawn cursor moves in the preview
```

Steps 1–6 are machine-checkable and must be. The third line needs a person; write the checklist and
mark it UNVERIFIED, as Tasks 4 and 5 did.

- [ ] **Step 8: commit**

```bash
git add Soredemo/Capture Soredemo/UI Soredemo.xcodeproj/project.pbxproj Tests/AppSourceTests
git commit -m "The first production caller of five things at once"
```

---

## Task 6: the successor writer and the differential test across the seam

**Files:**
- Create: `Soredemo/Capture/SuccessorMasterWriter.swift`
- Create a probe section in `scripts/cross-boundary-digest-probe.swift`
- Modify: `scripts/run-cross-boundary-probe.sh`

**Interfaces:**
- Consumes: `MasterWriting`, `MasterTrackWriting`, `MasterWriterStatus`.
- Produces: `SuccessorMasterWriter: MasterWriting`.

**Two implementations of one behaviour with nothing comparing them is the failure the
definite-singular audit's row 3 names.** This is the task that makes the seam trustworthy.

- [ ] **Step 1: write `SuccessorMasterWriter.swift`**

Same shape as `LegacyMasterWriter`, on `AVAssetWriter.start()`, `inputReceiver(for:)` and
`appendImmediately(_:)`. **Do not call `add(_:)` and do not call `startWriting()`** — mixing the two
generations put the writer in a state nobody designed and stalled at frame 137, measured in
`spikes/2026-08-03-writer-receiver-hang`. Order: take every receiver, then `start()`, then
`startSession(at:)`.

- [ ] **Step 2: write the differential probe section**

Feed identical input to both conformances and compare the **facts of the finished files, read back
from the asset** — never each writer's account of itself:

```swift
for (label, writer) in [("legacy", legacyWriter), ("successor", successorWriter)] {
    // … append the same 120 video frames and two audio streams to each …
}
let legacyFacts = try await inspect(legacyURL)
let successorFacts = try await inspect(successorURL)
check(legacyFacts.audioTrackCount == successorFacts.audioTrackCount,
      "both writers produce the same number of audio tracks — the property that decided "
      + "AVAssetWriter over SCRecordingOutput",
      actual: "legacy \(legacyFacts.audioTrackCount), successor \(successorFacts.audioTrackCount)")
check(legacyFacts.colourTags == successorFacts.colourTags,
      "both writers tag colour identically — uncontrolled colour tagging cost this project an "
      + "evening, and a redesign changes defaults",
      actual: "legacy \(legacyFacts.colourTags), successor \(successorFacts.colourTags)")
check(legacyFacts.audioTrackCount == 2 && successorFacts.audioTrackCount == 2,
      "and the shared value is the RIGHT one — two writers that agree on 1 would pass the "
      + "comparison above and both be wrong")
```

The third check is not redundant: a comparison alone passes when both sides are equally broken.

- [ ] **Step 3: run the probe, then commit**

```bash
./scripts/run-cross-boundary-probe.sh
git add Soredemo/Capture/SuccessorMasterWriter.swift scripts/
git commit -m "The second MasterWriting, and the test that compares the two finished files"
```

---

## Task 7: `export-basic` — one playable MP4

**Files:**
- Create: `Soredemo/Export/MP4Exporter.swift`
- Modify: `Soredemo/UI/StageWindow.swift` (an Export command)

**Interfaces:**
- Consumes: `CompositionBuilder.composition(for:outputWidth:outputHeight:frameDuration:)`,
  `SuccessorMasterWriter`.
- Produces: `MP4Exporter.export(asset:to:outputWidth:outputHeight:) async throws -> ExportReport`.

**Scope, restated because it grows quietly:** one MP4 (H.264). No GIF, no ProRes, no poster frame,
no written steps, no post copy.

- [ ] **Step 1: write the exporter**

`AVAssetReader` with an `AVAssetReaderVideoCompositionOutput` carrying the **same**
`AVVideoComposition` the preview uses, feeding a `SuccessorMasterWriter`. **Export never drops**:
when the writer is not ready, wait; do not skip a frame.

- [ ] **Step 2: assert the export dropped nothing**

`ExportReport` carries `framesRead` and `framesWritten`, and the exporter throws if they differ. A
count that is only reported is a count nobody reads.

- [ ] **Step 3: THE HUMAN STEP — play the file**

Export a recording, open the result in **QuickTime**, and confirm it plays with the framing and the
drawn pointer in it. This is the sentence the whole phase closes on.

- [ ] **Step 4: commit**

```bash
git add Soredemo/Export Soredemo/UI
git commit -m "export-basic: one playable MP4, and an export that never drops a frame"
```

---

## Task 8: `render-parity` and the preview's dropped-frame count

**Files:**
- Create: `Tests/RenderParityFixtures/` (a committed 2-second `.mov`, the `.gitignore` negation
  already exists), a probe section comparing preview and export output
- Modify: `Soredemo/Render/StageCompositor.swift` (drop counting)

- [ ] **Step 1: count preview drops as a stored value**

The preview path may drop; the count is a value the recording carries, not a console line. "What
you review is what ships" is false at exactly the frames the preview skipped, and a number is what
keeps that from being a surprise.

- [ ] **Step 2: the parity check**

Render the same composition time through the preview path and the export path, and compare the two
frames pixel by pixel with a documented tolerance. **The tolerance is a number in the check's own
message**, not a constant somewhere else.

- [ ] **Step 3: observe it fail**

Change `StageStyle.default.insetFraction` by 0.01 in one path only and confirm the parity check goes
red. Revert. A parity check nobody has seen fail is a parity check that compares a value to itself.

- [ ] **Step 4: update the registers and the ROADMAP**

- `docs/ARCHITECTURE.md` D6a: two rows — the drawn pointer's substitution (shape information lost),
  and preview frames dropped.
- `ROADMAP.md`: tick the six Phase 2B rows **and** the Phase 2 rows that only now became observable
  in the product, with the evidence for each.

- [ ] **Step 5: commit**

```bash
git add Tests/RenderParityFixtures Soredemo/Render docs/ARCHITECTURE.md ROADMAP.md scripts/
git commit -m "render-parity, the preview's drop count, and the rows that are now observable"
```

---

## Self-review notes

- **Spec coverage.** § 0 completion condition → Tasks 4, 5, 7 human steps. § 1 scope → Task 7. § 2.1
  blind policy → Task 2 (all three clauses; clause 1's "motion in flight" is the *reading*, since
  camera motion is Phase 3). § 2.2 cursor → Tasks 2 (`CursorOverride`) and 5. § 2.3 time budgets →
  Tasks 7 and 8. § 2.4 differential test → Task 6. § 3 structure and the compositor seam → Tasks 1
  and 3. § 5 open item 1 (which target) → Task 1 answers it: a new `Render` target.
- **Open item 2** (the blind-fraction threshold) is deliberately not implemented: the default is to
  surface every interval, and the threshold arrives with a real recording to choose it against.
- **Open item 3** (Core Image vs Metal) stays open by construction — Task 3 builds the seam and one
  implementation, and the scan in Task 3 step 1 is what keeps the second one possible.
