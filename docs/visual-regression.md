# Visual regression

Soredemo uses split visual authority. Geometry and metadata agreement is not sufficient; actual pixels must be inspected. Actual live pixels also need not be byte-identical for the render to satisfy the structural contract.

## Exact synthetic compositor authority

The exact authority starts from the canonical files in `test/golden-input/studio-v1/`: five fixed 2880×1800 browser images, a sparse fixed 30 fps resample plan, a fixed all-cursor-action timeline, and one fixed camera track. It calls the production studio compositor. It does not launch Playwright, generate a ghost-cursor path, consult a wall clock, or encode video.

The official profile is `macos-arm64-canvas-1.0.2`: macOS 26.5.2 build 25F84, arm64, Node 20.19.4, `@napi-rs/canvas@1.0.2`, and `@napi-rs/canvas-darwin-arm64@1.0.2`. Playwright, Chromium, and FFmpeg do not generate these authoritative RGBA frames and are therefore excluded from this exact profile. The cursor SVG hash, canonical input hashes, and studio-constant hash are included.

The workflow is explicit:

```bash
pnpm golden:generate
pnpm golden:verify-candidate
pnpm golden:promote -- --confirm
pnpm golden:verify
```

Generation writes only `.tmp/golden-candidate`. It requires the official profile and a clean worktree unless a maintainer supplies `--allow-dirty`. Promotion is the only command that replaces `test/golden/macos-arm64-canvas-1.0.2`, and it requires `--confirm`. Normal tests and verification never rewrite checked-in goldens.

An official-profile mismatch has zero pixel tolerance. It writes expected, actual, absolute-difference, and amplified-heatmap PNGs plus a bounding-box/statistics manifest under `.tmp/golden-diff`. Canonical input changes are reported separately as `GOLDEN_INPUT_CHANGED`.

Outside the official profile, exact hashes are not compared and no exact-pixel pass is claimed. The production compositor and structural assertions may still run, returning a non-authoritative result.

## Real public-render structural authority

`pnpm live-visual:verify` starts the unchanged deterministic fixture and invokes the built public command. It retains real Playwright input, real CDP epoch timestamps, measured mouse dispatch times, normal ghost-cursor geometry, the animated application, normal nearest-timestamp resampling, normal camera planning, bounded Canvas composition, and system FFmpeg encoding.

The live gate inspects actual pre-encoding full-frame and crop pixels. It verifies genuine 2× color-band painting, all six action kinds, the one moveTo/two click/one type-focus cursor contract, target pixels beneath the cursor, rounded-mask corners, shadow, gradient, toolbar, traffic lights, border, ripple, cursor ordering, and full output opacity. Every selected proof records the same compositor output index, encoder write index, and decoded MP4 index. Decoded H.264 frames use fidelity metrics rather than exact hashes.

Live renders are structurally reproducible, not byte-identical. Differences in capture duration, frame count, cursor point count, action timing, chosen CDP source frames, and whole-frame hashes are expected when all structural contracts still pass.

## Why live deterministic capture was rejected

A special deterministic capture mode would create a second execution path, stop testing normal production timing, hide real CDP and action-synchronization failures, and conflict with Soredemo's structural-reproducibility contract. Canonical inputs belong only at the compositor boundary.

Golden and live proof artifacts may contain application pixels. Candidate, diff, capture, workspace, and MP4 artifacts remain local under ignored directories and are excluded from the npm package.
