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
Soredemo cli steps demo.soredemo --json`, newline-delimited JSON when asked — and **an MCP
server over stdio** started by the same executable. stdio rather than a listening socket: a
port on `127.0.0.1` is reachable by every process on the machine, while a stdio server is
reachable only by the client that started it. The ROADMAP's `mcp-server` row said `NWListener`;
that changes here, for that reason.

**What no front end can do, ever:** accept a proposal, apply an edit without a person seeing it
in the editor, or publish. Accepting happens in the editor's review list, by a person. This is
`agent-review-tools`' "review posture, not generative" made into the type of the registry: there
is no accept verb to call.

**No argument-parsing dependency.** The `cli-surface` row named Swift Argument Parser.
Architecture rule 4 held every manifest at zero dependencies when this was written (since 2026-11-08 it admits official, pinned ones; none is used), the README advertises zero, and
the verbs above are five with a handful of flags each. A small hand-written parser in the app
target, tested like any other code, costs less than the rule it would break. The row is
corrected in the same commit as this document.

**Text from outside is data.** A proposal's goal and an agent's arguments are attacker-
controllable (`agentic-threat-model`): they are quoted into the model's prompt as data under a
fixed instruction, never concatenated into it, and nothing they say can widen what a verb does.

### The CLI, as built (stage 4, 2026-11-08)

*`Core/Sources/Surface/` (the verbs, pure over `ProjectReading`), `Core/Sources/Compositing/
PackageProjectReader.swift` (the package and the audio), `Soredemo/App/CommandLineSurface.swift`
(the entry point).*

**How others shape an agent-facing CLI, and what was taken.** Command-line guidelines and the
2026 write-ups on CLIs driven by agents agree on a handful of things: a global `--json`; results
on stdout and diagnostics on stderr; non-zero exits that say *what* failed rather than only that
something did; one envelope shape for every command, carrying a schema version; and a way for a
caller to list what exists. Two screen recorders' own CLIs do the same, and both also *write* —
record, export, upload, change a project's configuration. **This one takes the shape and refuses
the writes**, and says so in the listing an agent reads first.

- **`cli`, not `cut`.** The first word was `cut` in the draft above; it read as a verb and would
  have made `cut status` mean nothing. `cli` is a word no launch flag can collide with.
- **One envelope**, `{schemaVersion, verb, ok, result | error}`, one line, keys sorted so two runs
  are byte-comparable. In `--json` mode even a call that failed to parse answers in it.
- **Exit statuses from `sysexits(3)`**: 64 called wrongly, 65 the log is missing or unreadable,
  66 the project cannot be opened.
- **A write verb is refused by name.** `accept`, `apply`, `publish` and their neighbours do not
  merely fail as unknown: the message says that a person does that, in the editor — the
  difference between an agent that stops and one that retries with a different spelling.
- **The log is found by its header's join field** (`ProjectPackageIO.observationLog(forMedia:)`),
  not by the writer's naming convention, and **its length comes from its trailer**: no media is
  decoded to answer `status` or `steps`, and a log with no trailer — a recording that crashed —
  is refused rather than given a length. The editor reads the length from the media; `status`
  says which one it used.
- **What was heard** comes from the media's waveform through `SilenceFinder.sounding(peaks:…)`,
  the one function the editor's Cuts tab also calls. Writing that function found a defect in
  stage 3: a recording with no audio track had an empty waveform, which the complement of "no
  silences" read as sound throughout, hiding every proposal. It now says nothing was heard.
- **`export` is not built yet.** It is the one verb that renders, and it waits for stage 5's need
  for it; `cli-surface` stays ◐ until it lands.

### The MCP server, as built (stage 5, 2026-11-08)

*`Core/Sources/Surface/MCPServer.swift`; the stdio loop in `Soredemo/App/CommandLineSurface.swift`,
started as `Soredemo mcp`.*

**How others serve one, and what was taken.** Three comparable recorders ship an MCP server.
One serves over stdio *and* inside the app, annotates every tool with `readOnlyHint` /
`destructiveHint` / `openWorldHint`, and hands the agent a block of server `instructions`; both
were taken. One gates its writes behind a `confirmed: true` argument — which the agent itself
can set, so the gate keeps out nothing an agent would not walk through; this has no writes to
gate. One listens on a local port over HTTP with sessions, the design this document already
turned down for the reason above. The protocol is the 2025-11-25 revision, read from the
specification rather than from an SDK.

- **No SDK; one message in, at most one out.** The server answers `initialize` (agreeing the
  client's version when it is one of three it knows, offering the newest otherwise), `ping`,
  `tools/list` and `tools/call`, and never answers a notification. It is a value type mapping a
  line to a reply, so every rule is a unit test; the loop that reads stdin is twelve lines.
- **The tools are the registry's verbs**, run through `SurfaceCommand.answer` — the function the
  terminal calls — so `propose_cut` and `cli propose-cut --json` are tested to return the same
  object. `verbs` is not a tool: `tools/list` is that listing.
- **Every tool is annotated read-only, non-destructive, idempotent and closed-world**, and the
  annotations are true because no verb writes, not because a hint says so.
- **The two kinds of error the specification separates, kept separate**: an unknown tool or a
  malformed request is a JSON-RPC error; a missing `project`, an unexpected argument or a
  project with no log is a tool result with `isError`, which the model reads and can correct.
  A tool name that sounds like a write — `accept_cut` — is refused saying who accepts instead.
- **stdout carries replies only**, one line each with no embedded newline, as stdio framing
  requires; the one log line goes to stderr. A client closing stdin ends the process.

## The agent panel: bring the agent you already use

A panel in the editor where a person types what they want — "cut this to 45 seconds", "why is
step 6 not zoomed" — and the agent they already use does it, **in the editor, while they watch**.
*Redesigned 2026-11-08 by the owner's decision: the agent edits directly.* The first draft of this
section let an agent only propose; that is kept for every agent the person is not watching (the
terminal CLI, an outside MCP client), and dropped for the one they are.

### How others design it, and what was taken

| Product | How the agent is connected | Who edits | How a change is taken back |
| --- | --- | --- | --- |
| a slide framework built for agents | drives the person's installed Claude Code or Codex under their own login; the current slide and selection go with every message, in escaped tags | the agent, inside the deck's folders; anything else asks | provider checkpoints, rewind |
| an agentic video editor (native macOS) | in-app agent with the person's own API keys or the vendor's cloud; @-mentions frozen into sorted JSON at send time | the agent, on the timeline; every tool returns a delta of what moved | undo |
| a transcript-based editor's agent | built in, plus MCP | the agent | **a checkpoint before each response, and "Revert" under it**; undo; version history |
| a cloud recorder's agent | built in, plus a hosted MCP | the agent, "while you watch" | — |
| a design tool's assistant | select an element, then "Ask"; the selection is the context | the agent, on the canvas | continue in chat or edit by hand |
| a coding agent's desktop app | modes chosen per session: plan, ask, accept edits | the agent, by mode | diff review per file before commit |
| an edge platform's agent toolkit | per-tool: runs, or waits for a confirmation the UI renders | the agent, gated per tool | — |

Agent-UX write-ups of 2026 converge on the same few things: stream tool calls with their
arguments and collapse them when done; keep a visible **Stop** that says what stopping leaves;
show the work as a trace that stays inspectable, not a spinner; put a checkpoint before anything
lasting.

**What was taken.** The connection — the person's own CLI, their login, no key in Soredemo. The
selection as context. The per-response checkpoint and Revert. Streamed, collapsing tool rows and a
Stop that says what it leaves. **What only Soredemo adds:** every edit names the step or proposal it
rests on, so a cut can be checked against the observation log rather than trusted as a number.

### How it works

1. **The app starts the person's `claude`** headless — `-p`, `--output-format stream-json`,
   `--include-partial-messages`, `--strict-mcp-config` with Soredemo's server only, and
   `--tools ""` so none of the agent's built-in tools (shell, file edits, web) exist in the session.
   Measured 2026-11-08 against Claude Code 2.1.318: `init` listed exactly the four Soredemo tools,
   one tool call and one answer took five seconds.
2. **The tools run in the editor, not on the saved file.** The MCP server the agent starts is
   `Soredemo mcp --relay <socket>`, a pipe to the running app over a Unix socket in a directory
   only this user can open; the app answers with the live timeline, so the agent reads what the
   person sees, including its own last cut. Run without `--relay` it is the read-only server above.
3. **The edit tools** — cut a span, cut a step, accept a rule's proposal, move the playhead — each
   record one undo step named for the agent and its reason ("Claude: cut 9.2s — nothing happens
   after step 4"), and return what changed: the span, the new length, the step it touched.
4. **Each turn is checkpointed.** "Revert this turn" undoes back to the history position the
   turn started at, as long as nothing else was edited since; otherwise it says so.
5. **Each message carries what is on screen**: the playhead, its step, the selected proposal or
   note — in tagged, escaped blocks, as data. Never the video or a frame.
6. **Stop** ends the process; cuts already made stay and are revertible, and the button says so.

**Publishing is not a tool**, here or anywhere. The relay gives the agent the editor; it does not
give it a share button, and there is none to give.

| Provider | Where it runs | What leaves the Mac |
| --- | --- | --- |
| the person's own Claude Code (first) | their CLI, under **their** login | what that agent sends its provider, which is the person's existing arrangement; the panel says so before the first message |
| the person's Codex (next) | `codex exec --json`, same relay | the same |
| the on-device model | `SystemLanguageModel.default` | nothing |

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

### Notes, as built (stage 8, 2026-11-08)

*`Core/Sources/Framing/PinnedNotes.swift`; `Soredemo/Editor/NotesModel.swift` and `NoteLayer.swift`;
the notes bar and cards in `Soredemo/Agent/AgentPanel.swift`.*

**How others do it, and what was taken.** A slide framework's comment mode — press a key, click an
element or drag a region, write a note, and have an agent apply every note in one pass, deleting
each marker it applied and leaving any it skipped, with why. A review tool for video pins a
comment to the paused frame, optionally stretches it over a range, lets the reviewer draw on the
frame, and shows the comments on the player bar. **Taken**: the key, the click on the picture,
one pass by the agent, and an answer for every note — done, or left with a reason.

**What differs from the plan above, and why.**

- **Pinned on the preview only, for now.** A note on the zoom or steps lane is not built; the
  preview carries a time and a point, which is what every note so far has needed.
- **The note stores its time on the recording's clock and its point on the picture**; the step it
  falls in is derived when it is read (`NoteBoard.anchored`), never stored, so it follows the
  steps if they are re-derived — the producer-value rule, with the note as the authored half.
- **The agent resolves a note, with what it did, or leaves it open with why** (`resolve_note`,
  `skip_note`), because the panel's agent edits directly (stage 7): a note is answered by the edit
  it asked for, not by a proposal. A resolved note is greyed, keeps its answer, and a person can
  reopen it. A note the agent never answered stays open.
- **Notes are saved with the project** (`EditState.notesData`), through a validating decoder: an
  empty note, a negative time or a point off the picture in a file is refused by name.

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

## Cutting to a goal

*Stage 6's core, 2026-11-08: `Core/Sources/Framing/GoalCut.swift`. The on-device model's half —
the prompt and `@Generable` answer — is the next step.*

**How others approach it.** Tutorial-video research finds that a raw demonstration's redundant
and irrelevant actions must be filtered into key steps, and that handing a long action sequence
straight to a model yields over-granular, noisy results; a practitioner rule of thumb is three to
seven steps. An auto-editing agent's own instructions order cuts as dead air first, then fillers,
false starts and repeated beats — and remind it to re-read after each cut, because indices shift.
Idle-time trimming alone took one published recording from 2:59 to 1:01.

**What was decided: the model judges, the code measures.** A language model is asked only what
it is good at — which steps a stated goal does not need, least needed first, with a sentence each.
Nothing it is bad at: no times, no lengths, no arithmetic.

1. Dead air first: if the rules' proposals already reach the target, no step is proposed.
2. Then whole steps in the model's order, each removed from a second before its press to a second
   before the next press (never back past the previous press), until the projected length meets
   the target.
3. Never a step the model called necessary, never one a person kept; a target still out of reach
   is reported as a shortfall in seconds rather than met by cutting further.
4. Every verdict is checked: a step that does not exist, a second verdict on one step, and a cut
   with no reason are refused by name; a step the model said nothing about is kept and listed.

Indices cannot shift under it, because a proposal is keyed to the log's instants, not to a
position in the edit.

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
| 4 | the CLI's read verbs and `propose-cut` — **landed 2026-11-08, `export` still to come** | a terminal prints a take's steps and its proposals as JSON |
| 5 | MCP over stdio, the same registry — **landed 2026-11-08** | Claude Code lists Soredemo's tools and calls `steps` |
| 6 | the model producer, for a goal — **its planning core landed 2026-11-08; the model's half is next** | "45 seconds" yields a pending set of step-ranged proposals, each validated |
| 7 | the agent panel driving the person's Claude Code, editing the live timeline (redesigned 2026-11-08) | a typed request cuts the timeline while the person watches; each cut is one named undo step and the turn reverts at once |
| 8 | notes pinned on the preview, and "address the notes" — **landed 2026-11-08, preview only** | a note on a pause is answered by the cut it asked for, or left open with why |

Each row is a merge point. Rows 2 and 3 together are the first that a person can see, and the
completion rule holds the ROADMAP row at ◐ until row 3 lands.

Beside this, independent of it: **the release ships as a disk image** (drag to Applications,
the outer image notarised and stapled), and a **Homebrew cask in a tap the owner creates**,
since the official cask repository asks a self-submitted project for 225 stars.

## Alternatives considered

- **Let the agent apply the cut and offer undo.** Rejected in the first draft as the thing the
  thesis forbade; **adopted 2026-11-08 by the owner** for the agent a person is watching in the
  panel, after reading that every agent-driven editor of 2026 edits directly. The objection —
  that an undo after the fact is review after the fact — is answered by naming every edit for its
  agent and reason, checkpointing each turn, and keeping the terminal and outside MCP clients,
  which nobody is watching, read-only.
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
