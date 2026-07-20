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

## Session notes

- The Day-1 managed-sandbox `EPERM` was environmental: the fixture server served all local assets successfully over loopback on normal macOS, and Chromium rendered it with non-loopback requests blocked.
- The first temporary tarball installation used pnpm offline mode, but the local store lacked registry tarball metadata for `citty`. Retrying the isolated install with registry access succeeded; the packed `soredemo` binary then passed all exit-code checks.
- Production runtime licenses currently report MIT for `soredemo`, `citty`, `js-yaml`, and `zod`, plus Python-2.0 for `js-yaml`'s transitive `argparse` dependency.
- No CDP capture, cursor dispatch, frame resampling, canvas composition, or FFmpeg encoding was added on Day 1.
- `Page.startScreencast` initially returned 1440×900 JPEGs despite a 2× device scale factor and 2880×1800 maximum dimensions. Explicitly setting the CDP visible size to 2880×1800 while retaining 1440×900 CSS metrics produced native 2× frames; runtime gates now verify both sides of that contract.
- pnpm 11.15.1 itself requires Node 22 because it imports `node:sqlite`. Project binaries, tests, CLI, and the final capture trials pass under Node 20.19.4, but the declared package-manager version cannot be launched by Node 20. Address this toolchain-floor mismatch before release.
- The final Node 20 trials observed a largest inter-frame gap of 51.46 ms and a largest receive-delay spike of 75.29 ms. Neither crossed the 100 ms diagnostic threshold; no correction was applied.
- No cursor movement, click dispatch, action timeline, frame resampling, compositor, camera, or encoding code was added on Day 2.
