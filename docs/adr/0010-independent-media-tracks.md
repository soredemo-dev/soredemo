# ADR 0010: Independent media tracks

- Status: Accepted
- Date: 2026-07-21

## Context

Future presenter video, narration, captions, and music need independent retakes and replacements without rerunning browser actions.

## Decision

Preserve an architecture of independent timestamped browser, cursor/camera, presenter video, narration audio, caption, and optional music tracks feeding final composition. Browser capture never owns webcam or microphone recording.

## Consequences

Presenter and narration takes can be replaced independently and layouts or localization can evolve later. This ADR adds no webcam, audio, caption, music, or presenter dependency to v0.1.
