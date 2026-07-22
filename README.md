# Soredemo

Soredemo is a version-controlled demo compiler for web products. It executes a declarative YAML Demo Plan against an already-running application, captures real Chromium pixels and input, then produces a polished 1920×1080 H.264 MP4.

Development requires Node.js 20 or later and the exact `pnpm@10.34.0` version declared in `package.json`. Rendering also requires the pinned Playwright Chromium and a system FFmpeg/FFprobe build with `libx264`.

```bash
corepack pnpm install --frozen-lockfile
corepack pnpm build
corepack pnpm soredemo doctor
corepack pnpm soredemo validate examples/demo.yaml
corepack pnpm soredemo render demo.yaml --out demo.mp4
```

## Visual regression authorities

Soredemo deliberately separates two kinds of visual evidence:

- `pnpm golden:verify` feeds fixed, checked-in inputs through the production compositor and requires byte-identical RGBA and PNG output on the official macOS arm64 Canvas profile.
- `pnpm live-visual:verify` runs the normal public Playwright/CDP render path and verifies capture scale, action timing, cursor/target pixels, studio layers, encoded frame indexes, and decoded MP4 fidelity.

Live captures are structurally reproducible, not byte-identical. Real CDP frame timing, measured mouse timing, generated cursor geometry, frame selection, and animated application pixels are intentionally part of production execution.

See [Visual regression](docs/visual-regression.md) and the [specification](docs/SPEC.md).
