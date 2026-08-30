# What a codec keeps

*Measured 2026-08. Code: `Core/Sources/Compositing/TransparentExport.swift`,
`Core/Sources/Compositing/CodecSupport.swift`, `Soredemo/Export/CodecVerdicts.swift`.*

Two properties of an export are decided by the codec and are invisible at the
moment they are lost: whether a transparent background survives, and whether the
coloured fringes of anti-aliased text survive. Both fail silently. This is what
was measured and what the code does about it.

## Transparency

A transparent background is a property of the picture; whether it survives is a
property of the codec. Nothing connects the two, and the failure has no symptom
when it happens: `AVAssetWriter` accepts a transparent frame for H.264 without a
word, encodes the alpha away, and returns a video with a black rectangle where
somebody asked for nothing. They find out after the export, after the upload,
with no way to tell it from a bug in whatever they dropped it into.

Measured one codec at a time, by writing a frame opaque on one half and fully
transparent on the other and reading the alpha back out of the file:

| codec | left | right | |
|---|---|---|---|
| ProRes 4444 | 255 | 0 | carries it |
| HEVC with Alpha | 255 | 0 | carries it |
| ProRes 422 | 255 | 255 | silently opaque |
| HEVC | 255 | 255 | silently opaque |

Nothing was reported for either of the bottom two. That silence is what
`TransparentExport` exists to break.

### A refusal, not a substitution

The tempting alternative is to switch the codec quietly to one that works. It is
wrong for the reason every silent correction in this project is wrong: somebody
who chose H.264 chose it because of where the file is going, and handing them a
`.mov` they did not ask for trades one surprise for another. The refusal names
both halves of the mismatch so the person can change whichever one they meant.

`Outcome` has three cases rather than a `Bool` because "this export has no
transparency to carry" and "this export carries it" are both fine and are not the
same fact — and a caller that could not tell them apart could not explain itself.

### The order the two are offered in

`codecsThatCarryIt` lists HEVC with Alpha first, which is the opposite of what
every article on transparent video says. ProRes 4444 is the name everybody knows;
measured on sixty frames of 640×360 it is 14,563,749 bytes against HEVC with
Alpha's 135,432 — **107 times larger for the same picture**. The one that should
be reached for first is listed first. ProRes 4444 stays on the list because an
editor asking for ProRes is asking for ProRes.

### What transparency costs

*Moved out of `Core/Sources/Compositing/ExportFormat.swift` 2026-08-30 — a measurement table is a document.*

**Transparency for four per cent, rather than for a hundred times the file.**

Added because a transparent background is the one gap in this app that the competitor
everybody compares it to is publicly criticised for — "missing device frames, transparent
export, and Simulator recording", written about product demos and app showcases. The first
two are now here.

Two codecs on this Mac carry an alpha channel and it is worth stating how far apart they
are. Sixty frames of 640x360, a detailed card in the middle and a fully transparent
margin around it, measured 2026-08-29:

| codec | bytes | alpha survives |
|---|---|---|
| HEVC | 130,405 | no — the transparent margin comes back opaque |
| **HEVC with Alpha** | **135,432** | **yes** |
| ProRes 422 | 8,633,497 | no |
| **ProRes 4444** | **14,563,749** | **yes** |

So transparency costs **3.9%** over ordinary HEVC, and ProRes 4444 — the codec every
article on transparent video names — is **107 times larger** for the same picture. It is
still offered, because an editor asking for ProRes is asking for ProRes, but it is not
what somebody who wants a transparent clip should be pushed towards.

**`.mov` only, and that is measured rather than assumed.** `AVAssetWriter` refuses this
codec in an MP4 container outright — `canAdd(_:)` returns false — so the file type is not
a preference here, it is the only one that works.

## Coloured text edges

The bar test that established ProRes 4444 as the only path keeping a coloured
edge was run on one M1 Pro, and the note it produced said "on this hardware" as
though that settled it. It does not: this app runs on M1 through M5 and on Intel,
Apple's media engines have gained formats with every generation, and a table
written today is wrong for somebody by next autumn. It is the same mistake the
frame-rate ladder made before it started asking the displays.

So the export panel asks the machine. `CodecSupport` encodes a picture whose
answer is known and reads back what arrives, and `CodecVerdicts` holds the answer
for the run.

### Why it is not cached

The first version keyed a `UserDefaults` entry on the chip name and the OS build.
That meant reading the chip name, which is an ambient value — which the app tier
may not do, and which the package's one audited ambient file may not be widened
for, because that file's whole-file permit rests on every member of it reading
the same clock.

Both refusals were right, and chasing them turned up that the cache was solving a
problem nobody had. The whole probe is under a second (measured at about seven
tenths for all four codecs), it runs off the main actor, and it happens once when
an editor window opens. A cache would have bought that second back and paid for
it with an invalidation key that has to be correct forever.

### Silence has two meanings, and only one of them is an answer

A `nil` verdict means no encoder, no buffer, or no frame back. "We could not ask"
and "the answer is no" are the difference between saying nothing under the codec
picker and making a false promise, so `note(for:)` returns `nil` for both the
unfinished probe and the failed one.

### The bar test itself

*Moved out of `Core/Sources/Compositing/ExportFormat.swift` 2026-08-30 — a measurement table is a document.*

**The only export that keeps a coloured edge, and that is a measured claim — remeasured
on 2026-08-25, because the first measurement was wrong in a way that changed the
story.**

Encode 8-pixel red bars on black, decode them back, and read the last red column, which
should be 255, and the worst error across the edge. With `ExportQuality.colourProperties`
on the writer — Rec.709 primaries, transfer AND matrix, said explicitly:

| | last red column | worst edge error |
| --- | --- | --- |
| H.264 High | 154 | 101 |
| HEVC Main | 154 | 101 |
| ProRes 422 | 155 | 101 |
| **ProRes 4444** | **255** | **0** |

Everything except 4444 smears the edge by a hundred levels, because everything except
4444 is 4:2:0 by the time the encoder sees it — including ProRes 422. That is the
coloured fringing on red-on-black text, on a one-pixel border, on a thin diagonal, that
everybody recognises from a screen recording, and it is the largest picture-quality
difference available here — far larger than sRGB versus Display P3, and unlike the
gamut question anybody can see it.

**What the first measurement got wrong.** It read 234 / 21 for 4444 and 145 / 110 for
the rest, and explained the 21 as "what a fully saturated red costs in 8-bit YCbCr at
all" — reasoning from the fact that neutrals round-tripped exactly. The neutrals were
a red herring: the writer had been given no colour properties, and a writer fed
untagged BGRA infers a **601 matrix** under a 709 tag. Neutrals are identical under
both matrices, which is exactly why they passed, and a saturated red is where the two
differ most. Named, the matrix costs nothing, and 4444 is exact. The 4:2:0 figures
moved by ten in the other direction for the same reason. The rule this is an
instance of: a conclusion whose stated reason is false looks settled, and this one
stood for a day.
