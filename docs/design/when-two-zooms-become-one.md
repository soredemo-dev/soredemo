# When two zooms become one

*Moved out of `Core/Sources/Framing/ZoomBlock.swift` 2026-08-30 — a set of measured decisions is a document.*

**Blocks merge only when they genuinely OVERLAP — no tolerance, and that is the
decision this type exists to get right.**

`zoom-blocks`' ROADMAP row warns that demo clicks are 1–3 s apart and an over-eager
merge collapses a whole demo into one zoom. Measured on a realistic six-click
sequence (paced, a rapid trio, a pause) before this was written: overlap-only and a
0.1 s tolerance both give four blocks; 0.25 s gives three; **0.5 s gives two**,
because each merged block's end reaches the next block's start and the merge chains
down the whole recording. A block is `preRoll + hold` = 1.4 s long, so consecutive
clicks 1.5 s apart leave a 0.1 s gap — any tolerance above that starts the chain.

Overlap-only still merges what should merge: three clicks inside 1.2 s become one
block rather than a camera twitching three times
(`clicksInsideOneAnothersBlocksBecomeOneZoom`).

**Deterministic**: clicks are grouped by boot epoch, sorted within it, and swept
once. The row asks for a deterministic merge, and a sweep that depended on arrival
order would produce different footage from one recording between runs.

**Epochs never share a block.** Two boot sessions produce overlapping host times, so
a block spanning both would be a duration computed across two clocks — the
`1a98402` family. Grouped, not interleaved.

`coverage` is the share of the OUTPUT frame the recording occupies — 1 in the
recording's own shape — and it reaches `FramingDepth.zoom(for:coverage:)` unchanged.
Carried here rather than applied by a consumer because `ZoomBlock.zoom` exists so
that a consumer does NOT recompute the depth and risk disagreeing; a per-variant
correction applied downstream would reintroduce exactly that second answer.
