# Teaching the recogniser a word

*2026-08-30. A feature every surveyed recorder ships, measured twice on this platform,
and refused on the evidence — with a weaker thing built in its place.*

A demo says a product's name forty times. The recogniser has never heard it, so every
caption spells it wrong, and fixing that by hand is the reason people stop using
automatic captions. One surveyed recorder ships a "remembered terms" list for exactly
this: names, spellings, domains, capitalisation, fed to caption generation.

Apple publishes two mechanisms for it. **Neither changes what comes back.**

## The test

`say -v Samantha -o hint.aiff "Soredemo records the screen. Open Soredemo and press
record."` — a synthesised clip whose audio genuinely says *sore-demo*. The hint spells
the same phonemes as one word, which is the classic case contextual biasing is for: the
recogniser is not being asked to hear something that is not there, only to prefer one
segmentation of what is.

Untouched, `SpeechTranscriber` returns:

> Sorodimo records the screen. Open Sorodemo and press record.

## One: `AnalysisContext.contextualStrings`

```swift
let context = AnalysisContext()
context.contextualStrings[.general] = ["Soredemo"]
try await analyzer.setContext(context)
```

The value is accepted and reads back from `analyzer.context` unchanged, so it is not
being dropped. Five spellings were tried — `Soredemo`, `soredemo`, `SOREDEMO`,
`Sore demo`, `Soredemo.` — and all five produced **byte-identical output** to the run
with no context at all.

## Two: a custom language model

`SFCustomLanguageModelData` with `PhraseCount`s for the bare term and for two phrases
containing it, exported (985 bytes) and prepared into a **6.5 MB** model, then handed to
`DictationTranscriber` as `ContentHint.customizedLanguage(modelConfiguration:)`.

macOS 26 added a `weight` to `SFSpeechLanguageModel.Configuration` — "the relative
weight of the language model customization", 0…1. Swept at `nil`, `0.5` and `1.0`.

All three, and the run with no model, produced **byte-identical output**:

> Sora demo records the screen open sora demo and press record

Two things worth recording from that line. `DictationTranscriber` *does* give word times
— 11 runs carried an `audioTimeRange`, so switching modules would not have cost the
caption track its timings. And it returns markedly worse text: no punctuation and no
capitalisation, where `SpeechTranscriber` on the same audio produced sentences. So the
module swap would have been a real loss even if the biasing had worked.

`prepareCustomLanguageModel(for:clientIdentifier:configuration:)` is also deprecated in
macOS 26, which is a second reason not to build on it.

## Re-measured on macOS 27, and the answer has not changed

*2026-09-15, the same synthesised clip, the same four spellings.*

```
no context      : Sorodimo records the screen. Open Sorodemo and press record.
Soredemo        : IDENTICAL
soredemo        : IDENTICAL
SOREDEMO        : IDENTICAL
Sore demo       : IDENTICAL
```

Byte-identical, again. **This note is not stale; it is still true**, and the only way to know
which of those two it was is to run the measurement again — "Apple fixed it" and "Apple did
not" look exactly the same in source code. The method is written down above precisely so that
anyone can re-run it against the next release in ten minutes.

## Why the surveyed recorder can do this and this app cannot

It downloads a Whisper-class model of its own — about 440 MB, offered in the interface
as a one-time download — and for that family a vocabulary is a *prompt prefix*: the terms
are literally prepended to the decoder's context, and the decoder is free to emit them.
Apple's on-device transcriber has no such seam exposed. The difference is architectural,
not a setting somebody forgot to turn on.

Shipping the 440 MB model is not obviously wrong, and it is not this note's decision to
make. It is a different app: a model download, a storage question, a second transcription
path to keep working, and a reason for the on-device one to still exist.

## What was built instead, and what it does not claim

`Transcript.correcting(terms:)` — a **post-recognition spelling pass**. The person's own
list of terms is matched against what the recogniser returned, across word boundaries,
and close matches are rewritten to the term's spelling.

It fixes the text. **It cannot make the recogniser hear the word**, and the interface says
so rather than letting somebody infer that captions got more accurate. Word timings
survive, because nothing is re-recognised — a rewritten run keeps the span of the runs it
replaced, which is also why a correction can be applied after cuts.

The limits are the honest part:

* It only ever rewrites toward a term somebody typed. Nothing is corrected on its own.
* Matching is conservative, because the failure mode is worse than the problem: a pass
  that rewrites "sore" to a brand name every time somebody says it hurts more than a
  misspelling nobody minded.
* A term the recogniser mangles beyond recognition — different phonemes, not a different
  segmentation — stays mangled. It is a spelling pass, not a second opinion.
