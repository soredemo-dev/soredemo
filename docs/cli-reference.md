# CLI reference

## `soredemo doctor`

Checks Node, FFmpeg, FFprobe, libx264, the pinned Playwright Chromium revision, Canvas, the cursor asset, and workspace writability. `--json` emits one machine-readable value. `--quiet` shows only failures and final status; `--verbose` adds resolved paths and versions.

## `soredemo validate <plan>`

Parses and validates a Demo Plan without loading Playwright, Chromium, Canvas, capture, composition, or encoder modules. Use `--json`, `--quiet`, or `--verbose`; these modes are mutually exclusive.

## `soredemo render <plan>`

Validates, captures, resamples, composes, encodes, validates, and atomically publishes an MP4. `--out <path>` selects the output; otherwise the plan basename is used beside the plan. Existing output files are refused. `--keep-artifacts` preserves the local run workspace. `--json`, `--quiet`, and `--verbose` are mutually exclusive.

Exit codes are `0` for success, `1` for validation/render/prerequisite failure, and `2` for command misuse. `SIGINT` and `SIGTERM` preserve diagnostics, remove partial MP4s, and terminate Chromium and FFmpeg before exit.
