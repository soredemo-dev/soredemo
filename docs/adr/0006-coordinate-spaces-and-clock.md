# ADR 0006: One coordinate system and one clock

- Status: Accepted
- Date: 2026-07-21

## Context

Cursor landing and frame resampling fail when browser events, capture metadata, and composition use ambiguous coordinates or independent clocks.

## Decision

Script targets, bounding boxes, click points, and cursor paths use CSS pixels. Bounding boxes are viewport-relative unless documented otherwise. Captured pixel dimensions remain separate from CSS viewport dimensions.

All timeline milliseconds are relative to one capture origin. `Page.screencastFrame` metadata timestamps are `Network.TimeSinceEpoch`: epoch-based seconds, not a monotonic clock. The first accepted CDP frame defines the capture origin, and normalized frame time is the frame epoch minus that origin.

Driver events use Node's monotonic `performance.now()` clock. At startup, sample `performance.timeOrigin + performance.now()` in Chromium between Node monotonic measurements, choose the lowest-round-trip sample, and use its midpoint to establish this fixed mapping:

```text
browserEpochMs ≈ driverMonotonicMs + browserEpochAtDriverZeroMs
```

Take a second calibration at capture completion only to diagnose offset drift. Do not adjust the mapping during capture. CDP frame timestamps are authoritative; mapped Node receive time is diagnostic only. Never align streams by receive time. Acknowledge every screencast frame only after copying its bytes and metadata into the bounded capture queue.

For each real cursor movement, measure Node monotonic time immediately before and after `page.mouse.move()` and map the interval midpoint through the fixed startup calibration. Those measured capture-relative times, paired with the exact dispatched coordinates, form the timeline cursor path. Package-generated path timestamps provide relative scheduling only and never enter the artifact. Browser-observed pointer-down and pointer-up epochs are normalized directly against the CDP capture origin.

## Consequences

The driver and compositor can place future action timestamps on the capture-relative clock without using frame arrival time or manual action offsets. The mapping inherits midpoint uncertainty bounded by the selected sample's round-trip latency; ending offset delta makes short-run drift observable. Acceptance compares the composited cursor hotspot with the actual dispatched mouse-down point, not the original target center.
