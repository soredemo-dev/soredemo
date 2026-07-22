# Day 12: split visual authority

Day 12 established two deliberately separate gates without changing production capture behavior.

## Exact synthetic result

The official `macos-arm64-canvas-1.0.2` run rendered 13 semantic frames through `StudioFrameCompositor`. Establish, camera transition start/midpoint/completion, move interpolation/landing, ripple start/midpoint/completion, type focus, second click, rounded corner, and final hold all matched their checked-in RGBA and PNG SHA-256 values exactly.

Independent pixel assertions passed for opaque output, background gradient, toolbar, traffic lights, rounded mask, shadow, border, camera-projected browser pixels, click ripple, cursor-over-ripple ordering, and the fixed 30×38 cursor with hotspot `(2,2)`.

An intentional unit seam changed a candidate frame and proved that verification produced expected, actual, difference, and heatmap PNGs with deterministic difference statistics. The checked-in baseline was not mutated.

## Live structural result

The successful public render used Playwright 1.61.1, Chromium 149.0.7827.55 revision 1228, Node 20.19.4, macOS arm64, Canvas 1.0.2, and system FFmpeg 8.0. It captured 698 genuine 2880×1800 frames over a 1440×900 CSS viewport at DPR 2, then produced 367 frames at 30 fps.

All ten planned actions completed and covered all six kinds. The four cursor-bearing measurements were one moveTo, two clicks, and one type focus; every landing error was zero, every target was fully visible, pointer-enter and focus gates passed, and actual target pixels were present beneath the cursor. Sixteen selected RGBA/MP4 proof states preserved exact compositor, encoder-write, and decoded-frame indexes.

The decoded proofs had maximum RGB mean absolute error 2.811, minimum RGB PSNR 35.366 dB, and maximum channel error 90, with no wrong or corrupt frame. The output contained 367 H.264/yuv420p 1920×1080 frames at 30 fps over 12.233333 seconds.

One earlier public attempt correctly failed on a backward CDP timestamp: frame 167 moved backward 9.777 ms. The existing hard failure preserved diagnostics and did not clamp, reorder, drop, or replace the timestamp. A fresh independent render succeeded.

## Observed variability

Two successful normal production runs differed as expected:

| Measurement | Earlier run | Day-12 run |
| --- | ---: | ---: |
| Capture duration | 11,487.163 ms | 12,225.340 ms |
| Source frames | 748 | 698 |
| Output frames | 345 | 367 |
| Cursor points | 688 | 732 |
| Rolling RGBA SHA-256 | `9d1b63aa…` | `89ca8011…` |

These whole-run differences are reported, not treated as exact-golden failures. Both runs satisfied the structural cursor, scale, composition, backpressure, and encoded-output contracts.

## Release risks

- The CDP screencast surface remains experimental and can emit a backward epoch timestamp; Soredemo continues to fail without correction after actions begin.
- Exact compositor goldens are authoritative only for the recorded macOS arm64 Canvas profile. Canvas or OS upgrades require explicit candidate review and promotion.
- System FFmpeg output remains build-dependent and lossy. Selected decoded frames, not MP4 file hashes, are the encoded visual authority.
- Golden and live proof workspaces may contain private application pixels and must stay local.
