# Private-alpha troubleshooting

Run `soredemo doctor` before rendering. It checks the Node runtime, system FFmpeg and FFprobe, required libx264 and rawvideo capabilities, pinned Playwright Chromium, Canvas native binding, cursor asset, and local workspace permissions. `soredemo doctor --json` emits one machine-readable result.

Use `--verbose` for resolved paths, versions, capture-scale proof observations, stage durations, cursor-audit counts, and encoder backpressure. Use `--quiet` for only the final result, material warnings, and failures. `--json` emits exactly one stdout value; operational diagnostics remain on stderr.

Failed and interrupted renders preserve their Soredemo-owned run workspace. Inspect:

- `run-manifest.json` for the terminal status and per-stage timing;
- `diagnostics/error.json` for the stable code, action context, environment, capture proof, and bounded filenames;
- `diagnostics/action-NNN-kind-failure.png` for the first failed action, when Chromium remained available;
- `capture/frames.jsonl` and `capture/pixel-scale-proof.json` for accepted capture data;
- `encode/ffmpeg.log` for the local incremental encoder log.

Failure screenshots and captured frames may contain private application data. They stay local, are never uploaded, and are excluded from the npm package. Review them before sharing.

Common codes:

- `TARGET_NOT_FOUND`, `TARGET_AMBIGUOUS`, `TARGET_NOT_VISIBLE`, and `TARGET_NOT_ENABLED` identify semantic-target failures. Candidate summaries contain only tag, role, accessible name, test ID, visibility, enabled state, and bbox.
- `CAPTURE_PIXEL_SCALE_INVALID` means the CDP proof did not observe genuine 2× painting. Do not add an offset or restore `Emulation.setVisibleSize`; verify the pinned Playwright/Chromium pair and launch arguments.
- `CAPTURE_TIMESTAMP_INVALID` means a CDP frame timestamp was non-finite or moved backward. Soredemo does not clamp, sort, drop, or replace it with receive time.
- `CURSOR_SYNCHRONIZATION_FAILED` means a move, click, or type-focus hotspot failed its compositor landing contract.
- `FFMPEG_NOT_FOUND`, `FFPROBE_NOT_FOUND`, and `ENCODER_CAPABILITY_MISSING` identify system-encoder preflight failures. Soredemo does not bundle or silently substitute an encoder.

On SIGINT or SIGTERM, allow cleanup to finish. The run ends as `aborted`, invalid partial MP4 files are removed, and the workspace is preserved.
