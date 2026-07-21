# Day 2 CDP capture and clock spike

- Date: 2026-07-21
- Result: Timing and bundle gate passed; the native-resolution claim was superseded by Day 10.1
- Platform: macOS 26.5.2 (build 25F84), Apple Silicon (`arm64`)
- Supported-runtime trial: Node.js 20.19.4
- Package manager used during Day 2: pnpm 11.15.1
- Playwright: 1.61.1, exact dependency
- Chromium: 149.0.7827.55, Playwright revision 1228

## Procedure

The local fixture server bound to `127.0.0.1` on normal macOS and served `/workspace`, `/styles.css`, and `/app.js`. A Chromium preflight blocked all non-loopback requests and rendered the expected heading, sticky element, and deterministic animated probe without external resources.

Each accepted CDP frame was copied into an owned buffer and enqueued before acknowledgement. One ordered writer parsed its JPEG dimensions, wrote the JPEG and newline-delimited record, and maintained receive, acknowledgement, write, high-water, overflow, and write-failure counters. The spike verified exact correspondence between manifest count, frame records, indices, paths, dimensions, and files on disk.

Clock calibration took nine startup samples of Chromium's `performance.timeOrigin + performance.now()` between Node monotonic readings and selected the lowest-round-trip sample. The startup mapping remained fixed. A second nine-sample calibration measured ending offset drift only.

## Native-resolution finding

`deviceScaleFactor: 2` plus `Page.startScreencast` maximum dimensions did not by itself produce 2× JPEGs in the pinned headless Chromium; it returned 1440×900 and the spike failed loudly. The Day-2 workaround used `Emulation.setVisibleSize` at 2880×1800 while retaining 1440×900 CSS metrics. It produced 2880×1800 files, but Day 10.1 pixel evidence later proved that Chromium painted only 1× application pixels into the upper-left quadrant. File dimensions, `devicePixelRatio`, and CSS metrics did not prove native raster scale.

The corrected capture launches Chromium with `--force-device-scale-factor=2`, keeps CDP metrics at 1440×900, does not call `Emulation.setVisibleSize`, and verifies composed and decoded cursor-target pixels in addition to browser metrics and JPEG dimensions. It does not upscale captured frames. The Day-2 clock, ordering, acknowledgement, and bundle findings remain valid; its original resolution qualification does not.

## Final Node 20 trials

| Metric | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| Capture duration (ms) | 5951.705 | 5951.419 | 5951.400 |
| Frame count | 553 | 558 | 554 |
| Source pixels | 2880×1800 | 2880×1800 | 2880×1800 |
| Gap min / median / p95 / max (ms) | 7.160 / 8.838 / 16.640 / 18.087 | 7.159 / 8.760 / 16.565 / 17.233 | 7.032 / 8.900 / 16.573 / 51.458 |
| Receive delay median / p95 / max (ms) | 19.434 / 21.412 / 29.738 | 19.322 / 21.406 / 28.567 | 18.589 / 20.735 / 75.294 |
| Startup calibration RTT (ms) | 0.471 | 0.275 | 0.292 |
| Startup offset (ms) | 1784590557143.649 | 1784590557143.702 | 1784590557143.544 |
| Ending offset (ms) | 1784590557143.708 | 1784590557143.638 | 1784590557143.549 |
| Offset delta (ms) | +0.059 | -0.064 | +0.005 |
| Queue high-water mark | 1 | 1 | 1 |
| Queue overflows | 0 | 0 | 0 |

Every run had zero duplicate timestamps, zero backward timestamps, zero write failures, and exact equality between received, acknowledged, and written frame counts. No p95 frame gap exceeded 100 ms. The largest observed gap was 51.458 ms, and the largest receive delay was 75.294 ms in run 3. The largest absolute clock offset delta was 0.064 ms. No machine-specific or per-action timing correction was introduced.

## Risks for Day 3

- `Page.startScreencast` is Experimental, and forced device-scale behavior remains version-sensitive. The exact Playwright and Chromium versions remain pinned, and their behavior must stay behind runtime dimension and pixel-evidence gates.
- The explicit capture surface produces roughly 90 delivered frames per second on this animated fixture. Day 3 must continue using CDP timestamps rather than interpreting frame arrival cadence as an output frame rate.
- Short receive-delay spikes and a 51 ms source gap occurred without queue buildup. The Day-3 ±250 ms click-window gate must measure these around actual mouse-down events.
- pnpm 11.15.1 could not itself run under Node 20. Day 3 resolved this recorded issue by pinning pnpm 10.34.0; the application runtime remains Node 20 or later.
