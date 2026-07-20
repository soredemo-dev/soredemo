# ADR 0006: One coordinate system and one clock

- Status: Accepted
- Date: 2026-07-21

## Context

Cursor landing and frame resampling fail when browser events, capture metadata, and composition use ambiguous coordinates or independent clocks.

## Decision

Script targets, bounding boxes, click points, and cursor paths use CSS pixels. Bounding boxes are viewport-relative unless documented otherwise. Captured pixel dimensions remain separate from CSS viewport dimensions.

All timeline milliseconds are relative to one capture origin. Calibrate CDP and driver timestamps once at startup. CDP timestamps are authoritative; Node receive time is diagnostic only. Never align streams by receive time. Acknowledge every screencast frame only after copying its bytes into the capture queue.

## Consequences

The driver and compositor can use the same cursor path without manual action offsets. Acceptance compares the composited cursor hotspot with the actual dispatched mouse-down point, not the original target center.
