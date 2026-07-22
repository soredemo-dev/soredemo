# Changelog

## 0.1.0-alpha.0

First public-alpha release candidate.

- Declarative YAML Demo Plans with `goto`, `wait`, `moveTo`, `click`, `type`, and `scrollTo`.
- Deterministic semantic target resolution with real Chromium mouse and keyboard input.
- Genuine 2× CDP browser capture, fixed 30fps resampling, studio composition, camera framing, visible cursor, and click feedback.
- Bounded RGBA streaming to external system FFmpeg/libx264 with validated H.264 MP4 output.
- `doctor`, structured diagnostics, failure workspaces, and signal-safe cleanup.
- Split visual authority: exact canonical compositor goldens and structural live-render pixel gates.

Known limitations: macOS arm64 is the only verified platform; Node 20.19.4 is authoritative; the application must already be running; Chromium and FFmpeg are installed separately; app startup, authentication profiles, saved sessions, audio, narration, webcam, captions, and cloud rendering are not implemented.
