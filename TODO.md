# Soredemo implementation plan

| Day | Goal |
| --- | --- |
| 1 | Repository scaffold, CLI skeleton, schema, loader, validation, fixture, documentation |
| 2 | CDP screencast and capture-clock spike |
| 3 | Cursor events, timeline capture, and Day-3 capture gate |
| 4 | Timestamp frame resampler |
| 5 | Minimal canvas compositor |
| 6 | Cursor composition and Day-6 landing gate |
| 7 | Camera framing and easing |
| 8 | Browser chrome, mask, shadow, and background |
| 9 | Encoder interface and FFmpeg output |
| 10 | Complete the six browser actions and semantic target handling |
| 11 | Error handling, diagnostics, and CLI polish |
| 12 | Golden-frame visual regression testing |
| 13 | End-to-end `npx` flow and README |
| 14 | Buffer, cleanup, and record Soredemo’s own demo using Soredemo |

## Day 1 status

- [x] Initialize the Git repository and single-package pnpm scaffold.
- [x] Add strict TypeScript, Biome, Vitest, MIT license, and npm publish allowlist.
- [x] Implement JSON-Schema-compatible Zod v4 input schemas and normalized types.
- [x] Support target-based and coordinate-based `scrollTo` without mixing forms.
- [x] Implement explicit-path YAML loading and stable human/JSON diagnostics.
- [x] Generate and check in draft 2020-12 JSON Schema.
- [x] Add lazy `validate` and Day-1 `render` commands with fixed exit codes.
- [x] Add a local example demonstrating all six actions.
- [x] Add the deterministic fixture and test server helper.
- [x] Add schema, loader, diagnostics, CLI, fixture, and import-boundary tests.
- [x] Record the specification and accepted architecture decisions.
- [x] Run the final acceptance command sequence and packaged-binary verification.

## Day 2 status

- [x] Verify Day-1 gates and the fixture server on normal macOS.
- [x] Run the CLI, tests, and capture spike under Node.js 20.
- [x] Pin Playwright 1.61.1 and install its Chromium 149.0.7827.55 revision.
- [x] Add midpoint clock calibration using the lowest-round-trip of nine samples.
- [x] Capture ordered CDP JPEG frames into a bounded, acknowledged write queue.
- [x] Record frame, environment, clock, queue, and screencast diagnostics in the bundle.
- [x] Parse and verify every JPEG's native dimensions without an image dependency.
- [x] Add an offline deterministic animated fixture probe.
- [x] Complete three six-second trials at 2880×1800 with no loss, overflow, duplicate timestamps, or backward timestamps.
- [x] Preserve the validation command's heavy-import boundary.
- [x] Record the spike procedure, results, failures, and risks.

## Day 3 status

- [x] Align the exact pnpm toolchain with the Node 20 minimum.
- [x] Add exact `ghost-cursor@1.4.2` and verify its permissive production license tree.
- [x] Use only exported path generation and own all Playwright dispatch and timing.
- [x] Inject capture-phase pointer and mouse event instrumentation before application scripts.
- [x] Hide the browser cursor and verify `cursor: none` on both click targets.
- [x] Record versioned click timeline events with initial and commit bboxes.
- [x] Add static and hover-growing deterministic fixture targets with application counters.
- [x] Complete one continuous 30-click native-resolution capture with exact event counts.
- [x] Verify every local ±250 ms mouse-down frame window remains below 100 ms.
- [x] Verify capture bundle, timeline, clock, coordinate, and queue integrity.
- [x] Add path, mouse, event, timeline, cadence, and statistics unit tests.
- [x] Record the Day-3 gate results and Day-4 risks.

## Day 4 status

- [x] Generate every 30 fps output timestamp directly from its integer frame index.
- [x] Stream and validate capture JSONL without reading JPEG bytes.
- [x] Select the nearest CDP source timestamp with an earlier-frame tie break.
- [x] Write a deterministic metadata-only resample plan and manifest.
- [x] Keep timeline, fixed-output, and selected-source timestamps distinct.
- [x] Map all 30 Day-3 mouse-down events to output and source frames.
- [x] Calculate bounded full-plan statistics and exact small event diagnostics.
- [x] Add malformed capture, clock, selection, reuse, event, and statistics tests.
- [x] Run the real 5,428-frame Day-3 bundle without modifying or copying it.
- [x] Verify the resample plan contains 1,751 records and no image files.
- [x] Record the Day-4 trial results and Day-5 risks.

## Day 5 status

- [x] Pin `@napi-rs/canvas@1.0.2` and verify its MIT native-package tree.
- [x] Add deterministic contain geometry and an opaque RGBA base layer.
- [x] Resolve source paths safely inside the capture bundle.
- [x] Reuse one decoded image and one output canvas.
- [x] Preserve output and selected-source timestamps in every raw frame.
- [x] Honor sequential frame-consumer backpressure.
- [x] Hash every RGBA frame incrementally without writing raw files.
- [x] Write six deterministic proof snapshots and a composition manifest.
- [x] Prove same-machine determinism with two 22-frame subset executions.
- [x] Diagnose and replace the unbounded `getImageData()` extraction path.
- [x] Complete all 1,751 frames below the 1 GiB memory gate.
- [x] Record the Day-5 trial results and Day-6 risks.

## Day 6 status

- [x] Bundle an independently drawn 30×38 SVG cursor with hotspot `(2, 2)`.
- [x] Include the production cursor asset in the npm publish allowlist.
- [x] Validate and join all 30 recorded paths without regeneration or retiming.
- [x] Evaluate the global cursor track sequentially at fixed output timestamps.
- [x] Transform CSS cursor coordinates into fractional output-screen coordinates.
- [x] Render the fixed-size cursor above the browser base layer.
- [x] Verify declared hotspot placement with synthetic marked-pixel tests.
- [x] Measure all 30 real mouse-down landings from actual draw geometry.
- [x] Produce 30 landing crops and four unique full-frame snapshots.
- [x] Preserve bounded `canvas.data()` readback below the 1 GiB gate.
- [x] Prove deterministic cursor composition with two fresh subset executions.
- [x] Record the Day-6 gate results and Day-7 risks.

## Day 7 status

- [x] Pin `bezier-easing@3.0.1` and verify its dependency-free MIT production tree.
- [x] Define camera state, focus policy, clamping, source crops, and projection in CSS viewport coordinates.
- [x] Build a deterministic 30-transition track with establish, transition, and hold segments.
- [x] Ease camera state only at fixed output timestamps.
- [x] Crop browser pixels with the nine-argument Canvas draw path.
- [x] Project targets, click points, and cursor hotspots through one shared camera function.
- [x] Keep the cursor SVG fixed at 30×38 output pixels under zoom.
- [x] Keep all 30 targets fully visible and every projected click inside its commit bbox.
- [x] Preserve zero-error cursor landing across all 30 camera-aware mouse-down frames.
- [x] Complete all 1,751 frames with zero unsafe crops below the 1 GiB memory gate.
- [x] Prove deterministic camera composition with two fresh subset executions.
- [x] Record the Day-7 gate results and Day-8 risks.

## Day 8 status

- [x] Add the fixed centered v0.1 studio window and browser-content geometry.
- [x] Draw one opaque three-stop gradient without assets or randomness.
- [x] Add a compatibility-safe manual rounded-rectangle path shared by clip, shadow, and border.
- [x] Render a light toolbar, separator, and fixed traffic-light controls without fonts.
- [x] Clip camera-cropped browser pixels to the complete rounded window.
- [x] Pre-render the invariant shadow into one bounded cached layer and restore Canvas state.
- [x] Add deterministic 260 ms camera-aware click feedback from browser-observed mouse-down times.
- [x] Preserve the 30×38 output-screen cursor as the topmost layer.
- [x] Preserve zero-error landing and full target visibility across all 30 clicks.
- [x] Complete all 1,751 frames with zero mask leaks or black output corners.
- [x] Write ten review snapshots and a deterministic contact sheet.
- [x] Prove deterministic studio composition with two fresh subset executions.
- [x] Record the manual visual review, performance warning, and Day-9 risks.

## Session notes

- The Day-1 managed-sandbox `EPERM` was environmental: the fixture server served all local assets successfully over loopback on normal macOS, and Chromium rendered it with non-loopback requests blocked.
- The first temporary tarball installation used pnpm offline mode, but the local store lacked registry tarball metadata for `citty`. Retrying the isolated install with registry access succeeded; the packed `soredemo` binary then passed all exit-code checks.
- Production runtime licenses currently report ISC for `ghost-cursor`; Apache-2.0 for Playwright; MIT for Soredemo and the remaining browser, cursor, validation, and CLI dependencies; and Python-2.0 for `js-yaml`'s transitive `argparse` dependency.
- No CDP capture, cursor dispatch, frame resampling, canvas composition, or FFmpeg encoding was added on Day 1.
- `Page.startScreencast` initially returned 1440×900 JPEGs despite a 2× device scale factor and 2880×1800 maximum dimensions. Explicitly setting the CDP visible size to 2880×1800 while retaining 1440×900 CSS metrics produced native 2× frames; runtime gates now verify both sides of that contract.
- Day 3 replaced pnpm 11.15.1 with exact pnpm 10.34.0 so contributors can run the complete toolchain under the documented Node 20 minimum.
- The final Node 20 trials observed a largest inter-frame gap of 51.46 ms and a largest receive-delay spike of 75.29 ms. Neither crossed the 100 ms diagnostic threshold; no correction was applied.
- No cursor movement, click dispatch, action timeline, frame resampling, compositor, camera, or encoding code was added on Day 2.
- The first target-level hover probe used a window capture listener for `pointerenter`; Chromium did not deliver that non-bubbling event to the window. Direct capture-phase listeners are now attached to test-ID targets from the pre-application init script and maintained with a mutation observer.
- The successful Day-3 bundle contains 5,428 lossless 2880×1800 frames and 30 click timeline events over 58.337 seconds. It is ignored under `.tmp/` and was not committed.
- No generic action executor, selector resolver, frame resampler, compositor, camera, encoder, or public render integration was added on Day 3.
- The Day-4 real trial selected 1,751 of 5,428 source frames, skipped 3,677 high-cadence frames, and produced a 428,518-byte metadata plan in 248.818 ms.
- No Day-3 click exceeded the 20 ms source-to-mouse-down diagnostic threshold; the maximum was 19.337 ms.
- No JPEG was opened, decoded, copied, resized, blended, or modified on Day 4. No compositor, visible cursor, camera, canvas, or encoder code was added.
- The initial Day-5 `getImageData()` extraction path failed twice above 3 GiB RSS despite single-frame JavaScript ownership. `canvas.data()` preserved the same RGBA hashes and completed at 167,690,240 bytes peak RSS without forced garbage collection.
- The successful Day-5 run processed 14,523,494,400 logical RGBA bytes across 1,751 frames at 24.005 frames/s. Its diagnostic output contains hashes and six PNG snapshots, but no raw RGBA files or copied JPEGs.
- No visible cursor, cursor landing measurement, camera, chrome, background styling, encoder, FFmpeg, or public render integration was added on Day 5.
- The Day-6 track directly consumed 5,910 measured points from 30 Day-3 paths. All adjacent movements joined with zero CSS-pixel discontinuity.
- All 30 mouse-down output mappings evaluated held cursor state and landed at exactly zero output-pixel error. No timing or coordinate offset was added.
- The cursor-enabled full run processed 1,751 frames at 23.590 frames/s with 186,662,912 bytes peak RSS and a negative fitted RSS slope.
- Provisional click feedback was deferred. No camera, chrome, gradient, encoder, FFmpeg, or public render integration was added on Day 6.
- The Day-7 camera generated 30 transitions and 31 establish/hold segments with no overlap or timing compression. All 30 commit bboxes remained fully visible at mouse down.
- Camera-aware cursor landing remained exactly zero output pixels for all 30 clicks because browser-space click points and cursor hotspots share one projection.
- The camera-enabled full run processed 1,751 frames at 24.013 frames/s with 179,879,936 bytes peak RSS, zero crop corrections, and zero camera-generated black-edge frames.
- Day 7 intentionally frames click targets only. Resolved `focusAfter` result framing awaits full Demo Plan execution.
- No browser chrome, rounded mask, shadow, gradient, encoder, FFmpeg, or public render integration was added on Day 7.
- The Day-8 studio run rendered all 1,751 frames with 30 ripples across 233 output frames, zero landing error, full target visibility, zero mask leaks, and zero black output corners.
- Pre-rendering the invariant shadow improved studio throughput from 9.18 to 11.81 frames/s. This remains below the 15 frames/s diagnostic warning and must be considered before encoder integration.
- Peak Day-8 RSS was 221,478,912 bytes with a 4,512.607 bytes/frame fitted slope; memory remained bounded far below 1 GiB.
- The alternating fixture pans remain visually noticeable. Camera timing was not changed on Day 8 because the accepted Day-7 track is authoritative.
- No dependency, FFmpeg, encoder, MP4, YAML executor, `focusAfter`, or public render integration was added on Day 8.
