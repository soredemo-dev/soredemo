# ADR 0002: CDP screencast is the timing source

- Status: Accepted
- Date: 2026-07-21

## Context

Playwright `recordVideo` produces variable-frame-rate output with timestamp drift and cannot be the timing authority for cursor landing or composition.

## Decision

Capture with CDP `Page.startScreencast` and its frame metadata at `deviceScaleFactor: 2`. Launch the pinned Chromium with `--force-device-scale-factor=2`, retain a 1440×900 CDP visible surface, and require 2880×1800 JPEG output. Do not set the CDP visible size to 2880×1800: Chromium 149 paints a 1440×900 page into that surface's upper-left quadrant, producing the requested file dimensions without genuine 2× browser pixels. Verify browser metrics, JPEG dimensions, and cursor-target pixel alignment at runtime. Acknowledge every frame only after copying its bytes into the capture queue. Pin Playwright and Chromium versions and record both in the manifest.

## Consequences

The Experimental CDP API and forced device-scale launch flag are compatibility risks managed by version pinning and runtime pixel gates. Higher-resolution source frames provide zoom headroom. Dimensions alone are insufficient evidence of that headroom. `recordVideo` is banned.
