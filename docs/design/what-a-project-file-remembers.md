# What a project file remembers

*Code: `Core/Sources/Project/EditState.swift`, `ProjectSnapshot.swift`.*

## Only authored values

Not the framing plan, not the derived zoom blocks, not the pointer track — those
are read from the observation log every time and would be a second, staler copy of
a fact the recording already carries. What a person cannot get back by
re-deriving is what has to be saved: the cuts, the levels, the corrections to the
automatic zooms, the look, the shape.

That split is the producer-value rule made into a file format. A saved project
storing derived values would silently keep an old answer when the derivation
improved; one storing only authored values re-derives on open and applies the same
corrections on top.

### The one exception, deliberately

The caption track is derived and is stored anyway. Deriving is normally cheap and
a stored derived value goes stale when the derivation improves — but transcription
is neither cheap nor stable: it costs a minute of compute and a
several-hundred-megabyte model download, and two model versions do not agree word
for word. Re-deriving on open would apply a person's text corrections to text that
had changed underneath them. So the corrected text is what is saved, corrections
included, and there is nothing left to reconcile.

## Every field is absence-tolerant

A project written before a field existed has no such key and opens with that part
unedited. That is the one behaviour letting the format grow without a migration per
field, and it means **absent and off are the same thing**: a project made before a
feature existed and a project by somebody who never asked for it decode alike.

`ProjectSnapshot.schemaVersion` still moves when an existing key changes
*meaning* — that is what it is for.

## Why several fields are `Data` rather than their own types

`ZoomAdjustment` lives in `Framing`, `StageStyle` in `Render`, `AspectVariant` in
`Variants`, `NoiseReduction.Settings` in `Overlays`. `Project` depends on none of
them and must not: the architecture plugin enforces the dependency graph, and
making the file format depend on every tier that has something to save would
invert it — a persisted-format change would then require rebuilding the render
tier. The document's job is to remember what a person chose, not to know how noise
is removed.

So the field holds encoded bytes and each tier's own type does the decoding. The
format is still one file and still one version; what changes is which tier may
read which part of it. `encoding(_:)` and `decoding(_:as:)` are the seam, so no
caller writes an encoder by hand and gets different bytes.
