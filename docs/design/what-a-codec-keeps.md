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
