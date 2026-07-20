# ADR 0004: Canvas compositor with @napi-rs/canvas

- Status: Accepted
- Date: 2026-07-21

## Context

The compositor needs deterministic output-frame evaluation without a browser UI framework or a non-permissive renderer.

## Decision

Use `@napi-rs/canvas`. For each output timestamp, select the nearest valid captured frame, apply the camera transform, draw the visible cursor and click feedback, apply the browser mask and chrome, draw shadow and background, then write raw RGBA to the encoder. Use `bezier-easing` for interpolation.

## Consequences

The SVG cursor remains crisp and constant in output-screen size while application pixels zoom. Composition is frame-based and isolated from browser execution.
