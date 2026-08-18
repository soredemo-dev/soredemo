# Recorder parity — the bar moves, by owner decision

*2026-08-19. The owner's words: "my screen recording has to be as good as ScreenKite and
a Rust recorder and Screen Studio." This document records what that changes and what it does not.*

## What changes

`docs/PRODUCT.md` treats the recorder as "not defensible" and the free tier as "a
conversion surface, not a reach surface" — optimise for convincing, not counting. The
owner has overridden the consequence that was drawn from that: recorder quality is now a
BAR, not a residue. The defensibility analysis stands (a good recorder is still not a
moat); what falls is the licence it seemed to grant to ship a visibly worse recorder.

The ROADMAP's order changes with it. The recorder-quality path — the framing/zoom
pipeline, cursor quality, editing basics, export breadth — moves ahead of the
derivation-graph pipeline that Phases 5–8 need. Phase 0's untested premise stays
untested either way and stays flagged in the README.

## The gap matrix, measured against the tree on this date

| Capability | Screen Studio | ScreenKite | a Rust recorder | Soredemo today |
| --- | --- | --- | --- | --- |
| Auto-zoom on activity | ✅ signature | ✅ | ✅ | ☐ — `framing-*`/`zoom-blocks`/`camera-motion` all unstarted |
| Smooth cursor | ✅ signature | ✅ | ✅ | Rejected on evidence grounds — REVISITED below |
| Cursor shape fidelity | ✅ | ✅ | ✅ | Always an arrow; `PointerSample` records no shape |
| Click ripples | ✅ | ✅ | ✅ | ✅ pixel-proven |
| Card / background / rounded corners | ✅ | ✅ | ✅ | ✅ product-observable |
| Window shadow | ✅ | ✅ | ✅ | Modelled, persisted, **never drawn** — renderer's own header says so |
| Trim / cut / speed | ✅ | ✅ | ✅ | ☐ — `Editor/` not built |
| GIF export | ✅ | ✅ | — | ☐ — MP4 H.264 only, by disclosed scope |
| ProRes / MOV | ✅ | — | — | ☐ |
| Instant share link | — | — | ✅ wedge | Deliberately out (local-first) — unchanged |
| Webcam overlay | ✅ | — | ✅ | **In the "deliberately not built" table — open question below** |
| macOS 14/15 + Intel | ✅ | ✅ | ✅ | macOS 26 + Apple Silicon — unchanged, floor is a settled decision |

## Order, and why this order

1. **Shadow** — smallest gap with visible payoff; the fields exist, the renderer ignores
   them, and the render-core row already discloses it. Hours, not days.
2. **Cursor shape capture** — a FORMAT change (`PointerSample` gains a shape field), and
   format changes get more expensive with every recording that exists. The
   `CursorOverride.epoch` precedent: do it while the installed base is zero.
3. **Smooth cursor, revisited** — the rejection ("looking fine is what deletes the signal
   saying someone should look") conflated two consumers. RENDERING may smooth;
   REVIEW must not: blind intervals and gaps keep surfacing in the review UI
   regardless of what the pixels do. Presentation and diagnosis are different outputs
   of the same track, and the rejection's argument only ever applied to the second.
4. **The zoom pipeline** — `framing-targets` → `framing-gates` → `framing-depth` →
   `zoom-blocks` → `camera-motion`. The signature feature of all three competitors, and
   the largest block. Already the ROADMAP's own Phase 3 spine; the AX observation data
   it feeds on is captured and logged today.
5. **Editing basics** (trim/cut/speed) and **GIF export** follow.

## Open questions for the owner, not blocking the order above

- **Webcam overlay**: in PRODUCT.md's "deliberately not built" table ("doubles the
  capture surface"). Screen Studio and a Rust recorder both have it. Parity arguably includes it;
  the scope table says no. Items 1–4 are unaffected either way.
- **Region capture**: same table, same conflict, lower stakes.
