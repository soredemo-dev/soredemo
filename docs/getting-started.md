# Getting started

The public alpha is verified on macOS arm64 with Node.js 20.19.4. Install Soredemo into a clean project, install its matching Chromium revision explicitly, and check external prerequisites:

```bash
npm install --save-dev soredemo@alpha
npx playwright install chromium
npx soredemo doctor
```

Your target application must already be running over HTTP or HTTPS. Copy [`examples/quickstart`](../examples/quickstart), replace its URL and semantic targets, then validate and render:

```bash
npx soredemo validate demos/create-project.yaml
npx soredemo render demos/create-project.yaml --out output/create-project.mp4
```

Soredemo searches from the plan directory toward the filesystem root for the first `soredemo.config.yaml`. The plan owns the narrative and initial URL; configuration owns viewport and output mechanics. The alpha capture contract is a 1440×900 CSS viewport, genuine 2× browser painting, and 1920×1080 output at 30fps.

The package does not download a browser or encoder during installation. If Chromium is absent, rerun `npx playwright install chromium` from the project containing Soredemo. If FFmpeg is absent or lacks `libx264`, install a suitable system build or set `SOREDEMO_FFMPEG_PATH`.

Use `--keep-artifacts` only when you need diagnostics. Preserved workspaces may contain sensitive application pixels.
