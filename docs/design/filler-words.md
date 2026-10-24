# Filler words: cut by a person, not detected

2026-08-29; re-checked against the macOS 27.0 SDK on 2026-10-25. *Moved here from the retired
competitor survey.*

Screen Studio 4 (October 2026) detects and removes filler words, and ScreenKite ships a filler
clean-up. Soredemo does not detect them, and the reason is a fact about the recogniser, not a
judgement.

**`SpeechTranscriber.TranscriptionOption` has exactly one case, `.etiquetteReplacements`** — in
the macOS 26 SDK and still in 27.0 (`DictationTranscriber` has `punctuation`, `emoji` and
`etiquetteReplacements`). There is no verbatim mode and no disfluency option. The recogniser is
built to return clean, readable text.

Measured against synthesised speech saying *"So um I was uh thinking about this, er, feature.
Hmm. It is, like, useful."*:

    um    ->  transcribed as "am"     a real word
    uh    ->  no token at all
    er    ->  kept
    Hmm.  ->  no token at all
    like  ->  kept

So the fillers a word list could safely match are the ones the recogniser already drops, and the
one it kept a token for came back as a legitimate English word: a dictionary would miss most of
them and put "am" on a delete list. The interesting fillers — *like*, *so*, *actually*, *right* —
are real words, and no list tells "I like this" from "it is, like, useful".

**What shipped instead: cutting by the word.** The transcript carries per-word timings; a sentence
opens into its words, any of them can be chosen and cut, and adjacent choices merge so the breath
between them goes too (`TranscriptPanel`). The person decides which word is a filler, which they
can do at a glance and no dictionary can do at all. A missed "um" costs nothing; a deleted "am" is
somebody's sentence changed without being asked.

**What would change this:** a recogniser with a verbatim mode, or a model of our own run through
Core AI (`2026-10-22-what-macos-27-makes-possible.md`) that returns disfluencies as tokens. Either
would be measured on the same sentence first.
