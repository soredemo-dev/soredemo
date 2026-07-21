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
