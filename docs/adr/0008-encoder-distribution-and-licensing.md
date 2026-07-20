# ADR 0008: Encoder distribution and licensing boundary

- Status: Accepted
- Date: 2026-07-21

## Context

Soredemo needs broadly usable MP4 output without hiding executable distribution or codec licensing obligations inside the npm package.

## Decision

Isolate encoding behind an `Encoder` interface. Send raw RGBA frames to an FFmpeg child process that produces yuv420p H.264 at 1920×1080 and 30 fps.

Do not bundle FFmpeg. Prefer a compatible system binary; otherwise download a documented build on demand into a cache. Before release, record `ffmpeg -version` and `ffmpeg -buildconf`, add third-party notices, document the FFmpeg/x264 license boundary, and separately document the H.264 patent caveat.

## Consequences

Soredemo does not claim an arbitrary FFmpeg binary is LGPL. Builds containing `libx264` are GPL-conditioned and the exact license depends on build configuration. Software `libx264` remains the portable baseline.
