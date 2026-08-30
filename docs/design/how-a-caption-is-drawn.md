# How a caption is drawn

*Written 2026-08-30. Code: `Core/Sources/Render/CaptionStyle.swift`,
`TextOverlay.swift`, `Core/Sources/Compositing/TextArt.swift`, `CaptionArt.swift`.*

Asked for the colour, the size, the place and a font upload. The size and the
vertical place were sliders already. Everything else turned out to be a story
about a conversion, a Core Text default, and one seam.

## The six that were literals

`CaptionStyle.asTextStyle` converts a caption into the same `TextOverlayStyle` the
text overlays use. It used to pass six constants:

```swift
x: 0.5,  anchor: .center,  isBold: false,
plateRed: 0, plateGreen: 0, plateBlue: 0,
shadowOpacity: 0, shadowBlurFraction: 0
```

Every one of them was a capability `TextOverlayStyle` could already draw. A
caption was always centred, always at mid-frame, never bold, always on a black
plate and never had a shadow — not because anything decided that, but because the
conversion said so. They are fields now.

## The colour never reached a glyph

`TextArt` set the context's fill colour and drew the line, expecting the glyphs to
take it. Core Text does not work that way: an attributed string carrying neither
`kCTForegroundColorAttributeName` nor `kCTForegroundColorFromContextAttributeName`
draws **black**, whatever the context says.

The colour attribute was attached only when a word was being highlighted. So
`TextOverlayStyle.red`, `.green` and `.blue` had never reached a glyph on any
caption without word highlighting — every one of them was black, on a plate that
defaults to black.

Measured by asking for red on a white ground and getting black.

**What let it ship is the shape of the tests.** They asked whether there was ink
near the bottom of the frame, and there was. Black ink is ink. The test that
replaces the gap asks the question none of them did: is the colour asked for the
colour drawn, and do two different colours draw differently. A renderer ignoring
colour passes every "is there ink" check ever written and fails that one.

## The outline, and why it is an attribute

An outline is the half of legibility that does not cover the picture. A plate is a
rectangle across the frame; a shadow softens an edge; an outline follows the
letterforms, so a caption crossing a light region and a dark one in the same line
stays readable with nothing over the footage.

Drawn with Core Text's own `strokeWidth` rather than a second stroked pass.
Stroking separately means laying the same text out twice and lining the two up,
which is the drift `line`'s dimmed-run comment already refuses: two layouts of one
string are not guaranteed to agree at every size.

- **Negative**, because negative means fill *and* stroke; positive leaves hollow
  letters, which is a different effect.
- **A percentage of the type size**, which is the fraction everything in this file
  is already expressed in.
- **Capped at 0.14.** The stroke is centred on the glyph outline, so half of it
  eats into the letterform and past that the type visibly thins. Drawing it
  outside means extracting each glyph's path — the second layout again.

## A project's own font

The file, not an installed name, and copied into the package beside the
backgrounds and the music. `TextArt.font` resolves it and falls back to the system
face when it will not load.

The old comment refused named fonts for a good reason: a name that is not
installed falls back silently to something of a different width, and the text then
overflows on exactly the machines that lack the font. A file inside the project
does not have that failure — it travels with the recording.

### The seam is the only reason a fallback is safe

`CaptionBuilder` decides its line breaks through `CaptionArt.width`, which calls
`TextArt.width`, which calls the same `font(pointSize:bold:filename:)` the drawing
calls. A font that fails to load therefore changes what is measured and what is
drawn by exactly the same amount, and nothing overflows.

**That seam was broken by this same piece of work, in its first commit.**
`CaptionArt.width` passed `bold: false` and no font at all. Adding a bold toggle
meant line breaking measured a lighter, narrower face than the one drawn, so a
bold caption could overflow the limit it was broken to fit. Found while threading
the font through the same call, and pinned by a test: bold must measure wider than
regular.

Measurement and drawing must never grow two ways of choosing a font.

### Two smaller decisions

The font cache is keyed on filename, size and weight, and is cleared when the
project changes. Two projects may each have a `Brand.ttf` that is not the same
file, and a cache outliving its base URL draws the first project's font in the
second's captions — which reads as a rendering bug rather than a stale cache.

`changing(fontFilename:)` takes a double optional so "set it to nothing" and
"leave it alone" are different asks. Choosing the system font is a decision, not
the absence of one — `MusicBed.changing(filename:)`'s shape, for its reason.

## Compatibility, twice

Both styles had a synthesised `Codable`, and a synthesised decode **requires every
key**. Adding a field to either would have stopped every existing project from
opening — silently, at the moment somebody double-clicked it.

Both now have a hand-written `init(from:)` reading each field with
`decodeIfPresent` and falling back to what the field meant before it existed. That
closes a second hole in the same place: the synthesised decode also assigned
straight past the clamping the public initialisers do, so a corrupt file could put
a caption a thousand frames tall, or a stroke wider than the type, into the
renderer.

## What is still not offered

Fade in and out, per-word highlight backgrounds, and the preset "styles" other
editors ship by the dozen. The first two are animation rather than style; the
third is a library, and a library of presets over a style system that could not
set a colour would have been a catalogue of black text.
