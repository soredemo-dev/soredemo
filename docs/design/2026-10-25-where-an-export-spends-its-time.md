# Where an export spends its time

2026-10-25. The owner asked whether Accelerate, or anything else, could make export faster.
`2026-10-25-the-next-round.md` said to measure before changing anything; this is the measurement,
and its conclusion is that **nothing in Soredemo's code is what an H.264 or HEVC export at a
Retina display's size waits on.**

## The instrument

`scripts/measure-export.sh` makes two ten-second sources at 3024 × 1964, 60 fps, H.264 from the
hardware encoder as the app records — one whose every frame changes (`testsrc2`), one that
barely moves, as most of a screen recording does — and runs
`CompositingTests.exportSpeedBreakdown` on each. That test does nothing unless
`SOREDEMO_MEASURE_EXPORT` names a movie. It times six passes, three runs each, median and
minimum, every run required to produce the same non-zero frame count:

| pass | what it adds |
| --- | --- |
| decode | the reader alone |
| decode + composite | the stage's composite, the export's own composition, read and discarded |
| decode + encode, BGRA | the encoder, fed what the export feeds it, with no composite |
| decode + encode, 4:2:0 | the encoder fed its own format — prices the colour conversion |
| export, H.264 / HEVC / ProRes 422 | the whole of `MP4Exporter.export` |

## What it measured

Apple M1 Pro, macOS 27.0.1 (26A434), commit `8e38e0f`, debug build. Medians, ms per frame:

| | busy | calm |
| --- | --- | --- |
| decode | 5.20 | 5.18 |
| decode + composite | 6.95 | 5.96 |
| decode + encode, BGRA | 13.44 | 13.29 |
| decode + encode, 4:2:0 | 13.42 | 13.31 |
| export, H.264 | 13.45 | 13.40 |
| export, HEVC | 13.96 | 13.41 |
| export, ProRes 422 | 11.09 | 11.42 |

Every row but one repeats to within a few hundredths of a millisecond across three such runs.
The composite does not: busy's ranged 6.95–9.35 between runs, which is why no conclusion below
rests on it.

**The export is as fast as the encoder with nothing in front of it.** Decode and encode alone,
no composite, cost what the whole export costs, so the composite is already overlapped with the
encode and removing it entirely would save nothing. About 74 frames a second: a minute of 60 fps
recording exports in about 49 seconds.

**The encoder's rate does not move with anything this code controls**, which makes it a property
of the hardware rather than of a resource the code could spend differently: the same with busy
and calm content, with BGRA and with 4:2:0, with H.264 and with HEVC. Checked outside this code:
ffmpeg's `h264_videotoolbox` encodes the same source in 8.1 s (74 fps), unchanged by
`-prio_speed 1`, `-bf 0` or both; at half the size it runs at 222 fps — three times, for a
quarter of the pixels. The limit is the media engine's pixel rate, about 440 million pixels a
second here.

So the hypotheses `the-next-round` listed are each discarded by a number above:

- the compositor's output in the encoder's own format — BGRA and 4:2:0 cost the same;
- reading, compositing and writing overlapped — they already are;
- Accelerate's vImage — it is a CPU library, and neither the composite (hidden behind the
  encoder) nor the encode (fixed-function hardware) runs on the CPU.

**ProRes is the exception, and it moves the bottleneck.** Its engine is a separate one: ffmpeg's
`prores_videotoolbox` encodes the same source at 195 fps. Through Soredemo it reaches about
90, because the composite — hidden behind H.264 — is now what the export waits on. This is the
one place where making the compositor faster would show, and only for ProRes. Not pursued: a
ProRes export is for handing to another editor, not the common path, and this was a debug build,
in which the Swift around Core Image runs slower than it ships.

## What follows

Not a change to the exporter. What makes an export faster is fewer pixels or fewer frames —
1080p is about three times faster than full Retina size, 30 fps twice as fast as 60 — and both
are choices a person makes knowing the cost. So the measurement belongs in front of that choice:
the export's time estimate (landscape item 4, *export cost before pressing*) can be priced from
the output's pixel rate against this machine's encoder, which is now a measured number rather
than a guess.

Not measured: a Mac with two media engines (M1 Max, Ultra), where splitting the timeline and
encoding the halves at once might double the rate. There is no such machine here, so it is
written down rather than claimed.
