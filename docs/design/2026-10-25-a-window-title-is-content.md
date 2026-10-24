# A window's title is content, even through accessibility

2026-10-25. Found while working out whether a step's text can be written from the element a click
pressed (`2026-10-25-beyond-a-screen-recorder.md`).

## The rule, and the way around it

The observation log may carry "instants, normalised coordinates, AX roles, AX titles, frames, and
counts" and never "the contents of a control, the pasteboard, or an enumeration of other
applications' windows" (`noAppSourceReadsUserContent`). Window titles are on the wrong side of
that line, and the code says so in three places: `WindowTarget` shows the application's name and
never the window's title, because "a window title carries whatever is open in it: a document name,
a customer's name, a URL with a token in it"; `kCGWindowName` is banned everywhere; and
`FramingTarget` carries the role and "never the title" for the same reason.

**The accessibility walk reads them anyway.** `AXObserver.describe` reads `kAXTitleAttribute` for
every element in a click's chain, and the chain climbs to the root — through the `AXWindow`, whose
title is the window's title, and in a browser through the `AXWebArea`, whose title is the page's.
So a click on a button in a window named after a customer's invoice wrote the customer's name into
the log, and the log travels inside the `.soredemo` package a person shares. The rule was enforced
on the two APIs that name windows and not on the third route to the same text.

An AX title on a **control** stays: "Export" on a button is the interface's own label, the thing a
step's text is made of, and what the rule permits.

## The decision

`AXObserver` does not read the title of an element whose role makes its title the content it
holds: **`AXWindow` and `AXWebArea`**. The role is read first; for those two the title attribute is
not asked for at all, so the walk is one round trip cheaper per window and nothing is read and
then dropped. The list is `AXObserver.rolesWhoseTitleIsContent`, closed by construction, and a
role added to it is a visible edit.

Not changed, and said here rather than implied:

- **Logs already recorded keep the titles they have.** Nothing rewrites a recording; a project
  shared from before this commit carries them. A "share without the evidence" export (R5 of the
  2026-10-22 audit) is where a scrub of old logs belongs.
- **A browser tab is a control whose label is a page title.** Browsers commonly expose each tab as
  a control titled with its page — **not measured on this machine** — so a click ON a tab would
  record it. That is a control's title by the
  rule's own definition, and changing it would mean judging a title by its text, which is the
  content reading this rule exists to forbid. Left as a known limit.
- Finding a window again for a replayed step (idea 1 of the strategy document) cannot use the
  window's title; it will use the application's bundle identifier and the element path.

## How it is verified

On `ObserverTests`' fake tree: window → group → button, the window titled with a customer's
document name and the button titled "Record". The record keeps "Record" on the button and has no
title on the window; a web area titled with a page title has none either; a control's title inside
both survives. Mutations: the skip removed (the window's title comes back); the button skipped as
well (the control's title is lost).

## Where it ended

As decided. `aWindowsAndAPagesTitlesAreNotRecordedAndAControlsAre` on a four-level fake tree
(window, web area, group, button), red under both mutations: with the skip removed the web area's
title comes back; with controls added to the list the button's "Record" is lost. The walk still
climbs through the window and the page — only their titles are left out — and each costs one
accessibility round trip less.
