# Notice

Soredemo — Copyright © 2026 Soredemo.

Soredemo is free software under the **MIT License** (`LICENSE`). Everything in this tree was written
for it.

---

## What is not Soredemo's

- **Two marks** — the Claude and OpenAI symbols the Agent tab shows beside the agent a person has
  chosen. Where each came from and on what terms is in `docs/third-party-marks.md`.
- **Apple's frameworks**, which the app links and does not include.

There are no third-party packages; architecture rule 4 admits a pinned dependency only from Apple,
the Swift project or the Model Context Protocol project, and there are none today.

## Code from elsewhere

**None, and a file that ports or adapts another project's code cannot be added.** Renaming the
variables of somebody else's function does not make it this project's: it stays theirs, under their
licence, and some licences are copyleft — a line derived from one would make the licence at the root
false.

Other software may be read to understand a problem; the solution is written here. It has gone wrong
once, and was found by a scan rather than by anyone remembering: on 2026-11-11 a caption
line-breaking routine and a spring step were found to follow other programs' code line for line,
and both were rewritten from specifications by an agent that had read neither
(`docs/design/2026-11-11-caption-line-breaking.md`). `scripts/scan-for-borrowed-code.py` is that
scan, and it runs before a phase merges.

Facts are not code: a published bit rate, a measured threshold or a physical formula is used where
it is the right number, and the reasoning for it is recorded beside it.

**Not legal advice.** This file is what the code says. Anyone whose plans depend on the answer
should have a lawyer read it.

---

## Applying the licence to new files

Contributors do not need a per-file header: the `LICENSE` at the root covers the whole work.
