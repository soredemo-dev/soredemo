# Soredemo v0.1.0-alpha.0

Soredemo turns declarative YAML into polished product demos of real, already-running web applications. This first public alpha executes semantic browser actions with Playwright, captures genuine Chromium pixels, adds post-production camera movement and a visible cursor, and produces a validated H.264 MP4 through an external FFmpeg installation.

> This is an early public alpha, not a production-ready or API-stable release. The verified environment is macOS arm64 with Node.js 20.19.4, Playwright 1.61.1/Chromium 149 revision 1228, Canvas 1.0.2, and system FFmpeg/FFprobe 8.0.

## Install

```bash
npm install --save-dev soredemo@alpha
npx playwright install chromium
npx soredemo doctor
```

FFmpeg and FFprobe must be installed separately and expose the `libx264` encoder. Soredemo does not bundle or download Chromium during package installation and never bundles or downloads FFmpeg.

## Five-minute workflow

With your application already running over HTTP or HTTPS:

```bash
npx soredemo validate demos/create-project.yaml
npx soredemo render demos/create-project.yaml --out output/create-project.mp4
```

See the [README](https://github.com/soredemo-dev/soredemo#readme) and [getting-started guide](https://github.com/soredemo-dev/soredemo/blob/v0.1.0-alpha.0/docs/getting-started.md) for a complete configuration and Demo Plan.

## Included in this alpha

- Six actions: `goto`, `wait`, `moveTo`, `click`, `type`, and `scrollTo`.
- Semantic targets by role and accessible name, label, test ID, or text, plus an explicit CSS escape hatch.
- Real Playwright mouse, keyboard, navigation, and browser scrolling.
- Genuine 2× Chromium capture, fixed 30fps resampling, camera framing, studio chrome, visible cursor, and click feedback.
- Bounded one-frame RGBA streaming into external FFmpeg/libx264.
- H.264/yuv420p MP4 validation, fast-start ordering, diagnostics, failure workspaces, and `soredemo doctor`.
- Exact synthetic compositor goldens and structural live-render visual gates that inspect actual pixels.

## Known limitations

- macOS arm64 is the only verified platform; Windows and Linux remain unverified.
- Node.js support is intentionally limited to `>=20.19.4 <21` for this alpha.
- The target application must already be running. Application startup and authentication profiles are not implemented.
- Chromium and FFmpeg installation are explicit external prerequisites.
- Audio, narration, webcam, captions, cloud rendering, and stable API compatibility are not included.
- Live renders are structurally reproducible, not byte-identical. Browser-frame timing, measured input timing, generated cursor paths, source selection, and application animation remain part of production execution.

## Privacy and codec boundary

Preserved captures, failure screenshots, rendered videos, and diagnostic workspaces can contain private application pixels. They remain local and are never uploaded automatically; inspect them before sharing.

Soredemo is MIT licensed. FFmpeg remains external, and the tested libx264-enabled build is GPL-conditioned. H.264 may carry jurisdiction-specific patent considerations. This is technical documentation, not legal advice.

## Documentation and feedback

- [CLI reference](https://github.com/soredemo-dev/soredemo/blob/v0.1.0-alpha.0/docs/cli-reference.md)
- [Troubleshooting](https://github.com/soredemo-dev/soredemo/blob/v0.1.0-alpha.0/docs/private-alpha-troubleshooting.md)
- [Changelog](https://github.com/soredemo-dev/soredemo/blob/v0.1.0-alpha.0/CHANGELOG.md)
- [Report an issue](https://github.com/soredemo-dev/soredemo/issues)
