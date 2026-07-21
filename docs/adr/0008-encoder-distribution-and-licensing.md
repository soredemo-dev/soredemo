# ADR 0008: Encoder distribution and licensing boundary

- Status: Accepted
- Date: 2026-07-21

## Context

Soredemo needs broadly usable MP4 output without hiding executable distribution or codec licensing obligations inside the npm package.

## Decision

Isolate encoding behind an `Encoder` interface. Send raw RGBA frames to an FFmpeg child process that produces yuv420p H.264 at 1920×1080 and 30 fps.

Do not bundle FFmpeg. Prefer a compatible system binary; otherwise download a documented build on demand into a cache. Before release, record `ffmpeg -version` and `ffmpeg -buildconf`, add third-party notices, document the FFmpeg/x264 license boundary, and separately document the H.264 patent caveat.

The Day-9 implementation resolves a literal `SOREDEMO_FFMPEG_PATH` first and then inspects `PATH` directly. It does not implement the future managed download. Every encode preflights `libx264` and rawvideo capabilities and records the executable real path, SHA-256, version, compiler, and complete configure arguments. FFprobe is required beside FFmpeg or on `PATH` for output validation.

Successful output is written to a unique sibling partial file, validated, fsynced, and atomically renamed. RGBA delivery is sequential and waits for both Node stream backpressure and write-buffer ownership before the compositor advances.

## Consequences

Soredemo does not claim an arbitrary FFmpeg binary is LGPL. Builds containing `libx264` are GPL-conditioned and the exact license depends on build configuration. Software `libx264` remains the portable baseline.

H.264 may carry separate patent licensing considerations depending on jurisdiction and use. The repository records this technical boundary without giving legal advice. No FFmpeg or FFprobe executable, archive, source tree, codec library, or system-specific path enters the npm package.
