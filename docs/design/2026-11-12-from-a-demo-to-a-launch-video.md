# From a demo to a launch video

*Written 2026-11-12, when the owner set the direction: Soredemo records a demo, and from it makes
the videos a product is launched with — a landing-page hero, a launch video, a pitch — with the
agent helping cut and assemble them.*

## The question

Soredemo already makes one good video from one recording: zoomed to what was clicked, the cursor
drawn, the dead air proposed for cutting, captions corrected against what was on screen. A launch
does not need one video. It needs a **set**, each with its own job, and most of them are not a
recording played from start to end. So:

1. What does a team actually ship when it launches, and how is each piece made today?
2. What is the unit Soredemo should produce — a video, or a storyboard that renders to several?
3. What does the agent do, and what must it never do?
4. What is built first, so each step is something a person can use?

## What is shipped, and how it is made

From the 2026 guides (mostly vendors' own, so the shape is the evidence, not the numbers):

| Asset | Length | What it is for | How it is usually made |
| --- | --- | --- | --- |
| Landing-page hero loop | 10–30 s, muted, loops | shows the product working above the fold | screen capture plus motion design; the last frame close to the first |
| Launch video | 30–60 s | Product Hunt, X, the announcement | storyboard → capture → edit with title cards, music, a call to action |
| Pitch / walkthrough | 1–3 min | investors, sales, onboarding | narrated recording, captions, chapters |
| Social cut-downs | 6–20 s, 9:16 and 1:1 | ads and posts | re-framed pieces of the launch video |

Two points recur across sources and matter here. **Buyers discount what they cannot see working**,
so a launch video should show at least one real workflow in the real interface. And the
generative tools are told **not to invent UI or fake product behaviour**. Soredemo's evidence is the
one thing generated footage cannot have.

**Video written as code** (a framework read for ideas, not code) is how the developer-led teams make these: a video is a
function of the frame number and some props, scenes are sequences on a timeline, a template is a
composition with props (copy, brand, media), and the agent writes the composition. Its agent skills
are mostly **design rules written down** — decide what the viewer notices first in each scene; keep
key text inside a safe area; a headline is at least 84 px on a 1080-wide frame. What Soredemo takes
from that: templates as data with props; design rules as checks rather than taste; and an agent
that edits a structured description rather than pixels. What it does not take: React, a
browser renderer, or a second compositor. Soredemo's preview and export are already one
deterministic compositor, and a second rendering path would let them disagree.

## Decided

**0. A library first, and the agent picks from it.** *Added the same day, from the owner: "more
like the agent-driven editors — a library the agent picks from and cuts."* A launch video is assembled from many
short takes, screenshots and clips, not cut from one recording. So the ground is a **library**:
every recording, screenshot, clip, logo and piece of music the person has, each indexed by what it
contains. The editor that lets an agent pick from media is the open-source editor's idea; what
Soredemo indexes is its own.

| Item | Indexed by |
| --- | --- |
| recording | its steps (label, role, application, span), the transcript by word with times, the words that were on screen, the notes pinned on it, the cuts already proposed |
| screenshot | its size, the application and window it came from when Soredemo took it, the text on it |
| clip | duration, size, its transcript when it has speech |
| brand asset | its kind: logo, colour, typeface, music |

**The index is built from the observation log, not from a model looking at frames.** A search for
"where they export" returns *recording 3, step 7, "Export…" pressed in Keynote, 41.2–44.9 s* —
a span that exists, with the evidence that it is the right one. That is the difference from tools
that caption pixels, and it is what makes "the agent cannot invent footage" enforceable: the agent
can only place what a search returned.

The agent's first tools are therefore **`search_library`** (query → spans, each with its evidence)
and **`library_item`** (one item's steps, transcript and words), before any storyboard tool.

**1. The unit is a storyboard, and a deliverable is a storyboard rendered at a shape.** A
storyboard is an ordered list of scenes. A deliverable — *hero loop 16:9*, *launch 16:9*,
*launch 9:16*, *pitch 16:9* — is the storyboard with a length budget, an aspect, and rules (a
hero loop is muted and loops; a launch ends on a call to action). One storyboard, several exports,
and a change to a scene reaches every one of them.

**2. Five kinds of scene, each naming what it rests on.**

| Scene | Content | Evidence |
| --- | --- | --- |
| recording | a span of a recording, framed as today | the steps it covers, by number |
| screenshot | a still, with a slow push toward a point | the file, and the point if a person chose it |
| clip | an imported video span | the file |
| statement | a headline and a line under it, on the brand background | the person's words, or the agent's marked as a proposal |
| end card | logo, call to action, URL | the brand kit |

A recording scene that covers steps 3–5 can say so, and the story's beats can be checked against
it. That is "two derivations that disagree must say so", applied to a script.

**3. A brand kit, set once.** Logo, two colours, a typeface, a call to action and its URL. Every
statement and end card reads it, so a launch video and its cut-downs agree without being styled
twice.

**4. The agent drafts the storyboard; the person approves the words.** From the steps, the notes
and a one-line pitch, the agent proposes the scenes, the order, the lengths and the copy. Footage
choices it may make directly, each a named, revertible step as today. **Copy it writes is a
proposal until a person accepts it**, because a headline is a claim about the product made in the
person's name. **The agent cannot invent footage**: every recording scene is a span that exists.

**5. Design rules are checks, with the numbers.** A headline under the minimum size, text outside
the safe area, a scene with two focal points, a hero loop whose last frame does not match its
first: each is a diagnostic the agent reads and the person sees, phrased with the measurement.

**6. Publishing is still a person's act.** Rendering a deliverable to a file is an export. Nothing
is posted anywhere (AGENTS.md, "The publishing rule").

## In what order

1. **The library**: recordings already in it; screenshots and clips imported into it; the index
   over all of them; `search_library` and `library_item` for the agent. Without it there is
   nothing but one recording to tell a story with.
2. **The storyboard and the statement and end-card scenes**, with the brand kit; one deliverable
   (launch, 16:9). Rendered by the existing compositor.
3. **Deliverables**: hero loop, 9:16 and 1:1 cut-downs from the same storyboard.
4. **The agent's storyboard tools** — read the story, add, move, trim, replace a scene, propose copy
   — on the `ToolSpec` declarations, with the design checks as their diagnostics.

## Alternatives not taken

- **Generate the footage.** It is what the generative tools sell, and it is what the guides warn
  against for the part that matters: a product shown doing what it does not do.
- **Embed a video-as-code framework.** A JavaScript runtime and a browser renderer inside a native app, a dependency
  rule 4 does not admit, and a second compositor the preview would disagree with.
- **Templates as fixed videos.** A template here is a storyboard with props, so the agent and the
  person edit the same structure.
