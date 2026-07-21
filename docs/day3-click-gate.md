# Day 3 real cursor and click gate

- Date: 2026-07-21
- Result: Passed
- Platform: macOS 26.5.2 (build 25F84), Apple Silicon (`arm64`)
- Runtime: Node.js 20.19.4 and pnpm 10.34.0
- Playwright: 1.61.1
- Chromium: 149.0.7827.55
- Cursor geometry: ghost-cursor 1.4.2, exported `path()` only

## Dependency boundary

`ghost-cursor@1.4.2` is ISC licensed. Its production subtree is `@types/bezier-js@4.1.3`, `bezier-js@6.1.4`, `debug@4.4.3`, and `ms@2.1.3`; each is MIT licensed. Puppeteer is a development dependency in the upstream package metadata but did not enter Soredemo's installed production tree.

Soredemo does not use `GhostCursor`, a Puppeteer controller, mouse helper, click method, or move method. Package timestamps are reduced to relative spacing and rescaled. Every accepted coordinate is dispatched through `page.mouse.move()`, and the measured command-interval midpoint becomes that point's capture-relative timeline time.

## Gate result

One continuous screencast alternated 15 static-target clicks and 15 hover-target clicks. The cursor began each path at its last known real browser position. Every target was stable before path generation, every deterministic click point remained inside its commit bbox, every `elementFromPoint()` hit test matched the target or a descendant, and all clicks used `page.mouse.down()` followed by `page.mouse.up()`.

| Metric | Result |
| --- | ---: |
| Application clicks | 30 |
| Pointer-down events | 30 |
| Browser click events | 30 |
| Path points, min / median / p95 / max | 197 / 197 / 197 / 197 |
| Mouse-move RTT, median / p95 / max | 8.648 / 10.112 / 33.518 ms |
| Pointer-down coordinate error, median / p95 / max | 0 / 0 / 0 CSS px |
| All-target bbox change, median / p95 / max | 14.992 / 29.985 / 29.985 CSS px |
| Static-target bbox change, median / max | 0 / 0 CSS px |
| Hover-target bbox change, median / max | 29.985 / 29.985 CSS px |
| Local mouse-down gap, p95 / max | 24.111 / 24.913 ms |
| Nearest-frame distance, median / p95 / max | 3.859 / 7.296 / 8.111 ms |

The worst local frame gap was 24.913 ms around `click-004`; that click's nearest frame was 4.248 ms from mouse down. All 15 hover clicks recorded genuine target-level `pointerenter` events and measurable CSS-transition bbox changes. The static target remained geometrically unchanged.

## Capture integrity

The final capture lasted 58,336.856 ms and contained 5,428 JPEGs at 2880×1800. Browser metrics remained `innerWidth: 1440`, `innerHeight: 900`, and `devicePixelRatio: 2`. Every frame reported `pageScaleFactor: 1` and zero scroll offsets for this fixture state.

The manifest, JSONL, and JPEG counts matched. Frame timestamps had zero duplicates and zero backward steps. Queue counts were `received = acknowledged = written = 5428`, high-water mark 2, zero overflow, and zero write failures. Startup clock-calibration RTT was 0.530 ms and ending offset delta was +0.010 ms. `timeline.json` contained 30 unique click events whose path and browser-event times all fell inside the capture.

The generated bundle occupied approximately 342 MB under `.tmp/day3-click-gate/` and is ignored by Git.

## Failed attempts and fixes

- pnpm 11 could not support the documented Node 20 development floor. Exact pnpm 10.34.0 accepted the existing frozen lockfile and passed the full toolchain under Node 20.19.4.
- The initial package smoke called machine-global pnpm 11 from the nested `prepack` script. `prepack` now executes the build commands directly under the active runtime.
- The first gate command did not compile the new script because the spike tsconfig named only the Day-2 entrypoint. It now includes `scripts/*.ts` with an explicit root directory.
- A window capture listener did not receive Chromium's non-bubbling `pointerenter`. The init script now attaches genuine capture-phase listeners directly to test-ID targets and instruments later targets with a mutation observer.

## Day 4 risks

- Raw native-resolution capture volume is high: this 58-second gate produced approximately 342 MB and more than 5,400 source frames. Day 4 resampling must stay streaming or bounded and use CDP timestamps rather than loading decoded images wholesale.
- Real Playwright movement commands had an 8.648 ms median round trip and extended this gate beyond the nominal path schedules. Timeline points correctly contain measured times; future choreography must account for dispatch throughput without inventing timing offsets.
- The largest mouse-command RTT was 33.518 ms. Day 4 must preserve the measured timeline instead of reconstructing motion from proposed package timing.
- `Emulation.setVisibleSize` remains an Experimental, version-sensitive native-resolution invariant.
- `mouseUpMs` and click-event `endMs` are intentionally equal because the browser-observed pointer-up is the action boundary.
