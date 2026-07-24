# Changelog

## Unreleased (studio UI rebuild)

- Rebuild the Studio UI in React + Vite + TypeScript with full functional parity to the
  alpha.1 vanilla UI: agent proposal, manual plan paste/edit, exact plan-hash approval with
  edit-invalidation, run start/stop, ordered SSE rendering, live preview, MP4, and proof.
  New componentized design (three-zone layout, the plan-rail verified checklist, evidence
  badges) codified in [docs/design-system.md](docs/design-system.md); see
  [ADR 0012](docs/adr/0012-react-studio-ui.md). Both the browser `soredemo studio` command
  and the Electron shell serve the same built assets, unchanged; the server, session auth,
  CSP, and event protocol are untouched. React/Vite are devDependencies bundled into static
  assets — the published package surface is unchanged.

## Unreleased (desktop foundation)

- Add a development-grade Electron macOS shell in `desktop/` that embeds the existing
  Studio vertical slice: thin main process, sandboxed renderer, narrow typed preload,
  native menu/dialog/lifecycle. The shell is one client of the shared engine, is never
  published in the `soredemo` npm package, and is not signed or distributed. See
  [ADR 0011](docs/adr/0011-electron-desktop-shell.md) and [docs/desktop.md](docs/desktop.md).
- Guard the production engine against any Electron import.
- Note: alpha.1 npm publication remains deliberately deferred; the alpha.1 source is
  complete and verified but intentionally unpublished.

## 0.1.0-alpha.1 (development)

- Add the local `soredemo studio` vertical slice: plan discovery, optional AI proposal,
  exact-hash approval, production-run observation, evidence, MP4 playback, and proof access.
- Add safe `soredemo init` bootstrap and one canonical agent-neutral authoring skill.
- Add a read-only optional Claude Code provider using documented non-interactive JSON,
  plan permission mode, bounded turns, and no Agent tools.
- Add a shared run coordinator, bounded versioned event journal, sampled production-capture
  preview, and safe stop behavior.
- Add opt-in CLI proof bundles and default Studio proof output.
- Add a loopback npm publication-request gate and document alpha.0 release deviations.

## 0.1.0-alpha.0

First public-alpha release candidate.

- Declarative YAML Demo Plans with `goto`, `wait`, `moveTo`, `click`, `type`, and `scrollTo`.
- Deterministic semantic target resolution with real Chromium mouse and keyboard input.
- Genuine 2× CDP browser capture, fixed 30fps resampling, studio composition, camera framing, visible cursor, and click feedback.
- Bounded RGBA streaming to external system FFmpeg/libx264 with validated H.264 MP4 output.
- `doctor`, structured diagnostics, failure workspaces, and signal-safe cleanup.
- Split visual authority: exact canonical compositor goldens and structural live-render pixel gates.

Known limitations: macOS arm64 is the only verified platform; Node 20.19.4 is authoritative; the application must already be running; Chromium and FFmpeg are installed separately; app startup, authentication profiles, saved sessions, audio, narration, webcam, captions, and cloud rendering are not implemented.

Release status: **RELEASED WITH DOCUMENTED DEVIATIONS**. As npm's first publication,
`latest` and `alpha` both pointed to alpha.0 and npm rejected removing the only `latest`.
Registry packument source fields also reflected the local publication source, although the
downloadable tarball contained no private path or data. See
[publication hygiene](docs/publication-hygiene.md).
