# Evidence Cut, and the surface an agent edits through

*Written 2026-11-08, after `v0.1.0` shipped as a public beta. Settles what the director's cut
is, what an agent may do to a take, and in what order the work lands. The market it answers is
`../research/landscape.md`, "November 2026".*

## The question

In the month before this was written, letting an agent edit a recording stopped being unusual:
recorders now edit over MCP and cut by deleting transcript words, video editors expose their
timeline to Claude, Codex and Cursor on `127.0.0.1`, tools have a coding agent write, film and
cut its own demo, and hosted editors turn footage plus a goal into a first cut. **Every one of
them cuts from pixels and words.** None can say which step a cut removed, or why; none works
from what was pressed in a native Mac application; and the ones with agents apply the edit and
offer an undo.

Soredemo has the thing they lack — a log of what was pressed, in which application, and why
each click was or was not framed — and a thesis they do not: *automation proposes; the person
decides.* So the question is not whether to add an agent. It is:

1. What is a cut proposal, as a value, so that it can carry its evidence?
2. Who may produce one — a rule, the on-device model, an outside agent — and what may each see?
3. How does an outside agent reach a take at all, and what can it never do?
4. In what order does this land, so that each step is observable in the product?

## What a proposal is

*Rewritten 2026-11-08 when stage 2 landed: the first draft called a proposal a `Derived` value
keyed by a span from one step's origin to another's, and neither survived building it. Code:
`Core/Sources/Framing/CutProposal.swift`, `TakeActivity.swift`, `DeadAirProposer.swift`.*

**A proposal is a plain value whose evidence is its own non-optional fields**, the shape the
zoom plan already has — a `FramingDecision` names its gate, and a reviewer's decision about it
is stored apart, keyed on the click. `Derived` and its graph are not used, because nothing in
the product uses them yet (`derivation-graph` is ◐ for exactly that reason), and a first
production caller of the graph is its own piece of work rather than a side effect of this one.
When that row lands, proposals move into it; the fields below are what they will carry.

| Field | What it holds |
| --- | --- |
| `reason` | closed: `deadAir` today. `repeatedAttempt` and `outsideTheGoal` are later cases |
| `quiet` | the whole span in which nothing happened — what the proposal rests on |
| `removes` | the part of `quiet` proposed for removal |
| `openedBy`, `closedBy` | what bounded the span on each side, by name: `press(step:)`, `click`, `shortcut`, `pointerMoved`, `speech`, `unobserved`, `recordingStart`, `recordingEnd` |
| `duringStep` | the step in progress when the quiet began, by number |
| `key` | the reason and the instant the quiet began; a dismissal is stored against it |

**Anchored to what happened, not to a bare time.** The first draft required the span to run from
one step's origin to another's. A real pause does not: it begins when the pointer stops after
step 4, not at step 4's press, and ends half a second before step 5. So the span is bounded by
*measured instants*, each with its name, and the steps it lies between are carried beside it.
That keeps the property the draft wanted — every bound can be checked against the log, and the
same log re-derives the same key — without pretending a pause starts at a click.

**The initialiser is internal**, so only a producer in `Framing` builds one, and a proposal with
no bounds cannot be spelled. Proposals from outside — an agent's — arrive in stage 4 through a
validating constructor that refuses a span outside the take or running backwards, by name.

**Accepting one is an authored edit**, in stage 3: an ordinary undoable cut in
`EditState.timeline`. The producer-value rule holds in stage 2 already, for the authored half
that exists — a dismissal: `CutProposals.pending(_:dismissed:)` drops every proposal whose key
a person dismissed, and `aDismissedProposalStaysDismissedAfterReDerivation` is its test.

### How others decide what is dead air, and what was combined

| Approach | What it measures | What it misses |
| --- | --- | --- |
| transcript editors | silence in the audio, found from the transcript; offered as *shorten* or *remove* | a silent span in which the person was clicking through the product is the demo itself |
| browser silence cutters | audio gaps over about 0.6 s, cut in one pass | the same, and they cut rather than propose |
| a cursor-driven camera's intent classifier | no input events for 5 s is `idle` | speech — a narrated pause with a still pointer reads as idle |
| research on tutorial video | a transcript and a software-usage log together; breaks at application switches and time gaps | built for segmentation, not removal |

So: **quiet means every channel at once** — no press, no click (a press on an unnamed element made
no step and still happened), no shortcut, no pointer movement beyond a tremble, no speech — and,
from this project's own log, **a span the observer could not see is not quiet**: secure input
emits nothing, which is the absence of a measurement, not stillness. From the transcript
editors, **shorten rather than remove**: half a second is kept after the last thing that happened
and before the next, except at the recording's own start and end. Stillness is measured **from
where the pointer came to rest**, not from the previous sample, so a slow drift made of trembles
still counts once it has gone far enough. A recording in which nothing happened proposes nothing.

The constants — 2 s minimum, 0.5 s breath, 0.005 of the display — are uncalibrated.

## Who proposes

Three producers, in the order they are built, each seeing less of the world than the last:

1. **Rules over the log** — deterministic, no model. Dead air between two steps beyond a
   threshold; the same element pressed again after a short gap (a missed first try); a span
   where the pointer track is still. These need nothing but `RecordedSteps` and `PointerTrack`,
   they are exact, and they are testable with fixtures whose answers are known independently.
   **Their thresholds are uncalibrated until measured** against real takes, like every gate
   constant in this repository (`ARCHITECTURE.md` D4).
2. **The on-device model, for the goal.** "A 45-second launch cut", "the tutorial", "a vertical
   short" are choices among steps, not among seconds. The model is shown the numbered steps —
   label, application, length — and the numbered transcript sentences, and returns step numbers
   to keep. Everything it returns is validated against the numbers it was shown, exactly as
   chapters are. **`SystemLanguageModel.default` only**: the source test that forbids
   `PrivateCloudComputeLanguageModel` covers this producer too.
3. **An outside agent**, over the CLI or MCP, through the same validated proposal constructor.
   It may propose; it may not accept.

### Grounding, and why there is no vector store

What gets called retrieval-augmented generation elsewhere is, here, **grounding by key**. The
corpus is one take: tens of steps, a few hundred sentences. Every fact the model may use is
handed to it by number, and every number it returns is checked against that set. A vector
index would add an approximate lookup in front of a corpus small enough to show whole, and an
approximate lookup is the one thing a proposal's evidence must not rest on. **Revisit when the
library of takes is searchable** (`beyond-a-screen-recorder` idea 8): searching many takes by
what happened is a real retrieval problem, and the step records are its documents.

## The surface an agent edits through

**One registry of verbs, two front ends.** Each verb is a function from a request to a
response, both `Codable`, defined once:

| Verb | Kind | What it returns |
| --- | --- | --- |
| `status` | read | the project's take, its length, its steps' count, which proposals are pending |
| `steps` | read | the numbered steps, with label, application and span |
| `explain-framing` | read | for each click, the zoom it got or the gate that refused it, by name |
| `propose-cut` | propose | proposals from the rule producers, or the model's for a stated goal — **not applied** |
| `export` | read | a render of the edit as it stands, to a path the caller names |

The front ends are **a CLI inside the app's own executable** — `Soredemo.app/Contents/MacOS/
Soredemo cut steps demo.soredemo --json`, newline-delimited JSON when asked — and **an MCP
server over stdio** started by the same executable. stdio rather than a listening socket: a
port on `127.0.0.1` is reachable by every process on the machine, while a stdio server is
reachable only by the client that started it. The ROADMAP's `mcp-server` row said `NWListener`;
that changes here, for that reason.

**What no front end can do, ever:** accept a proposal, apply an edit without a person seeing it
in the editor, or publish. Accepting happens in the editor's review list, by a person. This is
`agent-review-tools`' "review posture, not generative" made into the type of the registry: there
is no accept verb to call.

**No argument-parsing dependency.** The `cli-surface` row named Swift Argument Parser.
Architecture rule 4 holds every manifest at zero dependencies, the README advertises zero, and
the verbs above are five with a handful of flags each. A small hand-written parser in the app
target, tested like any other code, costs less than the rule it would break. The row is
corrected in the same commit as this document.

**Text from outside is data.** A proposal's goal and an agent's arguments are attacker-
controllable (`agentic-threat-model`): they are quoted into the model's prompt as data under a
fixed instruction, never concatenated into it, and nothing they say can widen what a verb does.

## The agent panel: bring the agent you already use

A panel beside the editor where a person types what they want — "cut this to 45 seconds",
"why is step 6 not zoomed" — and an agent answers by calling the verbs above. **Which agent is
the person's choice, behind one protocol**:

| Provider | Where it runs | What leaves the Mac |
| --- | --- | --- |
| the on-device model (default) | `SystemLanguageModel.default` | nothing |
| the person's own Claude Code or Codex | their installed CLI, started headless by the app with Soredemo's MCP server attached, under **their** login — no API key is typed into Soredemo | what that agent sends its provider, which is the person's existing arrangement with it; the panel says so in one line before the first message |
| a local server the person runs | an OpenAI-compatible endpoint on `localhost` (LM Studio, Ollama) | nothing |

Driving the coding agent a person already has, rather than shipping keys of our own, is an
idea already proven elsewhere. What differs here is what the agent may do — the same verbs as
every other front end, so it can read and propose and **cannot accept**. Its proposals arrive
in the same review list as the rules' proposals, marked with which provider made them.

**What goes along with each message** is what is on screen, and only that: the playhead's
step, the selected step or zoom, and the take's step list. Never the video, never a frame,
never typed text that the privacy rules already keep out of the log.

## Pin a note where it is wrong

Pressing a key, clicking where something is wrong, leaving a note, and having an agent address
every note in one pass is a pattern already proven for agent-written documents. Here: **press `N`,
click the preview or a lane, and write a note** — "zoom tighter here", "this pause is too
long", "blur this". A note is an **authored** value anchored to what the click hit:

- on the preview: the instant under the playhead, the step it falls in, and a normalised point;
- on the zoom lane: that zoom's click key;
- on the steps lane: that step's origin.

Anchoring to step origins and click keys rather than seconds means a note still points at the
right press after a cut moves everything after it. **"Address the notes"** hands every open
note to the selected provider as one request; each note comes back as zero or more proposals,
each naming the note it answers, and a note stays open until a person resolves it. A note
whose request produced nothing says so, rather than closing silently.

## The review list

*Landed 2026-11-08, stage 3: `Core/Sources/Framing/CutReview.swift`,
`Core/Sources/Compositing/TakeActivityReader.swift`, `Soredemo/Editor/CutProposalsModel.swift`,
`Soredemo/Inspector/CutProposalsPanel.swift`, the Cuts tab in the inspector.*

### How others review a proposed removal

| Approach | How a person decides | What it costs |
| --- | --- | --- |
| a transcript editor's filler-word sidebar | every detection listed with its time, previewable, and each one deleted, replaced by a gap, or ignored; "remove all" beside them | the list says *what* was found, not what bounded it, so a pause cannot be checked without listening |
| a transcript editor's pauses, in a desktop NLE | each pause selectable and deleted, or all at once | editors report that "delete all" ruins pacing and that some pauses are kept on purpose — the bulk path is the risky one |
| a browser silence cutter | one threshold, one pass | no per-item decision at all |
| this project's own silence and stillness buttons | find, look at the lane, then remove all as one undo step | all-or-nothing, and nothing remembers a span a person meant to keep |

**What was combined.** The sidebar's per-item decision, with the bulk action kept beside it as
*one* undo step whose total is on screen before it is pressed. What none of them do, and this
does: **each row says what bounded the span** — "nothing happens for 9.2 s during step 4; after
the pointer stops, until step 5" — so a row can be checked against the recording, and **a "no" is
remembered**, so the next derivation does not offer the same pause again.

### What was decided

- **The list is derived from the edit, every time.** `CutReview.listing` places each proposal on
  the recording's clock and asks the timeline how much of it still plays: `.gone` leaves the list,
  `.partly` stays and says so. Nothing remembers an acceptance — the cut is the record, so ⌘Z on an
  acceptance puts the proposal back by restoring the span.
- **Every proposal goes exactly one way** — listed, already cut, dismissed, or unplaceable (an
  anchor from another boot) — and each way is counted, so the counts sum to the proposals given.
- **A dismissal is an undo step in the same history as the cuts** (`TimelineEdits.dismissedCuts`),
  and it is saved: `EditState.dismissedCutData`, the keys only, in a fixed order so the same
  dismissals are the same bytes. Proposals themselves are re-derived on open, the shape
  `framingOverrideData` already had. This closes the default that stood open below.
- **Every history write goes through one copy-and-replace** (`TimelineEdits.with`), because each
  constructor call that named the parts one by one was a place a new part could be dropped;
  `aCutAfterADismissalKeepsTheDismissal` is the test that it is not.
- **What was heard comes from the transcript when there is one, from the waveform when not.** The
  waveform's non-silent stretches (`SilenceFinder.sounding`) count any sound as something
  happening — music with nobody talking is not dead air — and the panel says which source it
  used, because without a transcript a narrated pause is kept only because it made a sound.
- **Accepting is the one place a proposal becomes a cut**: `CutReview.accepting`, recorded by
  `TimelineEditorModel.acceptCut` under a name that says what it cut ("Cut 9.2s Pause").

## The layers

The user of this document asked for SOLID, MVVM and a clean architecture explicitly; this is
where each sits, and the dependency arrows only point down.

```
SwiftUI views            CutProposalsPanel · AgentPanel · NoteOverlay         (app)
    │ observe
@Observable view models  CutProposalsModel · AgentPanelModel · NotesModel      (app)
    │ call
use cases                CutReview.listing · CutReview.accepting · AddressNotes (pure, in Framing)
    │ depend on protocols
domain                   CutProposal · Note · RecordedStep · EditTimeline      (SoredemoCore, Foundation only)
    ▲ implemented by
adapters                 RuleProposer · OnDeviceModelProvider · CLIAgentProvider ·
                         LocalEndpointProvider · VerbRegistry → CLI front end, MCP front end
```

- **Single responsibility**: a proposer proposes; validation is the proposal's constructor;
  applying is `CutReview.accepting`, and only `TimelineEditorModel.acceptCut` records it.
  (Named `AcceptProposal` in the first draft; it is a pure function in the package rather than
  an app-side use case, so it is tested without the app.)
- **Open / closed**: a new producer or a new provider is a new conformance to `CutProposer` or
  `AgentProvider`; nothing that exists changes. A new verb is one entry in the registry and
  appears in both the CLI and MCP.
- **Liskov**: every provider returns proposals through the same validated constructor, so the
  review list cannot tell — and need not care — which one produced them.
- **Interface segregation**: the read verbs and the propose verb are separate protocols; a
  front end that only reads holds no proposing capability.
- **Dependency inversion**: the domain owns the protocols; the app's adapters implement them.
  `SoredemoCore` keeps importing Foundation only, which architecture rule 1 already enforces at
  build time — this layering is held by the checker, not by convention.

## Order, and where each step becomes observable

| # | Lands | Observable as |
| --- | --- | --- |
| 1 | this document; the landscape update; the ROADMAP rows | — |
| 2 | `CutProposal` and the rule producers, in the package — **dead air landed 2026-11-08** | `swift test`; a fixture take with a known dead span yields exactly that proposal with its evidence |
| 3 | the review list in the editor: each proposal, its evidence, accept / dismiss — **landed 2026-11-08** | a person accepts one and the timeline changes, undoably |
| 4 | the CLI's read verbs and `propose-cut` | a terminal prints a take's steps and its proposals as JSON |
| 5 | MCP over stdio, the same registry | Claude Code lists Soredemo's tools and calls `steps` |
| 6 | the model producer, for a goal | "45 seconds" yields a pending set of step-ranged proposals, each validated |
| 7 | the agent panel, with the on-device provider, then the person's CLI agent | a typed request produces proposals in the review list, marked with their provider |
| 8 | notes pinned on the preview and lanes, and "address the notes" | a note on a pause comes back as a proposal that names it |

Each row is a merge point. Rows 2 and 3 together are the first that a person can see, and the
completion rule holds the ROADMAP row at ◐ until row 3 lands.

Beside this, independent of it: **the release ships as a disk image** (drag to Applications,
the outer image notarised and stapled), and a **Homebrew cask in a tap the owner creates**,
since the official cask repository asks a self-submitted project for 225 stars.

## Alternatives considered

- **Let the agent apply the cut and offer undo.** What the others do. Rejected: it is the one
  thing the thesis forbids, and an undo shown after the fact is a person reviewing a change
  already made — the posture the publishing rule exists to refuse.
- **Proposals keyed to seconds.** Simpler, and every competitor's. Rejected for the reason
  above: a time cannot be checked against the log, and survives a re-derivation only by luck.
- **A cloud model for better goals.** Rejected: nothing leaves the machine unless a person
  sends it, and the on-device model's 4096-token context fits one take's steps.
- **A vector store over transcripts.** Rejected for one take (above); kept open for the library.
- **MCP on `127.0.0.1` over HTTP**, the common choice. Rejected for stdio: no port, no other
  local process can reach it. Revisit if a client that cannot spawn a process needs it.
- **Containerising the build.** Docker images run Linux; ScreenCaptureKit, AppKit and the macOS
  SDK do not exist there, and nothing in this app could be built or tested inside one. The
  reproducibility a container would give is held instead by the CI gate's measured toolchain
  check (`.github/workflows/gates.yml`) and the determinism tests. Not adopted, and the reason
  is written down so that it is a decision rather than an absence.

## Defaults this depends on and has not decided

- The dead-air threshold, the repeated-attempt gap and the pointer-still window: uncalibrated.
- Whether a speed-up is offered at all, or only removal, in the first producer.
- ~~How a pending proposal survives a project being closed.~~ Decided in stage 3: dismissals
  only, re-derived on open (see "The review list").
- The breath kept on each side (0.5 s) and whether a person can change it per recording.
- Which silence threshold stands in for speech when there is no transcript: the toolbar's own
  `silenceSettings`, so the two features agree, and so uncalibrated in the same way.
