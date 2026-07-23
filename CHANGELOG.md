# Changelog

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
