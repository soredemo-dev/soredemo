# The library: what a project holds, and how the agent finds it

*Written 2026-11-13, the first stage of `2026-11-12-from-a-demo-to-a-launch-video.md`. That
document decided a library comes first and the agent searches it; this one decides what the
library is, where it lives, what is indexed and what the agent may do with it.*

## The question

A launch video is assembled from a recording, a few more takes, screenshots, a logo and a clip or
two. Today a project holds one recording and nothing else the agent can find. So:

1. Where does the library live — beside each project, or across all of them?
2. What is an item, and what is kept about it?
3. What is searched, and what does a hit carry?
4. Who puts things in?

## Decided

**1. One library per project, inside its package.** A project is the launch video; what it is
made of travels with it, as the backgrounds, pictures and fonts already do. A library across all
projects is the later step — it needs a home outside any package, and the per-project one is what
it would be built from. The folder is `library/`; the list is `library/library.json`.

**2. An item is a file and what is known of it.** Kind (`recording`, `video`, `image`, `audio`), a
safe file name, the name a person sees, its size and length when it has them, and **where it came
from** — recorded here, imported by the person (with the original name), or brought from the web by
the agent (with the host). Ids are a counter the list keeps, not random: the core is deterministic.
The list has a version and a hand-written decoder that refuses an unsafe name, a negative length and
an id at or above the counter — a package is a shareable document, and its list is untrusted input.

**3. The index is what was observed, and what was read off a picture.** For the project's own
recording: each step's label and application with its span, and the captions' words with their
times. For a picture: its name, and the text on it read by on-device text recognition when it was
imported, kept in the list and marked as derived, with the recognizer's revision, so a better
recognizer can redo it. A video clip: its name and, once transcribed, its words. **A hit carries
its evidence** — which item, which field, the span when there is one — so the agent places
what exists and can say why it chose it.

**4. A person puts things in; the agent brings pictures from the web.** Import is the person's —
a button and a drop target — because an agent naming a path would be an agent reading the person's
disk. The agent adds to the library only through `import_image`, whose checks are
`2026-11-13-the-agent-may-search-the-web.md`'s.

**5. The agent's tools.** `library` lists the items. `search_library` takes words and returns hits
with evidence, best first. Using an item in the video — a clip on the timeline, a screenshot as a
scene — is the next stage, the storyboard's, because the composition still has one source.

## Alternatives not taken

- **A library across all projects first.** It would need a place outside any package and a rule
  for what happens when a project moves; the per-project library answers the immediate need.
- **Index pictures with an image-embedding model.** It needs a model download and searches by
  likeness rather than by what was observed. Text on a screenshot is most of what a demo's
  screenshot is searched for, and it is read on device with no download.
- **Let the agent import any path.** Above.
