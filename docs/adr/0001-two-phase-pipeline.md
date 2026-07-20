# ADR 0001: Two-phase pipeline

- Status: Accepted
- Date: 2026-07-21

## Context

Browser interaction and cinematic presentation have different correctness requirements. Baking presentation effects into live page pixels would couple visual direction to browser behavior and prevent independent recomposition.

## Decision

Use two phases. The Playwright driver controls a real Chromium page and captures raw frames plus interaction metadata. A separate compositor adds cursor, camera, zoom, pan, click feedback, browser chrome, mask, shadow, and background.

## Consequences

The visible cursor and camera are never baked into browser capture. Capture bundles can be recomposed without reopening the browser, and later media tracks remain independent.
