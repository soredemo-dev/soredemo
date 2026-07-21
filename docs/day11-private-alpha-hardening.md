# Day 11: private-alpha CLI hardening

Day 11 added stable errors, stage accounting, reporter modes, local failure evidence, capability diagnostics, and signal recovery without changing the accepted video architecture.

## Capture proof

Before real capture begins, Soredemo temporarily paints four 8-CSS-pixel color bands, obtains a CDP screencast frame, and decodes physical samples at the expected 2× centers. The probe is then removed. The accepted public run reported JPEG 2880×1800, CSS viewport 1440×900, DPR 2, CSS CDP viewport 1440×900, physical CDP layout viewport 2880×1800, and color distances `1, 1, 1, 0`. A dimension-correct quadrant-painted frame fails as `CAPTURE_PIXEL_SCALE_INVALID` before user actions.

## CLI and recovery

The public CLI supports human, quiet, verbose, and single-value JSON reporting. Stable failures contain code, stage, bounded action and target metadata, an optional preserved artifact path, and safe details without stacks or typed values. `soredemo doctor` passed every required capability on Node 20.19.4, macOS arm64, FFmpeg/FFprobe 8.0, Playwright 1.61.1, Chromium revision 1228, and Canvas 1.0.2.

The controlled missing-target render returned `TARGET_NOT_FOUND` at action index 1, preserved one viewport screenshot plus `error.json`, and produced no final or partial MP4. Candidate output was capped at ten safe summaries. SIGINT and SIGTERM gates both reached terminal `aborted` manifests, closed their child render process, left no output or partial file, and did not leave running stage records.

## Successful renders

The authoritative current-source render captured 688 genuine 2880×1800 frames, resampled to 334 frames at 30 fps, and produced an 11.133333-second H.264/yuv420p MP4. The 741,380-byte file has SHA-256 `c07ec8d208f6d9be176b38ea45555bfffefaa54a0459e5b9a10adfc2818acbd9`. It retained one move, two click, and one type-focus measurement; every landing error was zero, every target was fully visible, all 16 decoded MP4 proofs matched output indexes, and encoder pending state remained one 8,294,400-byte RGBA frame.

The final fresh packed-package render captured 716 source frames and produced 345 output frames over 11.5 seconds. Its 751,527-byte MP4 has SHA-256 `a1b92ca6219b03c80f37fa82d2c81a875b6ab8423b55e71952dfd200e875adec`. All 345 encoder writes observed and awaited backpressure, with one pending 8,294,400-byte RGBA frame at most. The packed doctor, validation, four-action cursor gate, complete decode, and missing-target failure all passed.

A short successful render without `--keep-artifacts` published its MP4 and removed its completed run workspace. Successful full runs with `--keep-artifacts` retained completed manifests in which every administrative stage was terminal.

## Findings and Day 12 risks

- CDP timestamps remain a hard failure. The deterministic seam records frame indexes, epoch timestamps, signed delta, receive times, startup calibration, queue state, versions, and launch arguments without correction.
- The forced-device-scale route remains Chromium-version-sensitive. Doctor reports the pinned revision, and every render performs the painted-scale proof.
- Failure screenshots can contain private product data and require deliberate handling by alpha users.
- Encoded proof decoding is bounded to cursor-action frames rather than every output frame; Day 12 visual regression should add independent synthetic golden authority without weakening these action proofs.
- Same-machine composition and encoding results remain the supported determinism claim.
