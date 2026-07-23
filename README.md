# Soredemo

Soredemo is the open-source, agent-native studio for verified product demos.

> **Public alpha.** Soredemo is verified on macOS arm64 with Node.js 20.19.4. It is not production-ready, and Windows and Linux are not yet verified.

Describe what you want to demonstrate, review the proposed flow, watch the runner operate
your application, and receive a polished video with verifiable execution evidence. The
existing CLI remains the automation interface; Studio is the local human interface.

## Requirements

- macOS on Apple silicon (the verified alpha environment)
- Node.js `>=20.19.4 <21`
- an HTTP or HTTPS web application that is already running
- the Playwright Chromium revision installed with the local package
- system FFmpeg and FFprobe with the `libx264` encoder

Audio, webcam, authentication profiles, automatic application startup, and automatic browser or FFmpeg installation are not implemented.

## Install

```bash
npm install --save-dev soredemo@alpha
npx playwright install chromium
npx soredemo doctor
```

Release-candidate reviewers can install the generated tarball in place of `soredemo@alpha` without contacting the registry.

Soredemo never downloads Chromium or FFmpeg during `npm install`. `npx playwright install chromium` resolves the Playwright version installed alongside Soredemo. FFmpeg remains a separately installed system executable; set `SOREDEMO_FFMPEG_PATH` to choose one explicitly.

## Five-minute quickstart

Start your application at `http://127.0.0.1:3000`, then add this configuration:

<!-- quickstart-config:start -->
```yaml
version: 1

browser:
  viewport:
    width: 1440
    height: 900
  deviceScaleFactor: 2

output:
  width: 1920
  height: 1080
  fps: 30

defaults:
  style: studio
  pace: balanced
```
<!-- quickstart-config:end -->

Create `demos/create-project.yaml`:

<!-- quickstart-plan:start -->
```yaml
version: 1
name: create-project
url: http://127.0.0.1:3000

intent:
  goal: Show how quickly a user can create a project

style:
  preset: studio
  pace: balanced

actions:
  - action: wait
    until:
      visible:
        testId: demo-ready

  - action: moveTo
    target:
      testId: new-project

  - action: click
    target:
      testId: new-project

  - action: type
    target:
      label: Project name
    text: Soredemo

  - action: scrollTo
    target:
      testId: create-project
    durationMs: 700

  - action: click
    target:
      testId: create-project

  - action: wait
    until:
      visible:
        testId: project-created
    timeoutMs: 10000
    settleMs: 200
```
<!-- quickstart-plan:end -->

Replace the URL and semantic targets with values from your application, then run:

```bash
npx soredemo validate demos/create-project.yaml
npx soredemo render demos/create-project.yaml --out output/create-project.mp4
```

Or open the local application:

```bash
npx soredemo studio
```

Studio can inspect a bounded semantic view of your already-running app, ask an optional
external Claude Code provider for a six-action proposal, require approval of the exact plan
hash, execute the same production runner, and present the MP4 and proof summary. Agent source
and snapshot access require separate consent. With no Agent installed, existing Demo Plans
can still be reviewed, approved, and rendered.

Canonical copies of these snippets live in [`examples/quickstart`](examples/quickstart), and the repository verifies that the README and files remain schema-valid and synchronized.

## Demo Plans

The alpha supports exactly six actions: `goto`, `wait`, `moveTo`, `click`, `type`, and `scrollTo`. Targets may use role and accessible name, label, test ID, exact or inexact text, or an explicit CSS escape hatch. Semantic targets are preferred; Soredemo never silently chooses the first ambiguous match.

See [Getting started](docs/getting-started.md), [CLI reference](docs/cli-reference.md), and the generated [JSON Schema](schema/soredemo.schema.json).

## CLI

```text
soredemo doctor [--json]
soredemo validate <demo-plan> [--json|--quiet|--verbose]
soredemo render <demo-plan> [--out <file>] [--keep-artifacts] [--json|--quiet|--verbose]
soredemo render <demo-plan> --out <file> [--proof <directory>]
soredemo init [directory] [--dry-run|--yes] [--json]
soredemo studio [--project <directory>] [--no-open] [--agent <auto|claude-code|none>]
soredemo proof verify <proof-directory>
```

Use `soredemo <command> --help` for current options.

## Reproducibility and privacy

Live renders are structurally reproducible, not byte-identical. Real CDP frame timing, measured browser input timing, cursor paths, source-frame selection, and application animation remain part of production execution. Exact visual regression uses fixed compositor inputs separately from live capture.

Studio binds to loopback by default, uses an ephemeral HttpOnly session, ships no analytics,
and uploads nothing automatically. Agent requests never include screenshots, cookies, storage,
environment variables, or secrets; source and bounded semantic snapshots are opt-in.

Failed renders and `--keep-artifacts` workspaces can contain captured JPEGs, browser screenshots, timeline metadata, typed-text lengths, FFmpeg logs, and private application pixels. Diagnostics are local and never uploaded automatically. Password values are redacted from structured diagnostics, but Soredemo cannot detect every sensitive visual or value. Inspect artifacts, proofs, and final videos before sharing.

## Known alpha limits

- macOS arm64 is the only verified platform.
- Node 20.19.4 is the authoritative runtime; later Node 20 patch versions are accepted.
- Your application must already be running and reachable by HTTP or HTTPS.
- Chromium and FFmpeg are external prerequisites.
- There is no app startup, saved session, audio, narration, webcam, captions, cloud rendering, or stable-release guarantee yet.
- Studio does not provide autonomous exploration, manual recording, human takeover, mobile
  recording, narration, or timeline editing.

See [Public-alpha release notes](docs/public-alpha-release.md) and [Troubleshooting](docs/private-alpha-troubleshooting.md).

## License and codec boundary

Soredemo is MIT licensed. FFmpeg is external and its exact license depends on its build. The tested `libx264` configuration is GPL-conditioned, and H.264 may have jurisdiction-specific patent considerations. This is technical documentation, not legal advice. See [Encoder and codec notes](docs/encoder-and-codec-notes.md).

Development and visual-authority workflows are documented in [CLAUDE.md](CLAUDE.md) and [Visual regression](docs/visual-regression.md).
Studio details are in [Studio](docs/studio.md), [Studio security](docs/studio-security.md),
[Agent providers](docs/agent-providers.md), and [Proof bundles](docs/proof-bundles.md).
An experimental Electron desktop shell (development foundation, not distributed) is described in
[Desktop shell](docs/desktop.md) and [ADR 0011](docs/adr/0011-electron-desktop-shell.md).
