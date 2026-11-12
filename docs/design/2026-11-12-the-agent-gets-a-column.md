# The agent gets a column

*Written 2026-11-12, after the owner said the agent should not be "a small button on the right",
and asked for the layout to learn from the agent-driven editors.*

## The question

The agent panel was one of nine icons in the inspector's rail, the same size as Hide and Mark, in a
column 300–400 points wide that it shared with whatever else the person had open. Opening Captions
to check a line closed the conversation that was fixing it. That is the wrong weight for the
feature the 2026-11-08 document made the product's centre — an agent the person chose, editing
while they watch — and the wrong place, because the inspector is for *one thing at a time* and a
conversation runs beside everything else.

So: where does the conversation live, how big is it, and what does it know how to point at?

## What the comparable editors do

Read for ideas, not code (AGENTS.md, "Reading other people's code").

| Product | Where the conversation is | What it points at |
| --- | --- | --- |
| an open-source macOS editor built for agents | its own **full-height column on the left**, collapsible, resizable within a minimum and maximum; media, preview and inspector to its right, the timeline under those and not under the chat | `@` in the composer opens a picker of the project's media |
| a transcript-first editor's co-editor | a chat window beside the transcript, with the common actions in a separate tools panel | the transcript |
| coding-agent desktops (agent view / editor view) | two layouts: one where the conversation takes the window and the editor hides, one where the conversation is a side panel | files, diffs; review stays in the editor |

What they agree on: **the conversation is a peer of the preview, not a section of the inspector**,
and it stays open while the rest of the window changes. What is still argued: whether the record of
what changed belongs in the chat or in the editor. Soredemo already answers that one — every edit
is a card in the turn *and* a named undo step in the editor, and a whole turn reverts.

## Decided

**1. A column of its own, on the left, full height.** The conversation sits to the left of the
preview and the timeline; the inspector stays on the right. Left because the inspector already owns
the right edge, and because the order then reads as the work does — what was asked, what it looks
like, what it is made of. It is resizable (300–560 points, remembered) and collapsible from the
toolbar and with ⌥⌘A, and its open state is remembered. **The Agent tab leaves the inspector rail.**

**2. Collapsing it does not stop it.** A running turn keeps running with the column closed;
`AgentPresence` over the picture already says who is editing and what it is doing, so the person
can watch the picture at full width and still see the agent work.

**3. The starters say what it can do now.** Captions joined the tools on 2026-11-12, so "Fix the
names in the captions" joins the starters, and the welcome text says it can fix captions as well as
cut.

## Next, and why not in this pass

- **`@` points at the observation log**, not at media: `@step 3`, `@line 12`, `@note 2`. The other
  editors point at files because files are what they have; Soredemo has steps, lines and notes,
  each with an id the tools already take. The context block already carries the playhead's step,
  escaped, so a mention is the same mechanism made explicit.
- **The turn's edits drawn on the timeline**: a mark at each place the current conversation cut or
  fixed a line, so "what did it change" is answered where the edit is, not only in the chat.

Both need the column first, and both are a view over data that exists.

## Alternatives not taken

- **A floating window.** It survives the inspector changing, but it is a second window to place and
  lose, and the agent edits *this* window's recording.
- **A full "agent view" that hides the timeline.** It suits a coding agent, whose output is read as
  text. A video edit is judged by watching it, so the picture never leaves.
- **Leave it in the rail and widen the inspector.** It would still close whenever another tab opens,
  which is the actual complaint.
