# Day 9 FFmpeg encoding

- Date: 2026-07-21
- Result: Passed
- Runtime: Node.js 20.19.4 and pnpm 10.34.0 on macOS 26.5.2 arm64
- npm dependencies added: none
- Input: accepted 1,751-frame Day-8 studio composition

## System preflight

The spike resolved `/opt/homebrew/bin/ffmpeg` and sibling `/opt/homebrew/bin/ffprobe`. Their real files are under `/opt/homebrew/Cellar/ffmpeg/8.0_1/bin/`. FFmpeg SHA-256 was:

```text
fe026c818fa2f3b07263bc92c559b21518014c727720db2dfb3a24d372618116
```

Both report version 8.0 and Apple clang 17.0.0. Preflight confirmed rawvideo input, the `libx264` encoder, `--enable-gpl`, and `--enable-libx264` before composition began. Complete build output remains in the ignored spike artifact and the configure line is preserved in [encoder-and-codec-notes.md](encoder-and-codec-notes.md).

## Rawvideo and backpressure contract

FFmpeg receives ordered 1920×1080 RGBA frames through stdin at 30 fps. Every frame is exactly 8,294,400 bytes with a 7,680-byte stride. The encoder validates consecutive indices and direct index-derived timestamps before writing.

`stdin.write()` returned false for all 1,751 frames. Soredemo awaited both the write callback and the matching drain event before allowing the reusable compositor buffer to advance. The maximum pending application state was one frame and 8,294,400 bytes; no producer queue or concurrent composition exists.

| Metric | Result |
| --- | ---: |
| Frames composed / written | 1,751 / 1,751 |
| Write-false / drain events | 1,751 / 1,751 |
| Maximum pending frames / bytes | 1 / 8,294,400 |
| Write latency median / p95 / max | 7.114 / 8.438 / 11.057 ms |

FFmpeg stderr is drained continuously into `ffmpeg.log`; only a bounded 64 KiB tail is retained in memory. The successful run emitted no FFmpeg warnings and exited zero without a signal.

## Atomic output and failure handling

Encoding targets a unique sibling `.partial.mp4`. Soredemo closes stdin, awaits exit zero, validates the temporary MP4, fsyncs it, and only then atomically renames it to the final path. Abort closes stdin, terminates and awaits the child, removes the partial, and preserves any prior final file.

The real failure probe requested two frames and finalized with none. It preserved the sentinel prior output and left zero partial files. Unit coverage also exercises wrong layout, ordering, short/long lifecycle use, early child exit, bounded noisy stderr, double finalization, consumption after finalization, and previous-output preservation.

An initial managed run exposed that optional `/bin/ps` sampling could be denied with `EPERM`; the unhandled diagnostic error terminated that trial and left its disposable partial file. Child-RSS sampling is now explicitly non-fatal. The authoritative rerun began by cleaning the scoped `.tmp` directory and finished with no partial file or FFmpeg process. Product encoding failures remain covered by the encoder abort path; abrupt host-process termination cannot guarantee cleanup without a later recovery sweep.

## MP4 result

```text
file:               .tmp/day9-ffmpeg-encode/soredemo-day8.mp4
size:               2,430,985 bytes
SHA-256:            1b891122f64b41b979b08739ce1ea46d98f60c95586f3a786d7cf6779bc78255
codec:              H.264, High profile, level 4.0
pixel format:       yuv420p
dimensions:         1920×1080
frame rate:         30/1
decoded frames:     1,751
average bitrate:    330,288 bit/s
audio streams:      0
```

FFprobe reports a final frame timestamp of 58.333333 seconds and media duration of 58.366667 seconds. The difference is one frame duration: frame timestamps identify frame starts, while media duration includes the final frame's display interval.

Every decoded timestamp is strictly increasing at 1/30-second cadence, every reported frame duration is 1/30 second within numerical tolerance, and the final timestamp matches `(frameCount - 1) / fps`. FFmpeg decoded the complete output with zero error. The top-level MP4 reader found `moov` before `mdat`, proving fast-start ordering. FFprobe exposes BT.709 color space and TV range for this build.

## Fidelity and repeatability

Seven selected original/decoded pairs cover establish, transition, maximum zoom, static and hover ripple, high-motion composition, and final output. RGB mean absolute error stayed below 0.96 per channel. RGB PSNR ranged from 46.453 to 48.094 dB. Maximum single-channel errors ranged from 78 to 91 around sharp antialiased edges. Alpha error was zero. Manual inspection found expected H.264/chroma-subsampling softness but no corruption, wrong frame, dimension change, or gross color shift.

A fresh 21-frame motion/chrome/cursor/ripple subset encoded twice. Both complete MP4 files had the same SHA-256:

```text
8dcfe981e0bdb3c1fcff6f335c63acae95940ba8e82f8b72413fabbb47a14665
```

FFprobe metadata, decoded timing, and three selected decoded RGBA hashes also matched. This proves same-machine, same-build bit identity only; it is not a cross-build or cross-platform promise.

## Performance and memory

| Metric | Result |
| --- | ---: |
| Composition plus encoding | 155,327.076 ms |
| Effective throughput | 11.273 frames/s |
| Parent RSS before / peak / after | 91,734,016 / 201,916,416 / 137,920,512 bytes |
| FFmpeg peak RSS | 759,873,536 bytes |
| Conservative summed peak | 961,789,952 bytes |

Parent RSS remained well below the 1 GiB gate. The child used substantially more memory than Node, but the conservative sum remained below 1 GiB on the authority machine. RSS sampling is a macOS diagnostic and not a portable runtime dependency.

## Day 10 risks

- The public render command remains intentionally disconnected. Day 10 needs the complete six-action executor before this pipeline becomes user-facing.
- The system-FFmpeg requirement needs clear doctor-style diagnostics later; automatic binary download remains unimplemented and unapproved.
- Abrupt parent termination can leave a partial sibling file. A future render workflow should remove stale partials under an exact, scoped ownership policy.
- Parent and FFmpeg combined memory approached 917 MiB. Later progress reporting or action execution must not introduce a frame queue.
- Output quality is strong for the deterministic fixture, but CRF 18 should be reviewed on representative text-heavy and animation-heavy applications before release.
- The GPL-conditioned libx264 and H.264 patent boundaries require release notices and user-facing documentation; this report is not legal advice.
