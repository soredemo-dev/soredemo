# Day 10.1: cursor-bearing action visual synchronization

## Classification and reproduction

The reviewed label, `Growing hover target`, belongs to action index 1, `moveTo-002`, with semantic target `testId: hover-target`. In the preserved original Day-10 timeline it ran from 962.152 ms to 3,163.021 ms. Its recorded path began at `(0, 0)` and ended at destination `(1106, 299)` at 2,942.995 ms. The next cursor-bearing event, `click-003`, began at 3,243.087 ms.

The original screenshot's exact output index cannot be recovered from the textual review alone. Direct decoding removed the ambiguity: output frame 89 at 2,966.667 ms was the first fixed frame after path completion, frame 95 at 3,166.667 ms was the first frame after action completion, and frame 97 at 3,233.333 ms was the last frame before the next cursor path. All three still showed the browser target hundreds of pixels left of the cursor. The issue was therefore a confirmed completed-action rendering defect, not a legal movement midpoint.

## Root cause and fix

The global cursor track already extracted `moveTo`, `click`, and `type`, sorted measured timestamps, retained terminal points, held them until the next event began, and evaluated them at output time. Camera, target, and cursor diagnostics also shared one mathematical projection.

The mismatch was below that layer. `Emulation.setVisibleSize(2880, 1800)` made CDP emit 2880×1800 JPEG files, but Chromium painted the 1440×900 application at 1× scale into the surface's upper-left quadrant. The compositor treated the full JPEG as a genuine 2× representation and cropped browser pixels accordingly. Cursor and target diagnostics agreed with each other because both used CSS geometry; neither inspected where the target pixels actually appeared.

The corrected capture launches pinned Chromium with `--force-device-scale-factor=2`, leaves CDP device metrics at 1440×900, and no longer requests a 2880×1800 visible size. The resulting headless screencast contains genuine 2× page pixels across the complete 2880×1800 JPEG. No path, event time, camera state, or coordinate offset changed.

## Production visual gate

Production composition now builds a discriminated measurement for every cursor-bearing event:

- `moveTo`: first fixed output frame at or after the final measured path timestamp;
- `click`: existing browser-observed mouse-down mapping;
- `type`: first fixed output frame at or after its final focus path timestamp.

Every record preserves output and source timestamps, camera state, visible CSS crop, CSS and projected target bboxes, cursor CSS and screen coordinates, the actual draw origin, rendered 30×38 size, `(2, 2)` hotspot, error, target containment, full target visibility, and changed cursor pixels. Move events also preserve pointer-enter and terminal-hold checks; type events preserve browser focus verification.

The bounded encoder consumer writes one SHA-256 record per RGBA output frame and small 256×256 crops for movement midpoint, path or mouse-down landing, action completion, and final hold. FFmpeg then decodes the same selected output indexes from the temporary MP4. Decoded crops are compared with their originating RGBA crops before atomic publication. The fixture gate additionally requires visible target-pixel variation inside every projected landing bbox, which makes the original false-2× capture fail even though its geometry reports zero error.

## Corrected public render

The unchanged public command produced 748 genuine 2880×1800 capture frames over 11,487.163 ms and 345 fixed output frames over 11.5 seconds. The MP4 is 743,140 bytes with SHA-256 `cc4e9c3d2cb46706e3726ef4d7ad2d91112ca760bfb24d695eb176e73edfd4e7`. All 345 encoder writes observed and awaited backpressure, with one pending 8,294,400-byte frame maximum.

The four cursor measurements were one `moveTo`, two clicks, and one type focus. All errors were exactly zero output pixels, all hotspots were inside their projected commit bboxes, and all targets were fully visible. `moveTo-002` recorded a genuine pointer-enter and held its final point at action completion and through the final output frame before `click-003` began. The type event verified real focus.

For corrected `moveTo-002`, the path ended at 2,808.575 ms. Its first post-path output was frame 85 at 2,833.333 ms, using source frame 265 at 2,832.628 ms. Camera zoom was 1.25 with visible CSS crop `{ x: 288, y: 0, width: 1152, height: 720 }`. The projected target bbox was `{ x: 1127.002, y: 459.519, width: 271.739, height: 64.525 }`; the cursor hotspot was `(1262.5, 492.25)` and the real draw origin was `(1260.5, 490.25)`.

Sixteen RGBA proof crops and sixteen corresponding MP4 proof records passed. Crop mean absolute channel error ranged from 1.578 to 2.071; the maximum individual channel error was 80, with no wrong-index or corrupt frame. The fixed hover crop visibly contains the enlarged button and cursor at the same output position.

## Packed-package gate

An isolated Node 20 project installed `soredemo-0.1.0.tgz` and rendered the same ten-action plan through its packed binary. It captured 720 source frames, emitted 328 output frames over 10.933333 seconds, and produced a 757,782-byte MP4 with SHA-256 `8f21246cc313a134f19dae63d02c53d22d21714d92857379c6c3e5ced2fe0836`. The packed gate again produced exactly one move, two click, and one type-focus measurement with zero error, complete containment, pointer-enter, focus, terminal holds, 16 matching decoded proofs, and one pending encoder frame maximum.

## Remaining risk

One public reproduction attempt failed because CDP reported a frame timestamp 2.458 ms behind its predecessor. The run failed loudly and preserved its workspace; no receive-time substitution or timestamp correction was added. This intermittent pinned-Chromium behavior remains a Day-11 diagnostic risk. The capture raster fix also relies on a Chromium launch flag and must remain version-gated when Playwright or Chromium changes.
