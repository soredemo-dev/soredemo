# Day 10: public MVP render pipeline

Day 10 connected the accepted capture, resampling, studio composition, and system-FFmpeg modules behind the public `soredemo render` command. A user supplies a validated YAML Demo Plan for an already-running HTTP or HTTPS application and receives an atomically published, probed MP4.

## Public contract

```bash
soredemo render demo.yaml --out output/demo.mp4
```

When `--out` is omitted, the output is written beside the plan using its basename and an `.mp4` suffix. Existing output files and directory paths are rejected before Chromium or FFmpeg is loaded. `--keep-artifacts` preserves the run workspace, and `--json` keeps stdout to one final structured result while stage diagnostics use stderr.

Configuration discovery walks from the Demo Plan directory toward the filesystem root and uses the first `soredemo.config.yaml`. v0.1 enforces the accepted 1440×900 CSS viewport, device scale factor 2, and 1920×1080 at 30 fps output. Project startup and authentication remain external responsibilities.

## Action execution

The production executor runs actions sequentially and records one discriminated timeline event per plan entry. Semantic targets use exactly the requested Playwright locator strategy; zero and ambiguous matches fail instead of falling back or selecting the first result.

The six implemented actions are:

- `goto`: bounded HTTP(S) navigation to `domcontentloaded`, followed by cursor-hiding and instrumentation verification;
- `wait`: monotonic duration waits or semantic visible conditions with a settle interval;
- `moveTo`: one accepted `ghost-cursor` geometry path dispatched through real Playwright mouse movement;
- `click`: the accepted move, commit-bbox, hit-test, real mouse-down/up, and browser-observed event flow;
- `type`: real mouse focus and deterministic keyboard events at 18, 32, or 48 ms per character according to pace;
- `scrollTo`: target or coordinate scrolling through real browser smooth scrolling with bounded position samples.

Typed plaintext is not copied into the timeline. Type events record text length, timing, clear behavior, and password redaction state.

Package-generated cursor timestamps occasionally contained equal adjacent values during the gate. Soredemo now deterministically coalesces equal-time proposals before the path is accepted. The resulting accepted point array is used unchanged for browser dispatch, the timeline, and composition; no latency or coordinate offset is added.

## Workspace and lifecycle

Each render uses an isolated `.soredemo/runs/<run-id>/` workspace containing capture, resample, encoding, and run-manifest artifacts. Success deletes the workspace unless `--keep-artifacts` is set. Failure and interruption preserve it. The run manifest is atomically updated through initialization, capture, resampling, composition, encoding, validation, and completion or failure.

SIGINT and SIGTERM abort the current action, active encoder, browser session, and child processes before returning. The controlled interruption gate preserved an `aborted` manifest, published no final output, left no partial MP4, and left no Chromium or FFmpeg process.

## Authoritative fixture result

Command:

```bash
pnpm soredemo render test/fixtures/full-demo.yaml \
  --out .tmp/day10-e2e/soredemo-day10.mp4 \
  --keep-artifacts \
  --json
```

Environment: Node 20.19.4, pnpm 10.34.0, Playwright 1.61.1, Chromium 149.0.7827.55, `@napi-rs/canvas` 1.0.2, and Homebrew FFmpeg 8.0 on macOS arm64.

The plan completed ten entries covering all six action kinds. Its production timeline contained consecutive action indexes and ordered capture-relative timestamps. The target scroll moved from `y=0` to `y=1298` with 70 retained samples. The type event recorded eight characters at 32 ms per character. Four cursor-bearing actions contributed 696 accepted points.

Capture and output:

- capture duration: 11,548.779 ms;
- capture frames: 741 JPEGs, all 2880×1800;
- capture queue: 741 received, acknowledged, and written; high-water mark 4; zero overflow or write failure;
- output frames: 347 at 30 fps;
- media duration: 11.566667 seconds;
- output: H.264 High profile, level 4.0, yuv420p, 1920×1080, BT.709, zero audio, fast-start;
- MP4 size: 388,435 bytes;
- MP4 SHA-256: `a215ae8f1da8ec4ec43a7de35ce2b13ad1afaf17944a852f2baf1a0ff71520e0`;
- total public-command time: 41,963.672 ms.

The camera track contained 11 segments and the click-feedback track contained two ripples. Both click mappings evaluated held cursor state with median, p95, and maximum landing error of zero output pixels. Both target bboxes were fully visible and contained their projected click points.

Every RGBA write observed FFmpeg backpressure: 347 writes returned false and 347 drains were awaited. Maximum pending state remained one 8,294,400-byte frame. Parent RSS peaked at 345,030,656 bytes. Diagnostic FFmpeg RSS peaked at 762,429,440 bytes. Both processes remained individually below 1 GiB; their approximate simultaneous sum is close enough to 1 GiB to warrant continued memory monitoring.

## Packed-package gate

The 174-entry npm tarball included the production cursor and runtime modules but no fixture, spike script, capture, MP4, log, snapshot, or temporary output. An isolated Node 20 project installed the tarball and ran:

```bash
npx --no-install soredemo render demo.yaml --out rendered.mp4 --keep-artifacts --json
```

It produced 314 validated frames over 10.466667 seconds. The 376,742-byte MP4 SHA-256 was `8dbb6556eaa93b3ab64c856af6320bf653bafc5dcd384f8973294e3a89feb05c`. Landing error remained zero and encoder pending state remained one frame.

## Risks for Day 11

- One disposable interruption attempt observed a CDP timestamp move backward by 9.548 ms. The capture failed loudly and preserved diagnostics as required; no correction or receive-time substitution was applied. Frequency and Chromium-version behavior need continued observation.
- Combined parent-plus-FFmpeg RSS approached 1 GiB during the repository gate even though each process passed its individual bound.
- Camera focus currently uses move, type, click, and target-scroll geometry. Narrative `focusAfter` result framing remains deferred.
- Progress output is intentionally stage-level only. Stable error presentation and diagnostic polish remain Day-11 work.
- The command assumes the application is already running and system FFmpeg/FFprobe with `libx264` are installed.
