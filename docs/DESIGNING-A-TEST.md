# Designing a test

*2026-09-15. `TESTING.md` says what exists and what is missing. This says how to decide
what to write, so that a test is the answer to a question rather than a thing that was
added because more tests seemed better.*

Every technique below is a published one, cited at the end. What is not borrowed is the
worked examples: all of them are defects this project actually had, so the method can be
checked against whether it would have found them.

---

## 0. The order of the questions

A test is four decisions, and taking them in this order is most of the method.

1. **What could be wrong, and what would it cost?** — risk, § 1
2. **What are the classes of input, and where are the edges?** — partitions, § 2
3. **How would I know the answer is right?** — the oracle, § 3
4. **What size of test can answer it?** — size, § 4

Skipping (3) is the common failure. A test whose expected value was produced by running
the code is a test that pins today's behaviour, not a test that says what is correct.

---

## 1. Risk decides what gets tested, not coverage

Risk-based testing orders work by **impact × likelihood** rather than by what is easy to
reach. Coverage is a poor proxy: a line can be covered by a test that asserts nothing
about it.

For this project the impact scale is not abstract — it is what a person loses:

| | what it costs a person |
|---|---|
| **Catastrophic** | a recording that cannot be recovered: a corrupt file, a lost segment, a crash mid-record |
| **Severe** | work silently wrong: captions at the wrong times, an export missing a cut, a wrong length |
| **Annoying** | visible and recoverable: a control that does nothing, a status line in the wrong language |
| **Cosmetic** | a misaligned pixel |

Likelihood is a judgement, but two things raise it enough to act on: **code that has been
wrong before**, and **code nothing has ever executed**.

That product is why this project's testing is shaped as it is. Capture and the writers are
catastrophic-impact and get the probe; the app tier was annoying-impact and untested, which
is exactly where the last week's defects came from.

**Use it like this:** before writing a test, say which row it is in. A test in the Cosmetic
row that costs a day is a day not spent in the Catastrophic one.

---

## 2. Partitions first, then edges

### Equivalence partitioning

Divide the input space into classes whose members the code should treat *the same*, then
test one member of each. The point is not to save typing — it is that a class you cannot
name is a class you have not thought about.

**Worked example — `SubtitleFile.nanoseconds`.** The classes are: a valid `hh:mm:ss,mmm`;
a valid `mm:ss`; a fraction of 1, 2, 3 or 4 digits; a non-numeric field; a field with too
many parts; and — the one nobody wrote down — **a numerically valid field too large to
convert**. That last class existed in the input space and had no test, and it crashed the
app on opening a file. Naming the classes is what finds it.

### Boundary value analysis

Errors cluster at the edges of a partition, so test **the edge, and one either side**.

**Worked example — the same function.** The boundary is not "a big number", it is the
largest hours value whose arithmetic fits in `Int64`. The test names both sides:

```swift
#expect(SubtitleFile.nanoseconds("2562047:00:00,000") != nil)   // the last one that fits
#expect(SubtitleFile.nanoseconds("99999999:00:00,000") == nil)  // the first that does not
```

A test that only checked "a huge number is refused" would pass against a hard-coded limit
of 10 hours, which would be wrong for a real recording.

### Decision tables

When several conditions combine into an outcome, tabulate the combinations rather than
imagining them. `CaptionMeasurement.fault` is three conditions — too fast, too brief, too
long — and their ORDER is part of the behaviour: a 200 ms cue is also technically too
fast, and reporting that sends somebody to shorten a line whose real problem is that it is
on screen for a fifth of a second. A table makes the precedence visible; prose hides it.

### State transition testing

When the response to an event depends on what happened before, draw the machine and test
the transitions — **including the ones that should do nothing**.

**Worked example — `PointerSampler`.** The states are stopped / running / *stopped while a
tick is in flight*. That third state is not in anybody's mental model, which is why the
sample that arrived after `stop()` was a real defect. The transition test had to ARRANGE
it — block the reader inside the handler until `stop()` has been called — because on an
idle machine it never happens.

### Pairwise / combinatorial

When configuration explodes, test every *pair* of values rather than every combination;
most defects that depend on configuration depend on two settings, not five. Soredemo's
export space is codec × resolution × frame rate × alpha × range, which is hundreds of
combinations and about twenty pairs.

---

## 3. The oracle: how you know the answer is right

The **test oracle problem** is the hard half of testing and the half that gets skipped.
There are four honest oracles and they are not equally available.

| oracle | when it applies | example here |
|---|---|---|
| **Exact value** | the answer is a fact you can state independently | 17 characters a second is a published figure, so `widthPerSecond` has a citation, not a measurement |
| **Property / metamorphic** | you cannot compute the answer but you know a RELATION that must hold | four times the pixels must cost less than four times the time; a split then a merge returns the original text |
| **Golden / reference** | a previous output is trusted and the question is "did this change" | the render parity fixtures |
| **Differential** | two implementations must agree | `CaptionBuilder.longestLine` against `CaptionArt.fits` |

**Metamorphic relations are the most under-used and the most valuable here**, because so
much of this app produces output no one can state in advance. Nobody can say what the
1,847th frame of a composite should be — but they can say that rendering it twice gives
the same bytes, that a zoom at 1× is the identity, and that a cut removes exactly its own
duration from the output.

**The rule:** if the expected value in a test was obtained by running the code, write down
why it is right in the same commit, or the test is a snapshot of a bug.

---

## 4. Size, measured rather than argued about

Google classifies tests by **the resources they may touch**, not by what they are called —
small (one unit, no network, no filesystem, no sleep), medium (several units, localhost),
large (the real thing). The value is that "unit test" is an opinion and "does not touch the
filesystem" is a fact.

Soredemo's existing levels map onto it, and the mapping tells you where a test belongs:

| size | may touch | here |
|---|---|---|
| **small** | memory only | L0 static scans (101) + L1 pure tier (1,028) — the floor |
| **medium** | files, a GPU, real timing | L2 `CaptureTests` (250) + `CompositingTests` (351) |
| **large** | a display, a real recording, the app itself | L3 the probe (473 checks); L4 UI, which does not exist yet |

Counted 2026-09-15 from `@Test` declarations: 1,731 in the package, plus 13 in the app
target. The app tier is 15,469 lines behind 13 tests, and that ratio is the finding.

**The rule that decides the level is what the test is allowed to be wrong about.** A small
test may not be wrong about arithmetic; a large test may be wrong about timing and must
therefore not assert on it.

**Keep the shape deliberate.** A suite that is all small tests passes while the app does not
launch. A suite that is all large tests takes an hour and tells you something failed.

---

## 5. Writing the test itself

From Google's *Software Engineering at Google*, chapter 12 — the rules that keep a test
from becoming maintenance:

* **Test behaviours, not methods.** One test per thing the system guarantees. A name with
  "and" in it is two tests.
* **Name the behaviour and the outcome.** `aTickAlreadyRunningWhenStopIsCalledIsDropped`
  reads as a sentence in a failure report; `testSampler3` does not.
* **Given / when / then**, visibly — setup, the one action, the assertion.
* **State, not interactions.** Assert what the system ends up holding, not which methods
  were called. Interaction tests break on harmless refactors and pass on real breakage.
* **DAMP over DRY.** Duplication in tests is cheaper than indirection. A helper that hides
  the value under test makes the failure unreadable.
* **No logic in tests.** No loops, no conditionals. If a test needs a test, start again.
* **The failure message carries the numbers.** Every budget in this repo prints what it
  measured beside what it expected, because the next reader is deciding whether the budget
  is wrong.

Swift Testing's `@Test(arguments:)` is the right tool once the same test exists three
times with different inputs — and the diagnostic names the argument that failed, which a
loop inside one test does not.

---

## 6. When NOT to write a test

* **The compiler can enforce it.** A refusal that is a named enum case does not need a test
  that it is not `nil`.
* **A static scan can enforce it across the whole tree.** One scan that says *no app source
  names a CoreGraphics type* is worth more than fifty tests that each check one file — this
  repo has 74 such tests and they have found more real defects this month than any other
  level.
* **The assertion is the implementation, restated.** A test that re-computes the formula
  and compares passes whatever the formula is.
* **It would pin a decision nobody has made.** A budget invented without measuring is a
  number that will be edited the first time it fails, which teaches everyone to edit
  budgets.

---

## 7. The loop that keeps it honest

1. A defect escapes to a person.
2. Write the test that **fails** because of it — before fixing anything.
3. Fix it.
4. Ask which of § 2's techniques would have found it *without* the escape, and whether the
   same blind spot exists elsewhere.

Step 4 is where the leverage is. The caption list's state was not installed on a view; the
same question — *what else is handed to a `List` as a value?* — is a scan, and a scan
covers every future instance. Four of this month's defects were found that way: the escape
was one, the scan found the rest.

---

## Sources

* [Google Testing Blog: Test Sizes](https://testing.googleblog.com/2010/12/test-sizes.html)
* [Software Engineering at Google, ch. 12 — Unit Testing](https://abseil.io/resources/swe-book/html/ch12.html)
* [Software Engineering at Google, ch. 14 — Larger Testing](https://abseil.io/resources/swe-book/html/ch14.html)
* [Equivalence partitioning and boundary value analysis](https://www.sdetunicorns.com/blog/equivalence-partitioning-and-boundary-value-analysis)
* [Test design techniques: BVA, state transition and more](https://testrigor.com/blog/test-design-techniques-bva-state-transition-and-more/)
* [Risk-based testing](https://www.panaya.com/blog/testing/risk-based-testing-save-time-without-sacrificing-quality/)
* [Metamorphic testing](https://en.wikipedia.org/wiki/Metamorphic_testing)
* [A brief survey on oracle-based test adequacy metrics](https://arxiv.org/pdf/2212.06118)
* [Swift Testing — parameterised tests](https://developer.apple.com/xcode/swift-testing)
