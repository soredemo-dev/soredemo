# A string shown verbatim

2026-09-26. Written after the fact of a measurement, before the fix was committed.

## What was seen

Launched with `-AppleLanguages (de)` beside a positive control — `Beschneiden`, `Hilfslinien` and
`Ausgabe` all drew in German — the stage-style panel read **Shadow**, **Padding**, **Corner radius**,
the aspect picker read **Landscape**, the background read **Charcoal**. `"Shadow" = "Schatten"` was
in the German table the whole time.

## Why

SwiftUI has two `Text` initialisers that take text. A string *literal* becomes a
`LocalizedStringKey` and is looked up. A `String` *value* goes to
`init<S: StringProtocol>(_ content: S)`, which draws it as given. So every label that passed
through a helper typed `String` — `slider(_ title: String, …)`, `Text(shape.displayName)`,
`Text(cond ? "a" : "b")`, `"one " + "sentence"` — was English in all ten languages, including
the ones whose keys existed. The literal scans could not see it, because they look for literals,
and the literal was one call away from the `Text`.

A census found **115** such sites.

## Alternatives

**Make `Text(String)` a compile error.** An `@available(*, unavailable)` `Text.init<S:
StringProtocol>` in the app module, with and without `@_disfavoredOverload`. Measured with a
positive control (a deliberate type error that did fail): `Text(s)` compiled clean in every form,
the compiler preferring SwiftUI's. Rejected because it does not work, not on taste.

**An exemption list of sites allowed to be verbatim.** Rejected: every site can say which case it
is in its own spelling, so a list would be a second place to keep in step with the first.

**Chosen: every non-literal display argument states its case.** `Text(verbatim:)` for text that
is already localised or is the person's own; `LocalizedStringKey(…)` for a key looked up at run
time; or a name the same file declares as `LocalizedStringKey`, `LocalizedStringResource` or
`Text`. `everyDisplayedVariableSaysWhetherItIsTranslated` enforces it with no exemptions and
carries its own controls for both directions. What it cannot see — whether a looked-up *value* is
in the tables — is `everyNameLookedUpAtRunTimeIsInEveryStringTable`, an app test over the
enumerations those values come from.

A ternary of two literals is split into `cond ? Text("a") : Text("b")` rather than wrapped, so the
existing literal scans read both branches.

## The failure note that never fired

The recorder panel showed a failure when `statusText.contains("could not")`. Every status sentence
is `String(localized:)`, so in nine languages it never matched — and in English six of the seven
damaged-file sentences did not either. The sentence's writer now says what it is:
`RecordingCoordinator.Status.report(_:)` or `.problem(_:)`. `noViewReadsAStatusSentenceToDecideWhatItMeans`
is the shape of the old mistake. Found by reading, not reproduced in a German session.

## Build provenance, found on the way to a release

`BuildProvenance.swift` is meant to be committed as `UNBUILT — …` so that a build not run through
the script cannot present a plausible identity. A stamped copy had been committed with unrelated
work in 41 of the 43 commits that touched the file, and the baseline read `5ee4041-dirty`. `build-release.sh` never stamped
at all, so a release would have carried whichever hash was committed last. Both scripts now stamp
through `scripts/build-provenance.sh` and put the placeholder back on exit;
`appProvenanceIsCommittedAsThePlaceholder` fails when a stamp is in the tree. The release script
also refuses a dirty tree unless told otherwise.

## Not done

- **The translations of the 97 new keys were written by the same agent that wrote the code**, not
  by a native speaker of each language. They are in the tables so nothing draws in English; they
  have not been reviewed.
- `Text("\(n) sentence\(n == 1 ? "" : "s")")` in the transcript panel builds its plural by hand and
  reads wrong in every language with other plural rules. A stringsdict is the fix.
- `docs/TESTING.md` still lists "no rendered-locale check" as absent. The German launch above was
  one, run by hand; it is not a gate.
