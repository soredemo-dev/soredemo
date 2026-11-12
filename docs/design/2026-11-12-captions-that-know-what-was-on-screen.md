# Captions that know what was on screen

**2026-11-12.** The on-device recogniser mishears exactly the words a screen recording is about —
product names, menu items, the app being demonstrated. Soredemo is the one editor that knows what
those words were: every pressed element's label and every application's name is in the observation
log. This document decides how that evidence, and the agent, correct captions without inventing
words nobody said.

## What was already known, and what was measured again

`teaching-the-recogniser-a-word.md` measured both of Apple's biasing mechanisms on macOS 26 and again
on 27: `AnalysisContext.contextualStrings` on `SpeechTranscriber` leaves the output byte-identical,
and a custom language model on `DictationTranscriber` does too. This document should have started
from it, and was first drafted without reading it; the one measurement below that is new is the
second row.

A synthesised sentence with five rare names, on macOS 27.2, with and without contextual strings
naming all five:

| Module | No context | With context |
| --- | --- | --- |
| `SpeechTranscriber` (what Soredemo uses) | Sorodimo, Cubernades, Sora demo, keynote | **identical, character for character** — the earlier finding, unchanged on 27.2 |
| `DictationTranscriber` | sora demo, Cuban needs, "press the do", Cortez; no punctuation | **Soredemo corrected** — contextual strings do reach this module; everything else as bad |

So the decoder-side biasing the research recommends — boosting a list during decoding rather than
rewriting afterwards, because rewriting invents entities that were never spoken — is still not
available from the transcriber Soredemo uses, and the module that honours it is worse at everything
else, which the earlier document had already found for its own reasons.

And the existing names list could not have fixed these either. `Transcript.correcting(terms:)`
matches by character edit distance with a tolerance of an eighth of the term's length: "sorodimo"
is two edits from "soredemo" against a tolerance of one, "cubernades" three from "kubernetes".
A recogniser's errors are errors of *hearing* — c for k, d for t — and edit distance counts them as
spelling.

## Decided

**1. Match by sound as well as by spelling.** A sound key folds what a listener confuses — c/k/q,
voiced and unvoiced pairs (b/p, d/t, g/k, v/f, z/s), vowels after the first letter — so
"Cubernades" and "Kubernetes" share a key and "Sorodimo" and "Soredemo" share another. A run matches
a term when the keys are equal **and** the spelling is within a third of the term's length, and only
for terms of five letters or more: a short word's key collides with too much English to be evidence.

**2. The observation log supplies the vocabulary, and what it supplies is proposed.** The labels of
pressed elements and the names of applications are words that were on screen while the speaker was
talking about them. A correction drawn from the person's own names list is applied, as it is today.
A correction drawn from the log is a **suggestion with its origin** — "Soredemo, the label of the
element pressed in step 3" — accepted in the Captions tab or by the agent, never silently. That is
the producer-value rule: a derived value carries where it came from, and the person's text is not
replaced by a guess.

**3. The agent corrects with evidence and within a bound.** Its caption tools read the lines (with
each line's least certain word), the names list and the log's vocabulary, and edit by line, by run
everywhere, or by adding a name. **A single edit may change at most a third of a line's words**,
and the refusal says so and names the run-everywhere tool: the research's failure mode is the
fluent rewrite, and a bound on how much one edit may change is the cheapest guard against it. Each
edit is one undo step named for the agent and its reason, like a cut.

**4. A turn that edited captions reverts as a whole, like one that cut.** Caption edits do not go
through the timeline's history, so the turn's checkpoint records the caption track before the
agent's first caption edit, and reverting restores it — provided the track is still exactly what
the agent left; if a person edited a line after, the revert says so, as it does for cuts.

## Alternatives not taken

- **Transcribe twice — `SpeechTranscriber` for the text, `DictationTranscriber` with context for the
  names — and splice.** It doubles the time of the slowest step a person waits on, and the splice
  needs word alignment between two recognisers that disagree about word boundaries. Kept as the
  next measurement if sound matching leaves names unfixed.
- **Let the agent rewrite freely.** The research's own warning, and this project's thesis: a
  correction must be able to say what it rests on.
