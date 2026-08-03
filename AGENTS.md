# Working agreement — Soredemo

Read this before doing anything. Then `docs/PRODUCT.md`, `docs/FEATURES.md`,
`docs/ARCHITECTURE.md`, and `ROADMAP.md`.

macOS 26 · Apple Silicon · Swift 6.4 strict concurrency · SwiftUI · SDK 27

---

## What this project is

**You ship a feature; Soredemo carries it to published.** It watches your GitHub releases, proposes a
demo when something user-visible shipped, helps you record it, treats the recording as **evidence**,
and derives everything else from it — the framing, the story beats, the per-platform variants, and the
launch outputs. Then, behind a human approval gate, it publishes.

Every derived value carries its origin and a review state. **Automation proposes; the person decides.**
That is the product thesis and it is also the architecture.

### The publishing rule

> **Soredemo never posts anything without explicit, per-post human approval.** No auto-publish setting,
> no "approve all", no CI bypass. An agent may prepare a post; only a person may send one.
> `publish_post` returns "requires human approval" every time an agent calls it, and `soredemo publish`
> refuses to run non-interactively.

This is the thesis at the one boundary where getting it wrong is public and permanent. It is also the
rule most likely to be eroded by a well-meaning convenience feature. Do not add one.

---

## Method: a skill chain

This project uses the [a skill chain](https://github.com/a skill chain) skill chain:

1. **brainstorming** — before any code. Questions, alternatives, design presented in readable chunks.
2. **using-git-worktrees** — isolated branch, clean test baseline.
3. **writing-plans** — 2–5 minute tasks with exact file paths and verification steps.
4. **subagent-driven-development** — fresh subagent per task, two-stage review.
5. **test-driven-development** — RED-GREEN-REFACTOR. Code written before its test gets deleted.
6. **requesting-code-review** — between tasks. Critical issues block progress.
7. **finishing-a-development-branch** — verify, merge, clean up.

Design documents from `brainstorming` land in `docs/design/`. They are the durable record of *why*.

The SDD ledger that drives `subagent-driven-development` lives under `a skill chain/`, which
`.gitignore` excludes — it does not survive a clone. **At the end of a phase, promote what later
phases need into `docs/design/<date>-phase-N-carried-forward.md`** before the branch merges.
Phase 1's is the worked example: code with no caller yet, rules held by convention rather than
enforcement, and verification that runs only when a person runs it.

That file has three required sections and a fourth item that is not a section:

1. **Code with no caller yet**, each with its intended first caller.
2. **Rules held by convention rather than enforcement.**
3. **Defaults this phase depended on and never decided.** Not the same as 2. A rule stated and
   unenforced is a gap someone chose to leave; a default nobody discussed is a decision that never
   happened, and the two read completely differently to whoever inherits them. Phase 1's example:
   `ENABLE_APP_SANDBOX = YES` with `files.user-selected.read-only` — Xcode's default for a new
   macOS app target, which quietly forecloses `ax-observation` and cannot save a document, and
   which no document in the repository had ever mentioned.
4. **Propose the next merge point in the same pass.** Phase 1 merged four times and then stopped
   for eight tasks, because a mid-task "not yet" was never given a condition for becoming "now".
   Every task that ends green with a completed review is a legitimate merge point; name the next
   one rather than leaving `main` to drift behind whatever is being worked on.

---

## Rules

**The completion rule.** A row is not complete while the behaviour its name claims is not observable in
the product. A pure function with no caller does not satisfy a row that claims a product behaviour. If
the caller belongs to a different row, rename the row to what it actually delivers.

**The producer-value rule.** Every generated value carries an origin. An authored override is never
silently replaced by a derived one. Test form: supply a value the producer could not have derived, and
assert the supplied value wins. Write it for every producer.

**Cache invalidation pairing.** Every cache-hit test is paired with an invalidation test. A cache never
proven to invalidate is a correctness bug waiting for a demo.

**Two derivations that disagree must say so.** If the story beats say six steps happened and the camera
produced one move, that is a diagnostic, not silence.

**Read the implementation, not the summary.** Documentation summaries are not a substitute for reading
the code — yours or Apple's.

**When a document is wrong, say so.** If the code disagrees with the design, the code usually wins and
the document gets fixed in the same commit. Do not silently work around a document you think is wrong.

**A correct conclusion does not excuse its reasoning.** Verify the justification as carefully as the
result — including the justification for options you rejected. A decision whose stated reason is
false looks settled, and an audit whose stated reason is false looks discharged; both are worse than
having none, because nothing prompts anyone to re-examine a conclusion that happens to be right.

This has surfaced twice already in Phase 1. `.macOS(.v27)` was retained for "the newer manifest API
surface" long after the only real reason for it had gone, and the stale reason made it look
deliberate. An audit of the checker's string handling concluded the code was safe "because the
force-close only triggers on source that does not compile" — the conclusion held, the reason did
not, and disproving the reason exposed a defect the audit had passed over. Neither was found by
re-reading the conclusion. Both were found by testing the sentence underneath it.

**Every fixture set needs a non-identity value for every transform applied to it.** A fixture
chosen at a transform's identity element cannot test that transform, and the test passes for a
reason unrelated to the code being right. This has happened three times in Phase 1, each time with
a different operation:

| Fixture | Identity of | Consequence |
| --- | --- | --- |
| a vertically centred rect | the Y-flip | the centre-point test passes whether the flip is right or inverted |
| a display at origin `(0,0)` | translation | a mutation making routing ignore the global origin survived |
| `scale: 1` | scaling | 97 green tests while pixels and points were being compared directly |

So: alongside the centred rect, an off-centre one. Alongside `(0,0)`, a non-zero origin. Alongside
`scale: 1`, `scale: 2`.

**Never `git add -A` while an agent is working in the same directory.** This project runs
subagents in the main checkout with no worktree isolation, so `-A` stages whatever they have
written but not yet committed. It has already happened once: a documentation commit silently
absorbed two source files from a task still in flight, and the commit message described only half
of what it contained. Stage explicit paths. The damage is not corruption — the files were correct —
it is that the history stops describing what happened, which is the one thing history is for.

**A measurement has no safe default.** Three times in this project a measurement returned a
default instead of an error, and each time the default was **inside the valid range of the answer**,
so nothing looked wrong:

| Construct | Failure value | Why it is invisible |
| --- | --- | --- |
| `sort -u \| wc -l` on empty input | `1` | 1 is a legal line count |
| a `grep` filter matching nothing | silence | silence is a legal "no violations" |
| `m >= cg ? m - cg : 0` on mismatched units | `0` | 0 is a legal latency |

The last one is the sharpest, because it happened inside a probe written specifically to settle a
units question — the guard's false branch produced a plausible measurement rather than a complaint.

The constructive form of the rule is not "pick a better default". It is that **failure must land
outside the value range**: `precondition`, `nil`, or `throw`. A measurement that can fail into a
legal answer is not a measurement.

**A measurement that counts something must first assert it counted anything.** `sort -u | wc -l`
returns `1` for empty input, so a probe reporting "1 distinct result" reports the same number
whether the values agreed or the binary failed to build. This is the vacuous pass, one level up
from the code: `Tests/DeterminismTests` carries `#require(!objectFiles.isEmpty, "…would pass
vacuously")` for exactly this reason, and the shell probe that verified it did not. Assert non-empty
input before reporting an aggregate — a wrong API call surfaces on its own, a false green does not.

The same failure has a quieter twin: **a filter that drops rows reports a smaller number, not an
error.** `swift test` writes `1 test` for a one-test target and `N tests` for the rest, so a grep
for `tests` undercounted this suite by three and the wrong figure reached a committed progress
table and a task brief before an implementer measured it independently and disagreed. Neither half
of the pattern announces itself: `wc -l` returns 1 for nothing, and `grep` returns silence for a
row it does not match. Where a number is going into a document, derive it twice.

**Name the artefact, not the concept.** "The app binary" is not a file.
`Soredemo.app/Contents/MacOS/Soredemo` is a 59 KB launcher stub in a Debug build; the app's code is
in `Soredemo.debug.dylib`. `nm` on the stub reports zero `Geometry` symbols before the app's first
`import SoredemoCore` and zero after — the check answers identically whether or not the work
happened. On the dylib the count moves 1191 → 1197, because SwiftPM's static product is force-loaded
whole and the symbols were there when nothing imported them. Both readings are facts about a file;
neither is the fact that was claimed.

This is the "which build" rule one level down: having picked the right tool and the right state, you
can still measure the wrong file. Before quoting a number, say which path produced it — **and which
flags**. The counts above are plain `nm`. The same dylib under `nm -a`, which includes debug
symbols, gives `Minting` 20, `CGGeometryBridge` 22, `ProjectDocument` 234 and a total of 16662
against 5192. Both are correct measurements of different things, and this document and Task 18's
report each quoted one without naming it — the rule unmet by the entry that introduces it.

**The instrument can have state.** Every entry above is about a claim never compared to the thing.
This is the case where you did compare them and the comparison still lied, because the API answered
from its own cache instead of from the world. `URL.resourceValues(forKeys: [.fileResourceIdentifier
Key])`, read twice through the same `URL` binding, returns the identical value across a
`replaceItemAt` that genuinely changed the file's inode — `NSURL` caches resource values per
instance. `FileManager.attributesOfItem(atPath:)[.systemFileNumber]` `stat()`s each call and sees
`130435918 → 130435919` for the same two states.

The failure direction matters: the cached read made a **correct** implementation look broken. A
measurement that reads stale is not the safe kind of wrong. When an assertion is the only thing
standing between you and an unverified mechanism, prove it fails against the mutation *and* passes
against the real code, in a throwaway probe, before you keep it.

**A validating initialiser plus synthesised `Codable` is an invariant that holds everywhere except
the one path carrying untrusted input.** Swift's synthesised `init(from:)` assigns stored properties
directly. It never calls your `init`, so every `precondition` and every `throw` you wrote to define
the type's invariant is skipped exactly when a value arrives from disk.

Measured across this repository — **eight public types have a validating initialiser and no explicit
`init(from:)`**:

```
NormalizedPoint  NormalizedSize  NormalizedFrame  PixelRect
PointRect        Authorship      HostInstant      TimeRange
```

It was **ten** when this paragraph was written. `DisplayGeometry` and `HostRange` — the two of the ten
reachable from `ProjectSnapshot` — were closed in Task 4.5, and the number moved without this sentence
moving with it. Which is the whole reason the count lives in `scripts/scan-decode-validation.py`: run
it. Since Task 11.5 the eight are also enumerated in
`ArchitectureChecker.decodeValidationExemptTypes`, where **architecture rule 8 fails the build on a
ninth**, and a package test fails if one of the eight is closed without its line being deleted. The
list is the remaining work, in a form that cannot rot.

**Two of the ten are on a live decode path. The other eight are not, and an earlier version of this
paragraph said otherwise.** Traced structurally from `ProjectSnapshot` through stored properties and
enum payloads rather than from memory:

| reachable from `ProjectSnapshot` | not reachable today |
| --- | --- |
| `DisplayGeometry` (via `GeometryRegistry`), `HostRange` (via `SegmentTable` → `MasterSegment`) | `NormalizedPoint`, `NormalizedSize`, `NormalizedFrame`, `PixelRect`, `PointRect`, `Authorship`, `HostInstant`, `TimeRange` |

The claim that was here — that `ProjectSnapshot` carries `Derived` → `NormalizedFrame`, `Evidence`,
`Authorship` and `TimeRange` — was false, and `ROADMAP.md`'s `derivation-graph` row already said so
in plain words: *"no graph is persisted or read."* An assertion about structure, written from
impression, contradicting a fact already recorded two files away.

For the two that are reachable the exposure is real and the input is untrusted by design: a
`.soredemo` package is a shareable document, and `agentic-threat-model` assumes foreign content is
attacker-influenced. For the other eight there is no decode path yet, so closing them now would be
designing error handling with no caller — the thing that left `project-format` at ◐.

**This count was got wrong three times by hand, each time differently**, which is why it now lives
in `scripts/scan-decode-validation.py` and not in a sentence. The three ways: scanning for `Codable`
on the declaration line, missing every type that conforms in an extension; asserting reachability
instead of tracing it; and `break`ing after the first type in each file, so `Normalized.swift`'s
three and `Derivation.swift`'s several counted as one.

Each error survived because its result looked plausible. Run the script.

**The same thing happened to the test count, after this rule was already written down.** Reported as
226 against a real 229 in Phase 1, and as 336 against a real 338 in Phase 2 — both times from a
`grep` with a hardcoded plural (`"Test run with [0-9]+ tests"`), which silently drops every
single-test target, and this package has two. The rule did not fail because anyone forgot it. It
failed because **there was nothing to run**: a rule that says a number should be executable, with no
executable beside it, is a sentence. `scripts/count-tests.sh` is the executable, and it prints the
per-target breakdown as well as the total so the total can be checked rather than trusted. It exits
non-zero without printing a number when `swift test` fails, because a `0` and a stale count both
read as answers.

So the rule has a second half now: **when a number in a report turns out to be wrong, the fix is a
file, not a correction.** The third time a count is wrong is not new information about that count —
it is information about the method.

**And the eight closed ones show why the ten are open.** Phase 1 hand-wrote `Codable` for
`GeometryRegistry`, `ContentDigest`, `ProducerID`, `GateCode`, `Evidence` and `NodeID` — the types
whose *bytes are digested or whose identity must be checked*. That is a criterion about the
encoding. "Does the initialiser validate" is a different criterion, and the ten sit in the gap
between them. They are not ten separate oversights; they are one criterion applied consistently and
a second one never asked.

The `precondition` cases are the more deceptive half: the type has written down that a state is
impossible, and then does not check it on the only path where that state arrives from outside.

And the failure is not a crash. **It is an answer** — a plausible number, inside the legal range,
for a question the invariant says cannot arise.

**Invert every hand-written check list.** A list of *what we check* rots by **omission**, and an
omission is silent. A list of *what we skip* rots by **inclusion**, and an inclusion is loud. Write
the second.

Two live instances in this repository, both currently the wrong way round:

- **The cross-boundary probe compiles four of the app's eight files**, from a hand-written include
  list. A file added to the app is simply absent from the probe, and nothing says so — that is how
  a closure-isolation defect in `SoredemoApp.swift` reached `xcodebuild` unchallenged. Inverted:
  compile `Soredemo/**/*.swift` and enumerate the **exclusions**, each with a reason. A new file
  then either compiles or fails loudly.
- **The determinism rule's banned-symbol list went stale three times in one session** —
  `mach_continuous_time`, `NSUUID`, `clock` — and every time the missing symbol was the *sibling of
  one already banned*. Adding three more names does not change that shape; see the next entry for
  what does.

The general form: when a check enumerates what it looks at, the failure mode is a thing nobody
listed. When it enumerates what it ignores, the failure mode is a thing somebody has to write down.
Only the second one announces itself.

**Every output a human is asked to read starts with an identity block.** Three things have gone
wrong in this project's manual verification, and all three were the same omission wearing different
clothes:

| The wrong answer | The subject nobody stated |
| --- | --- |
| four permissions reported granted, for the terminal | **which process** |
| code passed the probe and failed `xcodebuild` | **which language rules** |
| a fix about to be checked against a three-hour-old build | **which build** |

The third is the meanest, because the check *works* — it just answers about a binary nobody meant.
`open` launches whatever sits at a path, and a rebuild landing in different DerivedData leaves the
old one there, silently. An expectation of the form *"if X, the fix did not land"* is then satisfied
by a stale binary, and the resulting diagnosis is confident and entirely wrong about code that is
fine.

So: build time, commit, bundle identifier, path — printed above the values, in every
`AWAITING_HUMAN` output, from one shared helper. **A commit line that does not match what was just
pushed is caught on sight**, with nobody needing to remember whether they rebuilt.

The commit must be injected at build time rather than read by running `git` at launch, or it reports
the checkout's current state instead of the binary's provenance — the same error one level down.

Manual verification is the most expensive and least repeatable kind this project has. It is the last
place that should leave its subject implicit.

**A verification that ran before the last edit did not verify it.** The probe's isolation flags were
added, the probe was run, 26 of 26 passed. Then an explanatory comment was added to the same file and
the result committed without re-running. The comment sat inside a backslash-continued `xcrun swiftc`
invocation, and bash treats `#` after a continuation as commenting out the rest of the *logical*
line:

```
$ echo A \
    # a comment
    B \
    C
+ echo A          <- the continuation is gone
+ B C             <- the remainder is executed as a command
```

So the committed script ran `xcrun swiftc` with **zero arguments**. The build failed with `no input
files` and `set -e` stopped it before anything else ran. Every check the commit message claimed
still passed had passed before the edit that broke them.

The ordering is the whole failure: verify, then edit, then commit is three steps in the wrong order,
and it feels identical to the right one. **The green light belongs to the bytes you commit**, not to
a state that existed a minute earlier — so the last thing before staging is the run, not the polish.

Related and worth knowing on its own: a comment cannot live inside a line continuation in bash. Put
it above the command.

**The probe is not the app, and it differs in more ways each time someone looks.** Three found so
far, and they are not variations of one thing:

| Layer | How the probe differs | What it cost |
| --- | --- | --- |
| TCC identity | bare `swiftc` executable, no bundle identity, so TCC attributes it to the responsible process up the chain | reported four permissions granted for the terminal, as though for the app |
| responsibility attribution | `Bundle.main.bundleIdentifier` reads `Info.plist`, which is the binary's claim about itself rather than TCC's attribution | a *correct-looking* subject block over misattributed values |
| **compile-time language semantics** | the app builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the probe's `swiftc` line had neither that nor `SWIFT_APPROACHABLE_CONCURRENCY` | code passed the probe and failed `xcodebuild`, because unannotated declarations were nonisolated in one and MainActor-isolated in the other |
| **coverage** | the probe's source list is hand-written and names **four of the app's eight files** | a closure's isolation defect lived in `SoredemoApp.swift`, which the probe does not compile at all |

The first two are about the environment at run time; the third is about **what the language means**
at compile time. The fourth is different again, and it is why fixing the third did not prevent the
next one: aligning compiler flags only helps for files the probe actually compiles, and **half the
app is not in its list**. `xcodebuild` is the only thing that sees the other half, and it runs less
often.

That list is hand-maintained, so it goes stale exactly the way the banned-symbol enumeration did —
a file added to the app is not added to it, and nothing says so.

Fixed by mirroring the isolation flags in `scripts/run-cross-boundary-probe.sh`, which cost nothing —
26 of 26 checks still pass. **Keep them in step with the pbxproj**, and when the probe and the app
disagree, suspect this before suspecting the code.

**Read the primary source before running anything.** SDK headers, availability annotations and
`swift package dump-package` answer *what an API is specified to do*, in seconds, and they answered
two of Spike B's three questions before it was ever run: `pause` appears zero times in the whole of
ScreenCaptureKit, and `mixesAudioWithMicrophone` carries `API_AVAILABLE(macos(27.0))`. Neither
needed a recording.

The division is not "reading versus measuring", it is which question is being asked:

| Question | Answered by |
| --- | --- |
| what the API is *specified* to do | the header, the annotation, the manifest dump |
| what it *actually* does on this machine, this OS version, this configuration | a measurement |

Measure the second only. Spending a spike on the first is slow, and — worse — a measurement of a
documented behaviour reads like a discovery.

**State a measurement's subject as explicitly as its value.** "Screen recording: granted" — *for
whom?* The sentence omits its subject, and a measurement will quietly supply a different one.

Phase 2 Task 6 built a repeatable permission check that reported all four permissions granted while
the app under test appeared in none of the four System Settings panes. Both cannot describe one
process. The check ran from a bare `swiftc` executable with no bundle identity, so TCC attributed it
to the responsible process up the chain — `zsh → claude → zsh → login → cmux.app` — and `cmux` holds
those grants. It measured the terminal.

So: `granted, granted, granted, granted` is not a claim. `granted ×4, for pid 1234, bundle
video.soredemo.Soredemo` is one, because it can be wrong. **The dump prints its own subject —
bundle identifier, executable path, whether it is inside a `.app`, pid — beside the values.**

**And then that was not enough either.** Running the app's own binary directly from a shell prints a
*correct* subject block — right bundle identifier, inside a `.app`: yes — and still returns
misattributed values. `Bundle.main.bundleIdentifier` reads `Info.plist`: it answers *what does this
binary say it is*, not *who does TCC hold responsible for it*. Same shape, different question, and
they diverge exactly when the binary is `exec`'d rather than launched by `open`.

So the rule has a second half: **print who is asserting the subject.** A block sourced from
`Info.plist` is the binary's claim about itself. The attribution that decides the answer lives
somewhere else, and a check that prints only the first has moved the ambiguity rather than removed
it.

The class recurs beyond this instance — an app launched from Xcode can have Xcode as its responsible
process, which differs again from Finder. Moving the check inside the app ended one occurrence.

**And the reconciliation went the wrong way by default.** The failure presented as four greens —
output that invites no question. Had the program been run before the human was asked, the
comfortable path was to doubt what the pane showed rather than what the probe measured, because the
pane is visible and concrete while "which process are we measuring" is invisible and abstract.

> When two sources disagree, the path of least resistance is to doubt the one that is harder to
> check. So name which side that is *before* reconciling, and check it **last** — cheap doubt is
> where you will stop.

This is why the human answer was recorded first, in a file the implementing agent was forbidden to
read. The ordering costs nothing and it is the only reason this was found.

**A probabilistic test presented as reliable is a measurement with a safe default, one level up.**
Say the miss rate, and say whether a deterministic form was available.

Phase 2 Task 3 closed a real gap — `JSONEncoder` without `.sortedKeys` emits per-process key orders,
measured across six processes — with a test that pins the encoded key order. It reddened five times
out of five under the mutation and was written up as reddening "reliably". But `PointerSample` has
four keys, so there are 24 orderings and roughly one run in 24 emits alphabetical order by chance
and passes on wrong code. Five red runs is consistent with "always" and equally consistent with
"96% of the time"; five trials cannot separate them.

The deterministic form was available and cheap: expose the encoder's `outputFormatting` as a
constant and assert it contains `.sortedKeys`. That checks the code path rather than sampling a hash
seed.

**And the miss happened during the verification of the fix.** Re-running the mutation eight times:
the deterministic assertion went red 8 of 8, and the byte-order test went red **7 of 8** — one run
passed on mutated code. The failure mode was not argued into existence; it appeared inside the
experiment run to check it.

So: a green light with a probability attached is not the same kind of evidence as one without, and
the difference is invisible in a report unless someone writes the number down.

**"Uncoverable in process" is not "unverifiable", and this project has the difference.** Swift
Testing has no crash expectation, so a `precondition` cannot be observed by `swift test`. That is a
fact about one tool, not about the guard. Phase 1 built the alternative and used it at least six
times — compile the real module against a small driver, run it as a child process, and inspect the
exit status and stderr; then remove the guard and confirm the probe stops seeing the trap, so the
probe is known to be sensitive to the thing it is watching.

Phase 2's first task shipped two `precondition`s with no coverage of any kind, one of them
structurally identical to a guard **three files away in the same module** that Phase 1 had already
covered this way. The brief was the reason: it recorded "expect nothing red, note it as a known
blind spot" as though that were a fact about the world. It was half of Phase 1's note — the half
that said `swift test` cannot see it, without the half that said something else can.

So: when writing that a thing cannot be tested, say **by what**. A blind spot named without its
instrument is an excuse that outlives its reason.

**A hand-computed constant in a task brief is a guess until something computes it.** Three times in
Phase 1 an implementer has been handed a wrong number by whoever wrote the brief and has been right
to override it: an FNV-1a vector for `"foobar"`, a test-suite total of 226 that was 229, and a
`droppedBytes` of 12 that was 11. Each was a value the author worked out by hand and wrote down
without running anything. The first came with the instruction *"do not adjust the vectors"* — which,
followed, would have pinned the error into a test and made the code wrong in the direction of the
document.

So: **an implementer who checks a supplied constant against an independent computation and disagrees
is doing the job.** A brief's numbers are requirements about intent, not about arithmetic. If you
are writing the brief, compute the values with a tool and paste the output; if you are implementing
from one, verify before you pin it.

**A compile failure is not a RED.** This project's rule is that an unobserved red light is not a
check. But writing the test before the type means the first failure is always `cannot find 'Foo' in
scope` or an unresolved symbol at link time — which satisfies the rule's words and not its meaning.
A missing symbol proves the test file names the API. It proves nothing about whether any assertion
discriminates correct behaviour from incorrect. The red that counts is **behavioural**: the code
compiles, the tests pass, you break the behaviour, and a test goes red.

**A mutation's red set is evidence at the granularity it is recorded.** A parameterised test that
reddens under a mutation has not been shown to catch it — only that *some* of its cases did. Task 5
recorded `commentAndRawStringOpenersInsideARawIdentifierAreContent["\`a/*b\`"]` as the red set for
disabling the raw-identifier branch, and read it as the branch being covered. It named one fixture
of three; the other two passed with the branch deleted, rescued by unrelated defensive code. The
disconfirming evidence was inside the artefact being used as proof, one level of detail below where
it was read. When a mutation reddens fewer cases than a test has, that gap is the finding.

In this workflow, **mutation checks are the only mechanism that produces a behavioural red.** They
are not a bonus round. A task that shipped without one has tests that were never shown to be able
to fail, whatever colour they were at the start. Task 16 is the evidence: thirteen tests, all
passing on their first run after a compile-level red, three covered by mutations — and the review's
two Important findings landed on exactly the tests the mutations did not reach, one of which passed
identically under the very implementation the requirements forbade.

**Mutation testing is bounded by fixture diversity, and that ceiling is invisible.** Breaking a code
path changes nothing if no fixture ever reaches it — so a mutation check that finds nothing is
evidence about the fixtures as much as about the tests. Four consecutive mutation checks found real
defects in this phase; none of them could have found the `scale: 1` problem, because no fixture had
a scale to get wrong.

**Check the claim against the thing, not against another claim.** Most errors in this project have
had one shape: an assertion about state that was never compared to the state. A grep that collapsed
two build settings and reported the wrong one. `main` recorded as sitting at a commit it had already
moved past. Every `swift build` green while the toolchain the app is opened in could not read the
manifest at all. A green light is evidence for exactly the proposition it tests, and usually that is
narrower than the one being claimed.

**Which build, and from what state.** The question has two axes and this project has been caught on
both. *Which tool* — `swift build` does not build test targets, so a suite can be green in `swift
test` and a package still fail under `xcodebuild`. *From what state* — every green light in Phase 1
was observed on a warm `.build`, and no clean build was run until Task 16, because nothing in the
plan asked for one and there is no CI to run one unasked. The gap was real whether or not it hid a
defect: a verification never performed covers nothing. Every phase ends with `rm -rf` on a scratch
path and `swift build --build-tests` from nothing.

**A total counted after a filter cannot show what the filter removed.** `CaptureSession` reported 310
complete frames over a zero-byte file, and 1045 lost audio buffers under a single number that could
not say which of two tracks lost them. Both were the same mistake: the count of "how many were
there" was taken downstream of the thing that discarded them, so what was discarded never existed on
the books. Any check for "did something go missing" needs its total incremented **before the first
filter**, and every path out counted by name, so the paths sum to the total exactly. Prefer the
conservation law (`delivered == appended + refused + skipped-A + skipped-B + …`) to the tempting
equality (`delivered == appended`): the equality is violated legitimately — a real-time input under
backpressure refuses frames — so it fires on healthy runs and gets relaxed rather than fixed, and a
relaxed assertion still looks like a check. The conservation law has no legitimate violation. Count
per subject, not summed: a law that cannot name the track it broke on is a smoke alarm without a
location.

**`_ =` is a claim, and it needs a reason beside it.** Swift warns on an unused return value;
`@discardableResult` and `_ =` are the two ways to silence that warning, and this project was bitten
by each of them within one task. `_ = videoInputRef.append(sampleBuffer)` made a run in which every
append failed indistinguishable from a perfect one; `@discardableResult` on `stop()` made "throw away
the entire record of what was just recorded" the shortest thing a caller could write. A bare `_ =`
with no comment is a defect. Measured before adopting this: ten non-test occurrences repo-wide, none
in the app target — the rule is nearly free.

**A failure value must not land inside the success type's legal range.** `stop()` returned a
`SegmentTable` naming `master-00.mov` when no such file existed: structurally perfect, factually a
lie, and nothing downstream could tell. The fix is not a log line, it is a type the caller cannot read
without saying which case they are in — the same move as `Evidence`'s non-empty requirement and
`NormalizedPoint`'s validating initialiser. Make the bad state impossible to hold by accident.

**Every fixture set needs a positive control, and it runs first.** A malformed synthetic
`CMSampleBuffer` — one with no data buffer at all — produced `-16122`, a real AVFoundation error code
that reads like a verdict on the thing under test and was in fact a verdict on the input. Three of
four rows in that experiment were unanchored and it took a later run to notice. So: one row per
fixture set whose answer is known **independently** of anything under test (here, the exact error a
real run had already produced). Run it first; if it does not match, stop and fix the fixture, and read
nothing below it. Synthetic CoreMedia and AVFoundation fixtures are especially easy to get subtly
wrong.

**A refusal message may state only what was measured.** A check has three outputs — pass, fail, and
*refused to run* — and the third is the only one nobody writes a test for, because it fires only when
something is already wrong. That is exactly when a person begins investigating, so a wrong refusal
message misdirects at maximum leverage. A padding check declined with "the content spans the full
buffer width"; the content spanned 1600 of 3024 pixels, and the next hour would have gone to
investigating something that never happened. Write "left margin 0 px, right margin 1424 px; the
chosen edge has no padding beside it" instead. A measurement cannot lie the same way an inference can.

**An observed default is not a contract.** ScreenCaptureKit anchors window content at the output
buffer's origin; `SCStream.h` says only "if not set, then the entire output surface is used" and
promises nothing about placement. Building the buffer-to-window mapping on that measured behaviour is
the same footing this project already refused twice — decimal rendering of floating-point, and
Unicode normalisation resting on the current OS's ICU tables. Set the value (`destinationRect`) so the
anchor is chosen rather than inherited. The test of the difference: if the OS changed it tomorrow,
would anything fail? An inherited default displaces every derived coordinate silently.

**A justification that rests on the caller must name the caller.** `CaptureSession.init(scale:)`
carried "this type does not derive a display's scale itself, because the caller already has to
compute it once to drive the picker." That was true when `start()` was the only caller. It became
false the moment reconfiguration handling appeared — a second caller, *inside* the type, which never
gets a chance to supply a fresh value — and nobody re-checked, because a paragraph of reasoning reads
like a decision that has already been made. The comment was never wrong; it expired. Write "**`start()`**
already computes it; any other caller must supply its own" instead, and the second caller is in
violation the moment someone reads the line, with no one needing to think to re-examine it. The same
shape as the expiring exemption in `CanonicalEncoding.version`, and harder to catch, because there is
no date on it.

**With several candidate causes, make the discriminating measurement before fixing *or explaining*
any of them.** The rule was written for fixes and it applies just as much to a sentence in a report.
A verification step observed zero seconds of secure input, and that was written into a commit message
and the ledger as "a `sudo` prompt does not enable system-wide secure input" — an inference, stated as
a finding, with nothing behind it. The owner offered a simpler competing explanation: `sudo` caches
its credential for five minutes, they had authenticated shortly before, so no prompt appeared at all.
Both explanations predict exactly the same observation, so that run could not tell them apart.

The discriminating experiment cost one minute: measure that the credential has expired, re-run, and
sample the flag. It came out confirming the original claim — the prompt appeared, the mouse moved
(1779 samples), and secure input stayed off for all fourteen seconds. Being right is not the point.
The claim was in a commit message before any of that existed, and had the simpler explanation been
the true one, the record would have carried a wrong fact about the OS into every future task that
touched secure input.

**With several candidate causes, make the discriminating measurement before fixing any of them.** A
display reconfiguration left frames resampled, and three causes were plausible: a stale
`destinationRect`, an expired `scale`, and the gap between the callback and the new segment opening.
Three fix-and-rerun rounds followed, the first two diagnosing wrongly — and the first of those fixed a
real but unrelated defect, which made it look like progress. One measurement separated all three:
buffer size, source size, scale and per-frame `ContentScale`, recorded **per segment**. Fixing is the
expensive move, especially with a person waiting; measuring is cheap. This project measures first
everywhere except when debugging, where it reverts to guessing.

**A caveat belongs where the people it protects will be.** Two probe checks carried "on a
single-display machine this passes trivially" in a source comment and printed two unqualified `ok`
lines. Anyone watching the console saw the mirror-fold path verified; on that machine it was not
exercised at all. A caveat that lives only in the source is a caveat for people already reading the
source, and those are not the people the output misleads. This is the second half of "state a
measurement's subject": say it, and say it **to the audience that will act on it** — which for a
check means its printed text, conditionally, only when the limitation actually applies:

    ok  no display appears twice in the arrangement  [VACUOUS ON THIS RUN: 1 display attached —
        this asserts nothing about mirroring. It needs two or more displays, at least two mirrored.]

**A cross-subsystem agreement is a check, not a note.** Two paths derived the same display's
geometry from different APIs — `CGDisplayMode.pixelWidth` on the observation side,
`SCDisplay.width × scale` on the capture side — both feeding `GeometryRevision`, whose mismatch is a
`precondition` trap downstream rather than a coordinate that is slightly off. The first instinct was
to write it into the ledger as a risk for the task where the two finally meet. It is checkable now,
with no permission and no human: assert they agree, **and** assert they disagree under a deliberately
wrong input, so the agreement is a fact about the derivations and not about a digest that ignores
them. A landmine someone has to remember is worse than a red light.

**A rule with more than two instances should become a table, and new instances go in the table
rather than in this file.** Measured over this project's own history, rules have two fates:

| Rule | What it became | Held? |
| --- | --- | --- |
| a hand-written list rots by omission | the exemption list, as an artefact | held |
| a number in a report must be executable | `scripts/count-tests.sh` | held |
| a vacuous pass must have its own vocabulary | `VerificationStep.didNotHappen` and its exit code | held |
| a check nobody watched fail is not a check | prose, here | **missed twice in Task 9** |
| a gap is recorded as an interval, not a count | prose, here | **missed once in Task 10** |

The three that became artefacts have not failed again. The two that stayed prose were missed by
authors who had the correct implementation open one file away — Task 10's author had
`SecureInputInterval` in the neighbouring file and prose did not send them to look at it.

This file is over six hundred lines. Nobody re-reads six hundred lines at the start of a task, and
that length is itself the evidence. A table is checked against itself: the missing sixth row is
visible, and a row that disagrees with its neighbours is conspicuous. The first such table is
`docs/ARCHITECTURE.md`'s **D6a — the gap register**.

### The conjunction register — one expectation, two claims, one assertion

Eight rows in the identifier migration were a single expectation stating **two or more** things,
discharged by an assertion covering one of them. Enumerated rather than summarised, because the
claim that follows can only be tested against a list:

| Spike / step | id | the claims in one row | which went unchecked |
| --- | --- | --- | --- |
| A `aRealTimeoutDisable` | detection | `detectedBy == .enabledPoll` **and** `disabledBy == nil` | `disabledBy` |
| A `aRealTimeoutDisable` | polls | `tapEnabledPolls > 0` **and** the run survives | the run surviving |
| A `theRealPortGoesDown` | (was) edges | the window contains `T_off` **and** the over-estimate is bounded | the bound |
| B `runReconfig` | after-the-change | a different revision, a second segment, `.displayReconfigured`, no resampled frame | three of the four |
| B `runVideoOnly` | destination | the rect was set **and** the frames came back at the buffer size | the frame size |
| B `runAudioTones` | tracks | two tracks **and** they are distinguishable by format | distinguishability |
| C `pointerTrack` | coordinates | every value in [0, 1] **and** the track spans more than a point | the span |
| C step 5 | budget | the largest stall that survives **and** the smallest that trips | the smallest |

**Measured, and settled.** The claim behind the identifier migration was that *naming an
expectation forces it to be atomic*. Task 11 wrote a fresh batch under the new rules and the batch
was counted twice — once by its author and once independently, because the person supplying the
number is the person the rule constrains, and the independent count came back worse in both
directions.

| | conjunctions | tautologies |
| --- | --- | --- |
| the eight above, written before identifiers | 8 | — |
| Task 11's first batch, 16 rows | 4 | 1 |
| after one rewrite aimed at exactly this, 22 rows | **0** | **4** |

**So identifiers work, on conjunctions, and a scan is not needed.** This register stays as the
instrument that settled it, not as an open question.

**And the rewrite surfaced a different defect the same rule cannot touch.** A name can be perfectly
atomic and still name something that cannot fail. Those four are the next section; they are not one
problem and they do not share a mechanism.

### A discriminator's only legitimate certificate is running it in both states

A predicate written to tell two states apart owes a red in a specific shape, and no other shape
counts.

`XPC_SERVICE_NAME != nil` was written to distinguish "launched through LaunchServices" from "exec'd
from a shell". The variable is present on **both** paths — `0` when exec'd — so the predicate would
have reported every run as correctly attributed, forever. And it would have passed a carelessly
filled certificate: *"delete the variable and it goes red"* is a true red about an irrelevant
mutation. The dimension that mattered was never touched.

**So: run the discriminator in each of the two states it claims to separate, and show it answers
differently.** Not "it can fail" — *it distinguishes these two*. Anything less is a red on the wrong
axis, which is exactly the `label == "from"` failure one level over.

**And when the header has no answer, find the discriminator by DIFFERENCE, not by nomination.**
Nominating a variable that sounds right is a hypothesis, and confirming a hypothesis fails toward
"everything is fine" — the direction that produces a green. Dumping every environment variable on
both launch paths and diffing them found `__CFBundleIdentifier`, which does not merely differ but
*names the responsible bundle*:

```
open -n …app     __CFBundleIdentifier = video.soredemo.SpikeA
exec …/SpikeA    __CFBundleIdentifier = com.cmuxterm.app
```

The difference-first version costs one extra command and cannot select a variable that fails to
discriminate, because a variable that does not differ is not in the output.

### Bounding an old measurement by the part that provably did not move

An old number often cannot be re-taken — the tree has moved, and re-running the command answers
about today. It can still be *bounded*, and the bound is often enough to prove the old number was
about something else.

D2-16 recorded "575 undefined symbols across the six library modules". A later task re-took it
per-module, summed to 1321, and reported +130% in 17 hours — which happened to be D2-17's own
stated failure case, so the conclusion looked earned. The rebuttal used no new measurement at all:

> `git diff --stat fb6792b..HEAD -- Sources/` shows `Graph`, `Framing` and `Variants` **entirely
> unchanged** since D2-16 was written. Those three alone are 472 symbols today, and therefore were
> 472 then. A per-module sum at `fb6792b` was already above 575 before counting the other three.
> So 575 was never a sum.

**The contradiction was visible before any re-measurement, inside one artefact.** The old number and
the parts of the tree that provably did not move cannot both be true under the same operator. Like
for like the movement is +10%, which inverts the argument the 1321 supported.

The technique generalises to any stale figure with a reachable history: *find the subset that
demonstrably did not change, price it today, and check whether the old number can still be what it
claims to be.* The violator count in D2-14 is the same shape — ten written before Task 4.5 closed
two of them, and the two it lost are the two D2-14's own prose traces as reachable from
`ProjectSnapshot`. The document contradicted itself, and the contradiction needed no scan to see.

### A claim about the platform leaves a row even after it is rewritten

The red obligation forces a row about the environment to be rewritten as a row about **our recording
of** the environment, because no mutation in this repository can make the OS behave otherwise. That
rewrite is correct and it is not free: it **erases the original claim's exposure**. If the OS
changes, the rewritten expectation still passes — we go on faithfully recording whatever we are told
— while the conclusion built on the original claim is quietly wrong.

So a rewrite produces **two** artefacts, not one:

1. the rewritten expectation, witnessable, with a recorded red;
2. a row in `docs/ARCHITECTURE.md`'s **D6b platform-premise register** — the claim, how it was
   established, on which OS build, and what breaks if it changes.

The register's trigger is an external event rather than someone remembering: **a macOS major version
bump.** The floor is 26 and 27 already exists, so the table is today the list of what has to be
re-measured when 27 becomes the floor. Seventeen rows so far, gathered from design-doc sections, code
comments and commit messages — which is what "prose gets missed" had accumulated to before anyone
counted it.

### A red is a discharge obligation, not a detector

"A check nobody watched fail is not a check" has been in this file as prose since Phase 1, and this
file already records that it was **missed twice in Task 9** for the reason prose is missed. The fix
is not to say it again.

Change what an expectation owes. Today an expectation is discharged by an assertion citing it. It
must also carry **a recorded red**: the mutation that made it fail, run once, written down beside it.

    .init("edges", "the window contains T_off",
          "start <= T_off <= end",
          red: "move the click's global X 2400 -> 2000; five checks fail including the negative one")

**This is not a tautology detector.** It asks for something a tautology cannot produce. There is no
mutation that makes "`endedBy` is a case of a non-optional enum" fail, so no red can be recorded for
it, so the row cannot be discharged — and the author finds that out while writing the row rather
than a reviewer finding it four rounds later. The same demand catches the drifted check in the
filename row: no mutation reddens "two files in one directory have different names", but the URL
version reddens under the writer that named all three the same, which is the defect that was
actually there.

**A dimension that cannot be reddened must say where it went.** `which-channel` asserts both that
the OS delivers a particular notification and that we record the channel we were told about. The
second has a mutation; the first has none reachable from this repository. The certificate cannot be
completed for that dimension, so the row names its destination instead — `docs/ARCHITECTURE.md`'s
D6b platform-premise register. That pairing used to be a rule someone had to remember; as a field
that cannot be left blank, it is a question the author is forced to answer. Four things in this
file have now made that same move, from a rule to a certificate.

It is also not new behaviour. It is what was done by hand for `given`'s position rule — inject a
violation, watch the scan name it, revert, and only then believe it — and for the guard's own
regression case. The action already existed; it did not have a name or an obligation attached, so it
happened when someone thought of it.

**The existing checks are sampled, not migrated — and the sample is over DIMENSIONS, not over
checks.** The first version of this said "take twenty checks at random and try to redden each",
which is the wrong unit, and migrating eight already-filled rows proved it: two of the eight needed
a *second* certificate, and one of those second dimensions had never been witnessed at all.
`edges` asserts a window contains `T_off`; the lower edge had a red and the upper edge did not, and
sampling at the level of checks would have found that check reddenable and moved on.

So: take twenty checks at random, **for each one first write down the dimensions it claims to
guard**, then try to redden each dimension separately. The output is two numbers rather than one —
checks that cannot be reddened at all, and *dimensions* that cannot. The second is the estimate of
how much of the suite is decoration; the first only finds the checks that are wholly ornamental,
which are the easy ones.

New expectations carry a dimensioned red from today; the existing ones owe that estimate and a
register of which have no observed red.

### The tautology register — four rows, four different mechanisms

The four expectations that survived Task 11's rewrite could not fail. Naming them together as "an
unfalsifiable check" is what would make them one problem; they are four, and only one is answered
by writing another scan.

| Row | Why it cannot fail | What answers it |
| --- | --- | --- |
| a straddle count cross-checked against a counter | the counter does not exist anywhere in the tree — `grep -i straddle` returns three prose comments and no field | a zero-occurrence scan. The mechanism is already here and used three times; this is free |
| "`endedBy` is a reason" | `SegmentBoundary` is non-optional, so it is always a case | check first whether the predicate reduces to a `nil` comparison or an exhaustive `switch` whose arms all return `true` — if so **the compiler already says this**, and the answer is promoting that warning to an error, not a new scan |
| "the trailer has one `GapWatch` per site" | the trailer's *decoder* refuses a trailer that does not | the invariant is real and lives in the wrong place. Push it into the type and this row degrades into the row above |
| "the three log filenames are distinct" | a directory cannot hold two files with one name | nothing in the type system reaches this — the invariant is POSIX's. Only a recorded red catches it |

**The last row is the one to remember, and its shape is not "one useless check too many".** The
falsifiable version is the distinctness of the three URLs `close()` returned — and that is exactly
where the defect lived when it was found. The check was not invented redundantly; it was **moved off
the place the defect actually lives** onto a neighbouring fact that happens to be guaranteed. A
tautology is usually a check that drifted, not a check that was never needed.

**A hand-written number beside the list it summarises will drift from it.** Task 11's report listed
five corrected rows in its own table and said "four" in the prose above it, and the prose is what was
copied into the ledger. Either derive the number from the list at the point of writing, or do not
write it. This project already applies the rule to its own product — every derived value carries its
origin — and a ledger entry is a derived value with no origin.

### The mislabelled-record register — right results under the wrong subject

Every human verification in Phase 2 was recorded under a spike's bundle identifier. Measured
afterwards: those spikes hold no grants, and each run was attributed to `com.cmuxterm.app` — the
terminal that exec'd it. The results are not wrong. The **subject** of each is.

This is not the stale-number failure, and treating it as one gets it wrong in both directions. A
stale number is a wrong value. This is a **correct value filed under a claim it does not support**,
and it passed every gate, because nothing checks a subject.

So the disposition is per row, not "re-run everything" and not "it probably makes no difference".
The question each row answers is: **does this conclusion depend on the identity?**

| Recorded as | Actually ran under | Does the conclusion depend on identity? |
| --- | --- | --- |
| Task 8 step 1 — window capture, `ContentScale == 1` on 918 frames | `com.cmuxterm.app` | **No.** ScreenCaptureKit's buffer geometry is not per-identity. Re-labelling is enough |
| Task 8 step 2 — two audio tracks, four tone assertions | `com.cmuxterm.app` | **No.** Track separation is a property of the writer |
| Task 8 step 3 — display reconfiguration splits the segment | `com.cmuxterm.app` | **No.** `CGDisplayRegisterReconfigurationCallback` is not identity-scoped |
| Task 9 steps 1–2 — pointer track, click down/up | `com.cmuxterm.app` | **No**, but see the row below — the *grant* question it answered is void |
| Task 9 step 3 — 41 keystrokes, 1 recorded, 40 refused | `com.cmuxterm.app` | **No** for the filter. **Yes** for "Input Monitoring was granted to SpikeC" — that was never true |
| Task 9 step 4 — secure input, 852 events suppressed | `com.cmuxterm.app` | **No.** `IsSecureEventInputEnabled` is system-wide |
| Task 9's boundary finding — "a pointer tap needs no grant, a keyboard tap does" | `com.cmuxterm.app` | **YES, and it is void.** Both ran under an identity that already held both. The boundary was inferred from which step first failed, and neither step ever tested the spike's own permission state |
| Task 10 human 1–2 — the poll finds a real disable | `com.cmuxterm.app` | **No.** Tap disable and re-arm are per-process, not per-identity |
| "the product's never-asked Screen Recording state is unspent" | — | **Still true, and now for a stronger reason:** not even the spikes consumed it |

One row is void rather than mislabelled, and it is the one that reads most like a finding. Everything
else is re-labelling.



**The numbering below is `ARCHITECTURE.md` D6's, which is the only one.** Do not restate it
elsewhere and do not renumber it here; this section is a reader's copy, and D6 is the authority. Two
schemes were in circulation until Task 19, both cited from source — `CGGeometryBridge.swift` had to
carry a parenthetical saying which "rule 5" it meant.

**Each rule says what enforces it, because the mechanisms differ and the difference matters.** The
plugin enforces rules 1, 2 and 4 — those fail `swift build` and `xcodebuild`, on every build. Rules
3 and 5 are tests: they fail `swift test` and **not** an `xcodebuild` of the app, because the Xcode
project has no test target. Rules 6 and 7 are inert; the code they constrain does not exist yet.
If you change a rule, change its mechanism in the same commit — and if it has no mechanism, say so
rather than writing it as though it had one.

1. **The `SoredemoCore` package imports Foundation only** — *plugin; fails both builds* — — `Package.swift` and `Sources/` sit at the repository root — no AppKit, no ScreenCaptureKit, no
   AVFoundation. **The compiler does not enforce this.** It constrains edges *between package
   targets*, and even that degrades to a warning on a warm `.build`; it places no restriction at all
   on system frameworks, so a target with no declared dependencies can import AppKit and build fine.
   `Plugins/ArchitectureCheck` is what makes it a build failure, on every build. Do not work around
   it, and do not detach the plugin from a target to make a build pass.

   **This constrains the package, not the app.** The app target uses ScreenCaptureKit, AVFoundation,
   AppKit, and Metal freely — that is where recording, rendering, and UI live.

   ```
   Soredemo.xcodeproj + Soredemo/   App/ UI/ Capture/ Resources/   ← platform frameworks
        │  captures, writes an observation log
        ▼
   observation log → evidence (plain data)
        │
        ▼
   Sources/   Geometry/ Timeline/ Graph/ Framing/ Variants/ Project/   ← Foundation only
   ```

   The core does not record; it reasons about a recording. Pure logic tests with no screen, no
   permissions, and no display — and derivation stays a deterministic function of its input, which is
   what makes staleness and content-hash approval mean anything.

2. **No `CGRect`, `CGPoint`, `CGSize` or `CGFloat` anywhere in the package** — *plugin; fails both
   builds.* **Anywhere, not just in the public API** — the checker scans every line of every file,
   and the weaker "public API" wording that stood here until Task 19 stated the rule two ways
   looser than the one that fails the build. Capture converts on entry, render converts on exit.
   Nothing in between speaks in pixels. And the compiler is no help: Foundation on Darwin
   re-exports these types, so `let r: CGRect? = nil` compiles clean in a Foundation-only target.
3. **No ambient time or randomness** — *tests; fails `swift test` only.* `Tests/DeterminismTests`
   reads link-time symbols for the package; `Tests/AppSourceTests` scans text for the app, where
   ambient values enter at `Soredemo/Support/Minting.swift` and nowhere else.
4. **No manifest declares a package dependency** — *plugin; fails both builds.* Every
   `Package*.swift`, not just `Package.swift`. This is what keeps rule 1's import allow-list
   complete: with zero dependencies there is no unlisted module to smuggle one in through.
5. **CG types in the app appear only in `Soredemo/Capture/CGGeometryBridge.swift`** — *test; fails
   `swift test` only.* A test rather than a plugin rule because the plugin attaches to SwiftPM
   targets and cannot see the Xcode app target at all.
6. **One owner for the observation-log → graph join** — *inert.* No mechanism; the code does not
   exist. Becomes real in Phase 3.
7. **`applyingProduced` is the sole writer of a `Derived`** — *inert.* `Derived`'s public
   initialiser is what this will have to constrain; see `ARCHITECTURE.md` D4.

**Not in this numbering, deliberately** — these are decisions with letters, not architecture rules
with mechanisms, and giving them numbers here is what produced two colliding schemes:
comparing `NormalizedFrame` across `geometryRevision` is a precondition failure (D3) · Swift 6
strict concurrency, no exceptions (D2) · app chrome is 100% standard SwiftUI, never
`.glassEffect()`, never `NSGlassEffectView`, content surfaces opaque (D7).

---

## Reading other people's code

`../opensource/` holds checkouts of comparable projects. **They are reference for ideas, not a source
of code.** Read them to understand a problem; write the solution yourself.

If you ever do adapt something concrete, put a header on the file naming the source and one accurate
word — `Adapted`, `Rewritten`, or `Copied` — and say so in the commit message. Licences differ and some
are copyleft, so an untracked copy is a problem that surfaces at the worst possible moment. Keeping the
count at zero is the simplest way to never have that conversation.

**Do not read `a source-available project`** — it is source-available for personal non-commercial use only, and
nothing in it is unavailable elsewhere.

---

## Testing

**Swift Testing** (`@Test`, `#expect`, `#require`), not XCTest for new work.

- Pure logic in `SoredemoCore` runs with no screen and no permissions. Keep it that way.
- **Golden-image tests** prove preview and export produce identical frames. They fail the build.
- **Evaluations framework** for anything the model touches — specifically, that a claim with no valid
  supporting evidence cannot reach an approvable state.
- Calibration constants (gate thresholds, merge gaps, depth curves) get tested against **measured
  distributions**, not chosen by intuition. See `ARCHITECTURE.md` D4.
