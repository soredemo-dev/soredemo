# ADR 0009: Capture artifact format

- Status: Accepted
- Date: 2026-07-21

## Context

One intermediate video would hide timing and coordinate evidence and require reopening the browser for every compositor change.

## Decision

Phase 1 emits `.capture/manifest.json`, numbered JPEG files under `frames/`, `frames.jsonl`, and `timeline.json`.

The version-1 manifest records script hash, Playwright and Chromium versions, CSS viewport, device scale factor, ISO capture start, and frame count. Each frame record contains index, filename, calibrated timestamp, pixel dimensions, page scale factor, scroll offsets, offset top, and optional diagnostic receive time.

## Consequences

The bundle supports compositor reruns, timestamp resampler debugging, coordinate inspection, and future `soredemo compose <capture-dir>` and visual inspection tools.
