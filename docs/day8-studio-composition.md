# Day 8 studio composition

- Date: 2026-07-21
- Result: Passed with a throughput diagnostic warning
- Runtime: Node.js 20.19.4 and pnpm 10.34.0 on macOS arm64
- Dependencies added: none
- Inputs: accepted Day-3 capture/timeline, Day-4 resample plan, Day-6 cursor, and unchanged Day-7 camera track

## Visual contract

The v0.1 studio window is centered at `{ x: 240, y: 64, width: 1440, height: 952 }`. Its toolbar is 52 pixels high and its browser content occupies `{ x: 240, y: 116, width: 1440, height: 900 }`. Margins are 240 pixels horizontally and 64 pixels vertically. The outer radius is 22 pixels.

The background is an opaque diagonal gradient from `(0, 0)` to `(1920, 1080)`:

| Offset | Color |
| ---: | --- |
| 0 | `#7C3AED` |
| 0.55 | `#2563EB` |
| 1 | `#0EA5E9` |

The stylized macOS toolbar uses `#F5F5F7`, a one-pixel `rgba(15, 23, 42, 0.10)` separator, and red/yellow/green six-pixel circles at local centers `(22,26)`, `(42,26)`, and `(62,26)`. It deliberately has no title, URL bar, tabs, glyphs, icons, or font use.

The complete window uses a one-pixel `rgba(15, 23, 42, 0.12)` border and `rgba(15, 23, 42, 0.30)` shadow with blur 40 and offset `(0,16)`. Shadow creation is scoped by Canvas save/restore and pre-rendered once into a bounded 1520×1056 layer. This avoids recomputing an invariant blur while retaining one sequential output canvas and one sequential window canvas.

## Mask and layer verification

The manual quadratic rounded path is shared by clipping, shadow, and border. Synthetic pixel tests confirm background at extreme window corners, window pixels inside rounded arcs, no toolbar or browser leakage, deterministic traffic-light colors, an external shadow, a border above the surface, ripple pixels above browser pixels, and cursor changes above the ripple layer.

The full run reported:

```text
mask-leak frames:            0
black output-corner frames:  0
unsafe camera crops:         0
corrected camera crops:      0
```

Focused tests scan complete alpha output and confirm opaque RGBA. Runtime diagnostics sample the four output corners and four window-mask corners on every frame.

## Click feedback

All 30 browser-observed `mouseDownMs` timestamps started one ripple. The ring lasts 260 ms, expands from 3 to 20 output pixels, uses a two-pixel white foreground stroke, and fades from 0.55 to zero opacity. A four-pixel dark backing stroke at 35% of foreground opacity was added after visual review showed the white ring was too faint on the fixture's light content.

| Metric | Result |
| --- | ---: |
| Ripples started | 30 |
| Ripple-visible output frames | 233 |
| Maximum simultaneous ripples | 1 |
| Frames per click | 7–8 |

Ripple state uses output time and the active camera projection. Radius and stroke remain screen-space and do not scale with camera zoom. The cursor is rendered after both backing and foreground rings.

## Camera, framing, and landing regression

The accepted Day-7 camera states and segment timing were not regenerated or retimed. Only the output projection changed to the final 1440×900 content rectangle. Consequently one CSS pixel maps to one output pixel at zoom 1, without making that equality part of the camera contract.

| Metric | Result |
| --- | ---: |
| Camera segments / transitions / compressed | 61 / 30 / 0 |
| Center movement median / p95 / max | 0 / 43.396 / 91.967 px/frame |
| Fully visible targets | 30 |
| Clipped targets | 0 |
| Maximum target-center distance | 502.932 px |
| Landing median / p95 / max | 0 / 0 / 0 px |
| Landing failures over 1 / 2 px | 0 / 0 |

All 30 mouse-down mappings evaluated held cursor state. Cursor raster dimensions remained 30×38 output pixels with hotspot `(2,2)`.

## Full run, memory, and determinism

| Metric | Result |
| --- | ---: |
| Output frames / hash records | 1,751 / 1,751 |
| Source decodes / maximum retained | 1,751 / 1 |
| RGBA bytes processed | 14,523,494,400 |
| Rolling RGBA SHA-256 | `84fe114eb993a2f8e5ead56e920f169b1b8c1adf311df7038341294c30e72c06` |
| Execution time | 148,270.693 ms |
| Throughput | 11.809 frames/s |
| RSS before / peak / after | 100,319,232 / 221,478,912 / 215,531,520 bytes |
| Fitted RSS slope | 4,512.607 bytes/frame |
| Artifact size | 1,991,304 bytes |

Memory stayed bounded around a 211.2 MiB peak without forced collection or raw-frame accumulation. The slope is negligible relative to one 8.29 MB RGBA frame. Throughput is below the 15 frames/s warning. Pre-rendering the static shadow improved it from the initial 9.18 frames/s, but Day 9 should distinguish compositor throughput from encoder backpressure and avoid assuming real-time performance.

A nine-frame subset at indices `0, 26, 34, 60, 64, 68, 119, 808, 1750` covers establish, camera movement, held focus, ripple start/mid/end, hover feedback, worst motion, cursor-over-ripple, and final output. Two fresh executions matched camera, crop, cursor, ripple, landing, RGBA, PNG, and rolling hashes:

```text
eebdcb4aa1c71d32a90f09200c153e8d2bc2bff9524e3f1f76aba8902d0386bb
```

This is same-machine evidence, not a cross-platform pixel-determinism promise.

## Manual visual review

- The window is centered and the 240/64-pixel margins are mathematically balanced. The shallow vertical margin makes the app feel intentionally large rather than floating.
- The 52-pixel toolbar is restrained relative to the 900-pixel content area.
- Traffic lights are clearly legible without dominating the toolbar.
- Establish and focus frames keep fixture content readable. Zoomed pans intentionally discard unrelated context while preserving each active target.
- Rounded corners are clean in full frames and the contact sheet; no square corner artifacts or browser leaks were observed.
- The shadow is visible but attached to the surface. It is subtle on the blue end of the gradient and stronger against purple, without darkening browser pixels.
- The cursor remains crisp and visually consistent at every zoom.
- The contrast-backed ripple is visible on light content without reading as a glow or particle effect. It remains subtle and does not distract from the target.
- No black bars, uninitialized pixels, or matte remnants were observed.
- Alternating fixture targets still create noticeable lateral camera motion. The maximum final-layout step is 91.967 pixels/frame. The movement is continuous and the target remains readable, but the front-loaded curve can feel brisk; future studio-policy tuning should use representative product journeys rather than changing the accepted spike timeline here.
- The composition looks deliberate and substantially more polished than the automation-test base layer. It is an initial preset, not final proof that subjective cinematic quality is solved.

## Day 9 risks

- The 11.809 frames/s compositor throughput warning should remain visible when FFmpeg backpressure is added. Encoding must not introduce unbounded frame queues.
- The bounded cached shadow layer is deterministic on this macOS authority machine, but golden-frame work should detect native Canvas differences on future platforms.
- The fixed 1440×900 content area leaves no internal scale margin. Day 8 camera crops are valid, but later layout changes must continue using shared CSS projection rather than relying on the current 1:1 mapping.
- Camera whipping is a policy concern, not an encoder concern. Do not hide it with frame timing offsets during Day 9.
- The exact H.264/FFmpeg licensing and binary-resolution boundary remains required before encoding work begins.
