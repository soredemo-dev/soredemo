# Day 6 cursor landing gate

- Date: 2026-07-21
- Result: Passed
- Runtime: Node.js 20.19.4 and pnpm 10.34.0
- Source: successful Day-3 timeline and Day-4 resample plan
- Runtime dependencies added: none

## Cursor asset

The bundled `assets/cursor.svg` is an independently drawn white arrow with a dark outline, no font, external resource, or embedded raster. It has 30×38 intrinsic dimensions and renders at a fixed 30×38 output pixels. Its source and rendered hotspot is `(2, 2)`, the arrow tip.

```text
SHA-256: 051c01324176fc5098a1db7de4b3fa56e83bab781836551b76cfd7201439d44c
```

The asset is decoded once per compositor execution and is included in the npm publish allowlist.

## Coordinate and timing contract

Cursor points remain viewport-relative CSS pixels. With the 1440×900 viewport contained at `{ x: 96, y: 0, width: 1728, height: 1080 }`, both axes use a 1.2 output-pixel-per-CSS-pixel scale:

```text
screenX = 96 + cssX × 1728 / 1440
screenY =  0 + cssY × 1080 / 900
```

Fractional screen positions are preserved for both Canvas draw coordinates and landing measurements. The rendered hotspot offset is derived from cursor asset metadata and subtracted from the screen hotspot. Cursor dimensions remain fixed in output pixels and do not inherit source JPEG scale, device scale factor, or future browser-camera transforms.

Browser pixels are still selected with the Day-4 source timestamp. The cursor is evaluated only at fixed output time. Timeline mouse-down timestamps remain unchanged.

## Recorded cursor track

The global track directly references all 30 Day-3 `cursorPath` arrays and their 5,910 measured points. No geometry was regenerated, smoothed, retimed, or copied from package timestamps. Adjacent paths join with zero CSS-pixel discontinuity.

The cursor is hidden before 129.041 ms. It interpolates linearly between measured points, holds the final point through hover settling and click dispatch, and holds the final recorded point after 57,392.499 ms through composition end. Sequential evaluation uses ordered pointers rather than searching all path points per frame.

## Landing gate

| Metric | All clicks | Static target | Hover target |
| --- | ---: | ---: | ---: |
| Clicks measured | 30 | 15 | 15 |
| Distance median | 0 px | 0 px | 0 px |
| Distance p95 | 0 px | 0 px | 0 px |
| Distance maximum | 0 px | 0 px | 0 px |
| Absolute X median / p95 / max | 0 / 0 / 0 px | 0 / 0 / 0 px | 0 / 0 / 0 px |
| Absolute Y median / p95 / max | 0 / 0 / 0 px | 0 / 0 / 0 px | 0 / 0 / 0 px |
| Exact / linear / held at mouse down | 0 / 0 / 30 | 0 / 0 / 15 | 0 / 0 / 15 |
| Failures over 1 px / 2 px | 0 / 0 | 0 / 0 | 0 / 0 |

Every mapped 30 fps mouse-down frame occurs after its movement reached the recorded click point, so all 30 measurements use held cursor state. All errors tie at zero; stable ordering therefore identifies `click-001` as the reported worst click. Its output-grid delta is -9.836 ms, selected-source-to-output delta is -5.022 ms, and selected-source-to-mouse-down delta is -14.857 ms. No offset or timing correction was applied.

The real-frame raster probe compares a small pre-cursor browser sample with the actual cursor-composited RGBA frame at every landing. All 30 showed changed cursor pixels in the expected raster neighborhood.

## Full composition result

| Metric | Result |
| --- | ---: |
| Output frames | 1,751 |
| Cursor-visible / hidden frames | 1,747 / 4 |
| Exact / linear / held visible frames | 0 / 1,476 / 271 |
| Source decodes | 1,751 |
| Maximum decoded browser images retained | 1 |
| RGBA bytes processed | 14,523,494,400 |
| Rolling RGBA SHA-256 | `aa06b101e05b5422b80fa862d542e00ebe23031dc7303bf4bf4f96634402f5d9` |
| Execution time | 74,224.948 ms |
| Throughput | 23.590 frames/s |
| RSS before / peak / after | 96,763,904 / 186,662,912 / 173,424,640 bytes |
| Fitted RSS slope | -3,706.070 bytes/frame |
| Artifact size | 789,621 bytes |

The compositor retains `canvas.data()` as its full-frame RGBA readback. Memory stayed bounded below 178.0 MiB peak without forced garbage collection. No raw RGBA files or JPEG copies were written.

## Artifacts and determinism

The artifact contains 1,751 newline-terminated frame-hash records, 30 normal 256×256 landing crops, four unique 1920×1080 full frames, the manifest, and all 30 landing records. Five requested full-frame purposes resolve to four files because `click-001` is both the first static click and the stable worst-error click.

A seven-frame subset covers hidden state, first appearance and movement, held static and hover clicks, and final held frames. Two fresh executions produced identical RGBA hashes, cursor states, landing measurements, PNG hashes, and rolling digest:

```text
d717ec23ca59d6aee9a8e8ad3785f443c0e0399a54e10e18860b8eb655cedc78
```

This is same-machine determinism evidence, not a cross-platform pixel guarantee.

## Click feedback and Day 7 risks

Provisional click feedback was deliberately deferred. It was optional and would not strengthen the mandatory cursor landing proof.

- Day 7 must apply camera transforms only to browser pixels. The cursor remains a fixed-size screen-space layer above them.
- Any future click feedback must evaluate browser-observed `mouseDownMs` at output time and render below the cursor.
- `canvas.data()` remains mandatory; `getImageData()` previously demonstrated multi-gigabyte growth.
- Cursor rendering reduced throughput from 24.005 to 23.590 frames/s and raised peak RSS from 159.9 to 178.0 MiB, both acceptable for offline composition.
- All landing errors were zero because each grid mapping landed in a recorded hold. A future capture with a moving mouse-down frame must fail honestly if it exceeds the fixed threshold.
