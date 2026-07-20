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

## Session notes

- The managed development sandbox rejects loopback `listen()` with `EPERM`. The fixture server helper remains typechecked; the automated Day-1 fixture test validates static controls and behavior hooks without opening a socket. Exercise the real server on macOS before the Day-3 gate.
- The first temporary tarball installation used pnpm offline mode, but the local store lacked registry tarball metadata for `citty`. Retrying the isolated install with registry access succeeded; the packed `soredemo` binary then passed all exit-code checks.
- Production runtime licenses currently report MIT for `soredemo`, `citty`, `js-yaml`, and `zod`, plus Python-2.0 for `js-yaml`'s transitive `argparse` dependency.
- No CDP capture, cursor dispatch, frame resampling, canvas composition, or FFmpeg encoding was added on Day 1.
