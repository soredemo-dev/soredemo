# Day 7 post-production camera spike

- Date: 2026-07-21
- Result: Passed
- Runtime: Node.js 20.19.4 and pnpm 10.34.0 on macOS arm64
- Inputs: successful Day-3 capture and timeline plus the Day-4 30 fps resample plan
- Runtime dependency added: exact `bezier-easing@3.0.1`, MIT, no production dependencies

## Camera and projection contract

The camera exists only in composition. Its zoom and center use the 1440×900 CSS viewport, while the selected browser JPEG remains 2880×1800. Each frame converts the clamped visible CSS rectangle to a 2× source crop and draws that crop into `{ x: 96, y: 0, width: 1728, height: 1080 }` with the nine-argument Canvas draw operation.

One projection function maps commit bboxes, click points, and cursor CSS coordinates through the evaluated camera. Browser source time selects pixels; fixed output time evaluates camera and cursor metadata. The cursor hotspot follows the camera projection, but its bundled SVG remains 30×38 output pixels with hotspot `(2, 2)`.

All conceptual geometry remains fractional. No live CSS transform, browser zoom, viewport change, crop file, per-click offset, or coordinate correction was introduced.

## Studio policy and track

The provisional internal policy uses a 600 ms establish hold, 120 ms camera lead, 100 ms pre-click settle target, 350–700 ms transition range, 1.25 default focus zoom, 1.35 maximum zoom, and `cubic-bezier(0.22, 1, 0.36, 1)` easing. Adaptive zoom fits a padded commit-time target rectangle to retain context.

The real track contains 61 contiguous segments: 30 transitions, the establish segment, and 30 holds. No transition overlaps or required timing compression. The first transition runs 600.000–1,112.038 ms for 512.038 ms; the other transitions are 456.760 ms. Transition output coverage is 13–16 frames. Holds range from 600.000 to 2,246.457 ms.

Zoom over the complete output is:

| Metric | Zoom |
| --- | ---: |
| Minimum | 1.000000 |
| Median | 1.258771 |
| p95 | 1.283869 |
| Maximum | 1.283869 |

The fixture alternates two focus states: the static target resolves to approximately 1.283869× at `(560.805, 350.503)` CSS pixels, while the larger hover target resolves to 1.25× at `(864, 360)`. Edge clamping is part of authoritative camera evaluation.

Per-frame center movement measured in equivalent output pixels was 0 median, 52.076 p95, and 110.360 maximum. Per-frame absolute zoom delta was 0 median, 0.005228 p95, and 0.077935 maximum. The large upper-tail center step follows the deliberately front-loaded easing curve during alternating fixture pans; it is continuous rather than a segment-boundary jump, but should be reviewed visually when Day 8 establishes the final window size.

## Target framing and cursor landing

All 30 commit-time target rectangles were fully visible at their mapped mouse-down output frame. Every projected click point remained inside its projected target. No target was clipped. Edge clamping allowed a maximum target-center distance of 603.519 output pixels from the content center; exact centering is not required when preserving captured bounds.

| Landing metric | All | Static | Hover |
| --- | ---: | ---: | ---: |
| Clicks | 30 | 15 | 15 |
| Median distance | 0 px | 0 px | 0 px |
| p95 distance | 0 px | 0 px | 0 px |
| Maximum distance | 0 px | 0 px | 0 px |
| Absolute X median / p95 / max | 0 / 0 / 0 px | 0 / 0 / 0 px | 0 / 0 / 0 px |
| Absolute Y median / p95 / max | 0 / 0 / 0 px | 0 / 0 / 0 px | 0 / 0 / 0 px |
| Exact / linear / held | 0 / 0 / 30 | 0 / 0 / 15 | 0 / 0 / 15 |

The actual cursor draw hotspot supplies every measurement. The fixed raster remained 30×38 output pixels at every zoom. No landing event was excluded or shifted.

## Full run, memory, and artifacts

| Metric | Result |
| --- | ---: |
| Output frames / hash records | 1,751 / 1,751 |
| Source decodes / retained images | 1,751 / 1 maximum |
| Cursor visible / hidden frames | 1,747 / 4 |
| Cursor exact / linear / held frames | 0 / 1,476 / 271 |
| Unsafe crops / epsilon corrections / black-edge frames | 0 / 0 / 0 |
| RGBA bytes | 14,523,494,400 |
| Rolling RGBA SHA-256 | `dc8b7450777f76560c9d8f4c06e0f82c3f22dc14507e6b79aec1524d3f6d8bb5` |
| Execution time | 72,918.372 ms |
| Throughput | 24.013 frames/s |
| RSS before / peak / after | 98,369,536 / 179,879,936 / 179,879,936 bytes |
| Fitted RSS slope | 5,457.856 bytes/frame |
| Diagnostic artifact size | 1,356,874 bytes |

The run retained `canvas.data()`, one reusable output canvas, one decoded browser image, one cursor asset, sequential consumption, and awaited backpressure. Peak RSS stayed near 171.5 MiB, well below 1 GiB and below the Day-7 warning threshold. The fitted slope is small relative to an 8.29 MB frame and did not approach linear raw-frame accumulation. No raw RGBA files or JPEG copies were written.

The artifact contains the manifest, 1,751 newline-terminated hashes, camera track, 30 landing measurements, 30 framing measurements, and nine unique 1920×1080 snapshots covering establish, transition, focus, target types, large pan, maximum zoom, worst diagnostics, and final state.

## Determinism and Day 8 risks

Two fresh eight-frame executions covered establish, transition start/midpoint/completion, hold, static and hover clicks, maximum zoom, and final state. Camera states, source crops, cursor states, landing records, RGBA hashes, PNG hashes, and rolling digests matched:

```text
fa24be8c8f8cb59673a5e4327781e6c7c7b58acd71404248e29449b8ec7302a1
```

This is same-machine structural and pixel evidence, not cross-platform pixel determinism.

- Day 8 changes the app window rectangle, so camera projection and crop framing must consume the new content rectangle without changing CSS camera state.
- The maximum per-frame center movement merits visual review with the final window layout even though segment boundaries are mathematically continuous.
- The current fixture has short spacing between alternating clicks; camera anticipation for the next path can begin shortly before the previous mouse down. Targets remained fully visible, but narrative policy may later need action-aware scheduling.
- Day 7 focuses `targetBboxAtCommit` only. Narrative result framing from `focusAfter` awaits resolved full-plan execution.
- Click feedback remains deferred. Browser chrome, masks, shadows, gradients, FFmpeg, and public render integration remain unimplemented.
