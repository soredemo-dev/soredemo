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

The manifest records schema and script identity, pinned Playwright and Chromium versions, CSS viewport dimensions, `deviceScaleFactor: 2`, capture origin, and frame count. Each frame record stores its index, file, calibrated CDP timestamp, pixel dimensions, page scale factor, scroll offsets, and offset top. Node receive time is diagnostic only.

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

Click execution must scroll the locator into view, establish actionability and stability, capture the initial box, generate one cursor path, dispatch every path point with `page.mouse.move()`, capture the commit box, hit-test the click point, and then dispatch `page.mouse.down()` and `page.mouse.up()`. A failed hit test fails loudly. `locator.click()` is not a fallback.

## Coordinate and clock contract

- Targets, bounding boxes, click points, and cursor paths use CSS pixels.
- Bounding boxes are viewport-relative unless a contract explicitly says otherwise.
- Captured pixel dimensions are stored separately from the CSS viewport.
- Every timeline millisecond is relative to one capture origin.
- CDP and driver timestamps are calibrated once at capture startup.
- CDP screencast timestamps are the frame timing authority.
- Node frame-arrival time is diagnostic only and never aligns streams.
- Every frame receives `Page.screencastFrameAck` only after its bytes have been copied into the capture queue.
- The same generated cursor path drives real Playwright mouse events and later visible composition.

Soredemo promises structural reproducibility, not pixel determinism across machines or runs. Core capture does not use JavaScript virtual-time tricks.

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
