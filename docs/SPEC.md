# Soredemo specification

## Product thesis

Soredemo (それでも, “nevertheless”) is a version-controlled demo compiler for web products. It turns a declarative YAML Demo Plan into a polished video of a real web application. It can be described as “VHS for web UIs,” “Scriptable Screen Studio,” and the product communication layer for agent-built software.

Soredemo is not an embedded AI model. The MIT-licensed CLI does not call an LLM and does not require an AI-provider key. An external coding agent such as Claude Code, Codex, or Cursor acts as the director because it already understands the repository, routes, documentation, tests, and running application.

The external agent owns feature selection and the meaningful user journey. It follows this priority:

1. explicit user goal;
2. existing demo script or catalog;
3. repository evidence such as routes, README files, stories, and end-to-end tests;
4. exploration of the running application;
5. asking the user when materially different goals remain.

Soredemo never silently chooses which product feature to demonstrate. It owns deterministic validation, browser execution, capture timing and coordinates, camera and cursor choreography, composition, and encoding.

## Pipeline

```text
Human demo intent
        │
        ▼
External coding agent writes a version-controlled Demo Plan
        │
        ▼
Schema validation and normalization
        │
        ▼
Phase 1: Playwright + Chromium CDP driver
        │  real events, raw frames, timestamped metadata
        ▼
Capture bundle (.capture/)
        │
        ▼
Phase 2: @napi-rs/canvas compositor
        │  camera, cursor, ripple, chrome, mask, shadow, background
        ▼
Encoder boundary → FFmpeg → 1920×1080, 30 fps, H.264, yuv420p MP4
```

Phase 1 never bakes a visible cursor or camera effect into browser pixels. Phase 2 can be rerun against a capture bundle without reopening the browser.

## Project configuration and Demo Plans

Project mechanics and video narratives are separate.

`soredemo.config.yaml` describes how to run and reach the application, optional authentication state, browser defaults, and project defaults. Future discovery may use `cosmiconfig` for `soredemo.config.yaml`, `.soredemorc`, or `package.json#soredemo`.

`demos/*.yaml` describes what the browser does and what the video communicates. An explicitly supplied Demo Plan always follows:

```text
fs.readFile → js-yaml → ScriptInputSchema → normalizeScript() → ActionPlan
```

It is never loaded through `cosmiconfig`. Credentials and secret values are forbidden in Demo Plans and timeline artifacts.

## Author input and normalized plan

`ScriptInputSchema` contains JSON-Schema-representable definitions only. It has no transforms. Zod v4 generates `schema/soredemo.schema.json` as draft 2020-12 input schema.

The required author input is:

```yaml
version: 1
name: create-project
url: http://127.0.0.1:4173/
intent:
  goal: Show how quickly a user can create a project
  targetDurationMs: 18000
actions: []
```

`url` is initial-navigation metadata, not a visible `goto` action. `intent.targetDurationMs` is a direction target, not a promise or an automatic fitting request.

`normalizeScript()` independently applies defaults and produces a fully normalized `ActionPlan`. Initial defaults are a 1440×900 CSS-pixel viewport and `{ preset: studio, pace: balanced, seed: 0 }`. The normalized plan remains distinct from the execution timeline: it has no resolved selectors, timestamps, cursor paths, or captured bounding boxes.

## Semantic targets

Author-facing targets use exactly one strategy:

```ts
type Target =
  | { role: string; name?: string }
  | { label: string }
  | { testId: string }
  | { text: string; exact?: boolean }
  | { css: string }
```

Resolution preference is role and accessible name, label, test ID, text, then CSS. CSS remains an escape hatch. Timeline events store the resolved strategy, values, coordinates, and bounding boxes.

## Browser actions

v0.1 contains exactly six action kinds: `goto`, `wait`, `moveTo`, `click`, `type`, and `scrollTo`.

- `goto` performs subsequent navigation only.
- `wait` accepts either a positive `durationMs` or a semantic `until.visible` condition with optional timeout and settling time.
- `moveTo` is used when hover itself matters.
- `click` automatically moves the real browser cursor before mouse down and up. It may carry `emphasis` and `focusAfter` narrative metadata.
- `type` will use Playwright `pressSequentially()` and record per-key timing.
- `scrollTo` accepts either a semantic target or coordinates, never both. Coordinate `x` normalizes to zero. Both forms perform real controlled browser scrolling in the future driver.

## Capture artifact

Phase 1 produces a directory, not an intermediate video:

```text
.capture/
├── manifest.json
├── frames/
│   ├── 000001.jpg
│   └── 000002.jpg
├── frames.jsonl
└── timeline.json
```

The manifest records schema and script identity, pinned Playwright and Chromium versions, CSS viewport dimensions, `deviceScaleFactor: 2`, observed browser metrics and JPEG dimensions, capture origin, frame count, clock diagnostics, and bounded-queue diagnostics. Each frame record stores its index, file, normalized CDP frame timestamp, pixel dimensions, page scale factor, scroll offsets, offset top, and diagnostic receive time.

The capture implementation preserves a 1440×900 CSS viewport with device scale factor 2 while configuring an explicit 2880×1800 CDP visible capture surface. It verifies `window.innerWidth`, `window.innerHeight`, `window.devicePixelRatio`, and every JPEG dimension rather than assuming CDP honors the requested scale. Day-2 frame-only bundles omit `timeline.json`; captures containing actions include it.

## Timeline contracts

Timeline events are an action-specific discriminated union:

```ts
type ActionKind = "goto" | "wait" | "moveTo" | "click" | "type" | "scrollTo"

interface TimelineEventBase {
  id: string
  kind: ActionKind
  startMs: number
  endMs: number
}

interface ClickTimelineEvent extends TimelineEventBase {
  kind: "click"
  target: ResolvedTarget
  targetBboxAtPathStart: BBox
  targetBboxAtCommit: BBox
  clickPoint: Point
  cursorPath: TimedPoint[]
  mouseDownMs: number
  mouseUpMs: number
}

interface MoveToTimelineEvent extends TimelineEventBase {
  kind: "moveTo"
  target: ResolvedTarget
  targetBbox: BBox
  cursorPath: TimedPoint[]
}

interface ScrollTimelineEvent extends TimelineEventBase {
  kind: "scrollTo"
  samples: Array<{ timeMs: number; scrollX: number; scrollY: number }>
}
```

`goto`, both `wait` forms, and `type` have their own variants. Unrelated event types are never forced into one fixed object shape.

Click execution must scroll the locator into view, establish actionability and geometric stability, capture the initial box, choose one click point, generate one cursor path, dispatch every path point with `page.mouse.move()`, allow hover effects to settle, capture the commit box, hit-test the original click point, and then dispatch `page.mouse.down()` and `page.mouse.up()`. A failed containment or hit test fails loudly. `locator.click()`, DOM `.click()`, and synthetic click events are not fallbacks.

`ghost-cursor` supplies geometry through its exported `path()` function only. Its timestamps are reduced to relative spacing and rescaled to a restrained movement duration. For each accepted point, Soredemo waits for the proposed driver-monotonic schedule and records the measured midpoint around the real Playwright mouse command. The resulting coordinates and measured times are the single cursor path used by browser events, timeline metadata, and future composition.

## Coordinate and clock contract

- Targets, bounding boxes, click points, and cursor paths use CSS pixels.
- Bounding boxes are viewport-relative unless a contract explicitly says otherwise.
- Captured pixel dimensions are stored separately from the CSS viewport.
- Every timeline millisecond is relative to one capture origin.
- CDP `Page.screencastFrame` timestamps are epoch-based `Network.TimeSinceEpoch` seconds, not monotonic timestamps.
- The first accepted CDP frame epoch defines the capture origin and each frame timestamp is normalized against it.
- Driver events use Node's monotonic `performance.now()` clock.
- Startup calibration maps Node monotonic time to browser epoch time using a Chromium epoch sample and the Node request midpoint; the lowest-round-trip of nine samples is selected.
- The startup mapping remains fixed for the capture. Ending calibration measures drift but never retimes frames or events.
- CDP screencast timestamps are the frame timing authority.
- Mapped Node frame-arrival time is diagnostic only and never aligns streams.
- Every frame receives `Page.screencastFrameAck` only after its bytes have been copied into the capture queue.
- The same generated cursor path drives real Playwright mouse events and later visible composition.
- Browser-observed capture-phase `pointerdown` and `pointerup` events supply canonical click times.

Soredemo promises structural reproducibility, not pixel determinism across machines or runs. Core capture does not use JavaScript virtual-time tricks.

## Timestamp frame resampling

The source capture has variable cadence. Before composition, Soredemo creates a metadata-only 30 fps selection plan. Output time is independently derived from each integer index:

```text
outputTimestampMs = outputIndex × 1000 / 30
outputFrameCount = floor(sourceDurationMs × 30 / 1000) + 1
```

Frame zero is at 0 ms, and no output timestamp exceeds the last CDP source-frame timestamp. The streaming two-pointer selector retains the closest source frame at or before output time and the first source frame after it. It selects the smaller timestamp distance; an exact tie selects the earlier source frame. It does not sort invalid captures, inspect receive time or filesystem timestamps, decode JPEGs, interpolate pixels, or infer an average capture rate.

The reader incrementally validates `frames.jsonl` order, consecutive indices, canonical unique filenames, strict timestamps, native dimensions, manifest invariants, and referenced-file existence. The resampler retains only adjacent source records, current output state, bounded P² aggregate estimators, and the small set of requested event mappings.

Three timestamps remain distinct:

```text
timeline event time       preserves interaction semantics
fixed output time         evaluates camera, cursor, and visual metadata
selected source time      selects captured browser pixels only
```

The compositor must evaluate cursor and camera metadata at output time, never at the selected source timestamp. Event timestamps are not shifted onto the 30 fps grid.

## Minimal composition and RGBA boundary

The compositor consumes resample records sequentially. It resolves each selected JPEG inside the capture bundle, decodes or reuses one current source image, draws into one reusable 1920×1080 canvas, extracts one raw RGBA frame, and awaits the frame consumer before advancing. It never retains the complete decoded or RGBA sequence.

The Day-5 base layer preserves source aspect ratio using contain geometry. A 2880×1800 capture draws at `{ x: 96, y: 0, width: 1728, height: 1080 }` over an opaque black matte. This layout is provisional; final browser-window placement, chrome, mask, shadow, and background remain later composition concerns.

The raw boundary is 1920×1080 RGBA with top-to-bottom rows, left-to-right pixels, a 7,680-byte stride, and 8,294,400 bytes per frame. Alpha is fully opaque. The sequential consumer contract provides backpressure for the future encoder without implementing encoding in the compositor.

For every composed frame, selected source time continues to choose browser pixels and fixed output time continues to evaluate composition metadata. Decoding and drawing never collapse or retime timeline event, output, and source timestamps.

## Screen-space cursor composition

The visible cursor is a bundled SVG decoded once at compositor startup. Its definition fixes intrinsic dimensions, rendered dimensions, and arrow-tip hotspot. Recorded cursor coordinates remain CSS viewport pixels and transform into the contained application rectangle:

```text
screenX = contentRect.x + cssX × contentRect.width / cssViewport.width
screenY = contentRect.y + cssY × contentRect.height / cssViewport.height
```

The compositor preserves fractional screen coordinates and draws at the screen hotspot minus the scaled asset hotspot. Cursor raster size is constant in output pixels. Device scale factor, source JPEG dimensions, contain scale, and future browser-camera transforms do not resize it. Browser and future camera transforms belong below the cursor layer.

The cursor track directly joins the measured Day-3 paths. It is hidden before the first point, linearly interpolates dense measured points at fixed output time, holds each final point until the next movement, and holds the final position through composition end. It never regenerates, smooths, or retimes the path. The cursor renders after browser pixels and any future click feedback, so it remains the topmost visual layer.

## Post-production camera

Camera state is defined in CSS viewport coordinates as zoom plus a CSS-space center. Zoom never falls below 1, and the center is clamped at every evaluated output frame so the visible CSS rectangle remains inside captured pixels. The visible rectangle converts to source JPEG pixels using the separately recorded source-to-CSS scale and is drawn into the complete content rectangle with Canvas source cropping. The compositor never changes browser layout, viewport, hit testing, or live DOM state.

One shared projection maps browser-space coordinates through the current camera:

```text
outputX = contentRect.x + (cssX - visibleCssRect.x) / visibleCssRect.width × contentRect.width
outputY = contentRect.y + (cssY - visibleCssRect.y) / visibleCssRect.height × contentRect.height
```

Target bounds, click points, and the cursor hotspot use this exact projection. Browser pixels and cursor hotspot position therefore move together, while the SVG raster and hotspot offset remain fixed at 30×38 output pixels. At zoom 1, the projection is exactly the Day-6 CSS-to-content mapping.

The initial studio policy holds a 600 ms establish shot, anticipates each recorded cursor path by 120 ms, settles camera motion 100 ms before the corresponding mouse down where timing permits, and uses non-overlapping 350–700 ms transitions. A single `cubic-bezier(0.22, 1, 0.36, 1)` curve eases center and zoom from authoritative camera states. Commit-time target bounds determine deterministic padded focus states in the 1.25–1.35 zoom range. These constants remain internal preset policy rather than author-facing YAML parameters.

The Day-7 track frames clicked controls only. Narrative result framing from resolved `focusAfter` targets will be connected when full Demo Plan execution produces those timeline targets.

## Cinematic direction

The studio preset uses a restrained shot grammar:

1. Establish the whole application and spatial context.
2. Anticipate a meaningful interaction by leading cursor arrival with camera movement.
3. Focus without excessive zoom.
4. Settle after the action while the interface stabilizes.
5. Reveal the result, which may differ from the clicked target.

Not every action receives a zoom. Primary interactions and success reveals receive stronger emphasis; secondary actions may retain the current frame. Camera zoom and pan operate only on captured pixels. They never replace real document scrolling and cannot reveal pixels outside the captured viewport.

The only v0.1 visual preset is `studio`, with `fast`, `balanced`, and `calm` pacing. Low-level animation parameters are preset-owned rather than exposed as a large author API.

## Independent future media tracks

The future composition boundary is:

```text
browser track
+ cursor and camera metadata
+ presenter video track
+ narration audio track
+ caption track
+ optional music track
→ final composition
```

Browser capture never owns webcam or microphone recording. Independent timestamped tracks permit presenter or narration replacement without rerunning browser actions. No presenter, webcam, audio, caption, narration, TTS, or music dependency belongs in v0.1.

## Platform and determinism

macOS is the v0.1 manual verification, golden-frame, performance, and initial release authority. The implementation remains platform-agnostic and uses no mandatory macOS-only API. Chromium is the only v0.1 browser because raw Playwright CDP sessions are Chromium-specific. Software `libx264` is the baseline encoder; future VideoToolbox support may be optional but never exclusive.

## v0.1 scope

Included: Chromium; YAML plans; six browser actions; semantic targets; condition and duration waits; human-like typing; real scrolling; timestamped capture bundles; cursor choreography; post-production camera; one gradient; macOS-style browser chrome; studio preset; 1920×1080; 30 fps; MP4.

Explicitly excluded: 4K; MDX; audio; microphone; TTS; webcam; presenter studio; captions; music; transition types beyond hard cuts; Windows or Linux browser chrome; interactive HTML export; cloud rendering; collaboration; embedded LLM calls; autonomous feature selection; and an MCP server.

Soredemo Cloud may later provide hosted rendering and team workflows, but the local MIT engine retains complete validation, capture, composition, and rendering capabilities.
