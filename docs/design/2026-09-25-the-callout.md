# The callout

**Decided 2026-09-25.** A text bubble with a tail, pointing at something in the recording. The
one shape on Shotbase's list that Soredemo does not have — and the only one, which is the other
half of this document.

## Highlight was already there, and is deliberately not being added

Shotbase lists "highlights" beside arrows, text, shapes and callouts. Soredemo has every
ingredient of one already, reachable from the panel today:

| what a highlight is | the control that does it |
|---|---|
| a translucent block of colour | `AnnotationShape.rectangle` with `AnnotationStyle.fillOpacity` |
| yellow | `AnnotationInk.amber` |
| over the thing, not around it | the **Fill** slider, shown for the fillable shapes |

`AnnotationStyle.fillOpacity`'s own doc already said so before any of this: *"A low fill is a
highlighter."* Adding `case highlight` would be a second name for a state the type can already
hold — the tautology register's shape, one level up: a feature that drifted onto a neighbouring
fact that is already guaranteed. **What is missing is a preset, not a case**, and a preset is a
row of its own if anybody wants it.

## Why a callout is an annotation and not a text overlay

Soredemo already draws text: `TextOverlay`, placed in OUTPUT space. That is right for a title,
and wrong for a callout, because a callout points at something:

> An annotation is anchored to the recording, not to the frame — it moves with the picture when
> the camera zooms in on what it points at.

A callout whose tail stayed put while the camera moved in on the button it was labelling would be
pointing at the wrong thing on every frame after the zoom. So it goes where the anchoring already
is, and inherits `AnnotationOverlay`'s mapping through `RenderPlan.contentX(ofNormalised:)` — the
same one the drawn cursor uses, which is what stops an arrow and a pointer disagreeing about where
a click was.

## The two points it already has

Every annotation carries a start and an end. For an arrow they are tail and head. For a callout:

- **start** — where the bubble sits
- **end** — what it points at

So the callout needs no new geometry, no new sliders for position, and the existing *From
across / From up / To across / To up* controls already say the right thing. The tail is drawn from
the bubble's edge toward `end`, which means a bubble dragged around its target keeps pointing at it.

## What is new

- `AnnotationShape.callout`, which `canBeFilled` — the bubble is a filled shape, unlike an arrow.
- `AnnotationOverlay.text` and `AnnotationItem.text`. Empty for every other shape, and stored
  rather than refused, for the reason `fillOpacity` is stored on an arrow: switching a callout to
  an arrow and back must not silently discard what somebody typed.
- `AnnotationStyle.textSizeFraction` — **a fraction of the output's shorter edge**, the rule every
  other measurement in this type follows and for its reason: the same recording is exported at
  1920, at 640 for a GIF, and at a portrait variant's size, and a point size is right in exactly
  one of them.

**The bubble is sized to the text, not the other way round.** `TextArt` already measures a line
with Core Text and both types live in `Compositing`, so the measurement is shared rather than
re-derived — a bubble sized by a guess is a bubble the text overflows in one language and rattles
around in in another.

## What is deliberately not in it

- **No multi-line layout.** One line, which is what a callout is for. Wrapping brings a width
  control, a line-height control and a hyphenation question, and none of those are this row.
- **No tail-less bubble.** That is a text overlay, which exists.
- **No pointer to a second target.** One tail.

## Open

- **Whether the bubble's corner radius should follow the text size or be its own control.** It
  follows the text size here, unchecked by anybody's eye.
- **Whether a callout should be legible over its own colour.** The text is drawn in the ink's
  contrasting partner rather than in a chosen colour, which is one fewer control and one more
  assumption.
