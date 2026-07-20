# ADR 0002: CDP screencast is the timing source

- Status: Accepted
- Date: 2026-07-21

## Context

Playwright `recordVideo` produces variable-frame-rate output with timestamp drift and cannot be the timing authority for cursor landing or composition.

## Decision

Capture with CDP `Page.startScreencast` and its frame metadata at `deviceScaleFactor: 2`. Configure an explicit 2880×1800 CDP visible surface while preserving a 1440×900 CSS viewport, and verify both browser metrics and every JPEG's actual dimensions at runtime. Acknowledge every frame only after copying its bytes into the capture queue. Pin Playwright and Chromium versions and record both in the manifest.

## Consequences

The Experimental CDP API and explicit surface sizing are compatibility risks managed by version pinning and runtime gates. Higher-resolution source frames provide zoom headroom. `recordVideo` is banned.
