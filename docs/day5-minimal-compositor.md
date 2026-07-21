# Day 5 minimal compositor

- Date: 2026-07-21
- Result: Passed
- Runtime: Node.js 20.19.4 and pnpm 10.34.0
- Canvas: `@napi-rs/canvas@1.0.2`
- Source: successful Day-4 30 fps resample plan

## Contract

Each resample record resolves one selected JPEG relative to the source capture bundle. Resolution rejects absolute paths, traversal, symlink escapes, missing or non-regular files, decode failures, and dimension mismatches. Source indices must remain non-decreasing.

The loader retains one reusable native `Image`. A repeated consecutive source index is a cache hit; a new index replaces the decoded contents of the same object. The compositor retains one 1920×1080 canvas. It fills the complete output with opaque black, draws the 2880×1800 source into a deterministic contain rectangle, extracts RGBA bytes, awaits one consumer, and only then advances.

```text
source:       2880×1800
output:       1920×1080
content rect: x=96, y=0, width=1728, height=1080
matte:        rgba(0, 0, 0, 255)
```

Raw rows are top-to-bottom, pixels are left-to-right, and channels are `R, G, B, A`. Each frame has a 7,680-byte stride and 8,294,400 bytes total. Focused tests verify the binding's `canvas.data()` extraction order and complete opacity.

The timestamp boundary remains explicit: selected source time chooses browser pixels, while fixed output time will evaluate cursor, camera, and other composition metadata. Timeline event time remains independent of both.

## Dependency and license check

`@napi-rs/canvas@1.0.2` is MIT licensed and has no non-optional production child dependency. It declares eleven exact-version native optionals for Android arm64; macOS arm64 and x64; Windows arm64 and x64; and Linux arm, arm64, riscv64, and x64 across supported GNU/musl variants. The installed native package is `@napi-rs/canvas-darwin-arm64@1.0.2`, also MIT. The installed production license report contains only the project's already accepted MIT, ISC, Apache-2.0, and Python-2.0 categories; no non-permissive runtime dependency was introduced.

## Real bundle result

| Metric | Result |
| --- | ---: |
| Output frames | 1,751 |
| Source images decoded | 1,751 |
| Cache hits / misses | 0 / 1,751 |
| Maximum decoded images retained | 1 |
| Out-of-order selections | 0 |
| Logical RGBA bytes processed | 14,523,494,400 |
| Rolling RGBA SHA-256 | `668e89729ace6543a8915851779a5a9e1af50704200f98ef05344a7ee08c6009` |
| Execution time | 72,942.431 ms |
| Throughput | 24.005 frames/s |
| RSS before / peak / after | 95,027,200 / 167,690,240 / 155,254,784 bytes |
| Fitted RSS slope | -4,686.050 bytes/frame |
| Diagnostic artifact size | 690,762 bytes |
| Frame-hash records | 1,751 |
| PNG snapshots | 6 |

The current real plan chooses a unique source for every output frame, so the full run has no cache hits. Synthetic tests prove consecutive reuse without growing the cache.

## Memory finding

The first implementation used `getImageData()` for every full-size extraction. Although JavaScript retained only one frame reference, native buffers were reclaimed too slowly: two failed full trials peaked at 3,164,389,376 and 3,302,981,632 bytes. Isolated probes showed reusable JPEG decoding remaining near 119 MiB while 500 `getImageData()` calls rose to approximately 2.5 GiB.

`canvas.data()` exposes the same tested RGBA order and stayed near 112 MiB over the same 500-extraction probe. The accepted full run peaked at 159.9 MiB, ended at 148.1 MiB, and had no linear growth. No forced garbage collection, runtime flag, hidden concurrency, or relaxed threshold was used. The failed attempts are retained here because they materially determined the extraction boundary.

## Determinism and snapshots

A 22-frame subset contains frames 0–9, static click frame 59, hover click frame 119, and final frames 1741–1750. Two fresh compositor executions produced the identical rolling digest:

```text
358e796e004b0becd0ca9e9dac44ad504fcccb51af3072b980967f2db20cba95
```

Every per-frame hash also matched. This proves same-machine determinism for identical inputs, not cross-platform pixel determinism.

Snapshots were written for output indices 0, 59, 119, 349, 875, and 1750. Index 349 is click 006, the largest Day-4 source-to-mouse-down error. Every PNG is 1920×1080 and contains no overlay or label.

## Risks for Day 6

- `canvas.data()` is the bounded extraction path for this binding version; replacing it with `getImageData()` reintroduces a demonstrated multi-gigabyte native-memory failure.
- Full composition throughput was 24.005 frames/s, below real time but sufficient for an offline renderer. Cursor work must not add unbounded per-frame allocations.
- The current plan did not exercise real-bundle source reuse. Reuse is covered synthetically and must remain valid when later captures have gaps.
- The provisional contain rectangle and black matte are base-layer contracts only. Day 8 will own final window placement and styling.
- Pixel hashes are same-machine evidence. Soredemo still does not promise cross-platform pixel determinism.
