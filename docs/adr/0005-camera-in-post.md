# ADR 0005: Camera movement exists only in post-production

- Status: Accepted
- Date: 2026-07-21

## Context

Live CSS transforms can change layout, hit testing, sticky positioning, animation, rendering, and event coordinates.

## Decision

Camera zoom and pan operate only on captured pixels inside the compositor. Browser capture never applies a live demo-camera transform.

## Consequences

Browser behavior stays genuine and coordinate metadata remains meaningful. The compositor cannot invent content outside the captured viewport, so viewport and real scrolling decisions remain important.
