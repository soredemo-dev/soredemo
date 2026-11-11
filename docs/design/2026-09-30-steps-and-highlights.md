# Step numbers and a highlighter

2026-09-30. Item 3 of the list approved after reading a utility suite (GPL-3.0; ideas only —
its screenshot editor has a "Number" tool and a "Highlighter"). The two things a tutorial reaches
for that `AnnotationShape` did not have: "this is step 2", and "read this line".

## Both are still a drag from one point to another

`AnnotationShape`'s header makes that the whole interaction model, and neither needs a third
point. A **step** is a badge inscribed in the box the drag drew; a **highlight** is that box,
filled. Neither is a freehand stroke — the header's refusal of a pen still stands, for its reason.

## The number is derived, and derived from time

**A step's number is its place among the steps, in the order they appear** — sorted by start
time, then by id so two at one instant are still ordered. Asked of the track
(`AnnotationTrack.stepNumber(of:)`) at render time, not stored on the item.

| Alternative | Why not |
| --- | --- |
| the number a person types | a list of steps is renumbered by hand every time one is inserted or cut, which is the chore a counter tool exists to remove |
| stored at creation, `nextStep += 1` | deleting step 2 leaves "1, 3" |
| ordered by id (creation order) | adding a forgotten step between two others numbers it last |

A split by a cut keeps the item's id (`retimed(through:)`), so both halves carry one number, as
both halves of an arrow are one arrow.

**Producer-value rule:** there is no authored number for a derived one to replace — the number is
not a value a person sets, and there is no control for it. If one is ever wanted, it is an
override that wins, and this section is where it gets written down.

## Drawing

**Step:** a filled circle of the ink colour, the largest that fits the box, with the number in its
centre in white or black, whichever contrasts with the ink (the WCAG relative-luminance rule
`Palette` already uses). The text size follows the circle, not `textSizeFraction`: a number
that overflows its own badge is not a style choice.

**Highlight:** the box filled with the ink at a fixed 35 % over what is there, no outline. A
marker that hides the text it marks is a redaction, and `RedactionTrack` exists for that. The
`fillOpacity` slider is not used — highlighting at 100 % is not a highlight.

## Verification

Behavioural, through the real renderer (`CoreImageFrameRenderer`), not by inspecting paths:
a highlight over a known colour leaves that colour visibly through it; a step badge's centre is
not the ink colour (the number is drawn) while a point inside the circle away from the digit is.
Numbering by unit tests over `AnnotationTrack`, with the insertion order different from the time
order so "by id" and "by time" disagree.

**Found by mutation:** the first version of the badge test checked the corner of the drag's box,
which is outside the circle — and outside the circle's own square too. Drawing the badge as that
square passed. The test now also checks a point inside the square and outside the circle, which is
the point that tells the two apart. The fixture's identity case, one level down: a check at a point
two shapes agree about cannot choose between them.
