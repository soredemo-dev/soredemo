# The landscape, October 2026

Researched 2026-10-25. **This is the one competitor document.** It replaces
`docs/research/competitors.md` and the five overlapping studies in `docs/design/`
(`2026-08-23-five-project-feature-sweep`, `2026-08-23-editor-inventory`,
`2026-08-25-design-audit`, `2026-08-26-feature-gap`, `2026-08-30-what-the-market-ships`), whose
rows had gone stale: half the "absent" column of the August gap list has since shipped here —
screenshots, phones, annotations, hidden desktop icons, chapters, manual zoom. Their history is in
git; what still holds is below. Redo this document rather than adding a second one.

**Sources are the vendors' own pages unless a row says otherwise**, and many "alternatives"
round-ups are written by a competitor, so a ranking from one is not evidence. The Soredemo column
was checked against the code on the same day, not against `FEATURES.md`.

## Who is in the market

Four kinds of product get compared with this one, and only the first is the same job.

| Kind | Products | What they are for | Where they overlap |
| --- | --- | --- | --- |
| **Polished demo recorders** — auto-zoom, drawn cursor, backgrounds | Screen Studio, ScreenKite, Screen Charm, FocuSee, Cursorful, Prequel, CursorClip, Rekort, Smooth Recorder, Lumiko, Retina; and several free, open-source recorders | a product demo or tutorial that looks edited when recording stops | everything |
| **Editors that record** | Camtasia, ScreenFlow, Descript, Tella | a long tutorial cut on a full timeline; Descript and Tella edit by transcript | the timeline, transcript editing, export |
| **Async video messages** | Loom, Vidyard, Screencastify, ScreenPal, Zoom clips | a quick message with a share link and viewer analytics | share links — which Soredemo deliberately does not do (AGENTS.md, the publishing rule) |
| **Capture utilities** | CleanShot X, Snagit, QuickTime, an open-source streaming studio, ShareX, Bandicam, FlashBack, Icecream, Movavi, Clipchamp | screenshots, raw recordings, streaming | screenshot mode and raw capture only |

**Free products doing the same job exist and are getting better.** One is MIT-licensed, free
for commercial use and widely recommended as the free pick; another has a free tier; Retina is
free in beta; several newer open projects, one of them native Swift, ship auto-zoom, a timeline,
captions and platform export presets. So "free" alone does not set Soredemo apart. What does is
the observation log (below).

## What shipped recently

| Product | Recent release | What is new |
| --- | --- | --- |
| Screen Studio | 4.0, 2 Oct 2026 | glass loupe (a lens magnifies one detail while the rest stays in view); camera cut out of its background (beta), face tracking, "hide during silence"; camera colour grading, 12 looks and LUTs; **edit by transcript** — delete sentences, remove detected filler words, shorten pauses; split-screen layouts (side by side, stacked for vertical); sharper zoomed text from an on-device model; exports up to 3× faster; key presses drawn as keys; redesigned click ripple; caption fonts and animations; project sharing link (beta); a scan that masks e-mails, card numbers and API keys in every frame. Roadmap: on-device voice enhancement. 4.0 projects do not open in 3.x |
| ScreenKite | 1.14–1.16, summer–autumn 2026 | on-device transcription; noise reduction suite; an AI editing agent that asks before changing anything; scene transitions; teleprompter; cursor style themes; per-track audio placement; multi-language audio tracks with subtitle sidecars; 120/144 fps capture; the editor opens on the display where recording stopped |
| an open-source recorder | its 0.6 desktop release, Aug–Sep 2026 | rebuilt editor with a crop tool and inspector; **export screen that shows estimated file size and export time**; record straight into an open project; 3D scenes and animated text; split-screen editing (0.5.1); recording recovery |
| Prequel | 2026 | zoom on clicks **and typing**, softening the rest of the window; camera recorded separately with ten layouts switchable mid-take; teleprompter that follows the voice; separate mic and system tracks with their own gain; MP4/GIF to 4K 120 fps |
| CursorClip | 2.0, 2026 | layouts, motion blur, keyboard-shortcut overlay (keystrokes opt-in), click ripples; teleprompter; cut/trim, speed, undo. Says itself it has no transcription, captions or noise removal |
| Lumiko, Smooth Recorder, Rekort | 2026 launches | auto zoom-and-pan from the cursor with no keyframes, every zoom overridable; local only |
| Open recorders (several) | 2026 | platform export presets (YouTube, X, TikTok, Instagram, Discord, ProRes, GIF); camera regions on the timeline (full screen, hidden, positioned) with transitions; a spotlight that dims everything away from the cursor; click sounds; a cursor-follow zoom mode |

## Where Soredemo stands, feature by feature

● has it · ◐ partly · ○ does not. Checked in the code on 2026-10-25.

| Feature | Market | Soredemo |
| --- | --- | --- |
| Auto-zoom on clicks | everyone | ● — and every zoom says which click it came from, and why a click was *not* zoomed to |
| Zoom on typing, scrolling, dragging | Prequel (typing) | ○ — the log separates them already (`2026-10-22-what-macos-27-makes-possible.md`, idea 6) |
| Manual zoom, move, resize, undo | most | ● — undo since 2026-10-23 |
| Visible ease-in / hold / ease-out on a zoom block | open recorders | ○ — the block is one rectangle; its easing is invisible on the timeline |
| Cursor-follow zoom mode | open recorders | ○ |
| Loupe — magnify one detail without zooming the frame | Screen Studio 4 | ○ |
| Spotlight — dim away from the cursor | open recorders | ○ |
| Click ripple / click sound | most / open recorders | ● ripple (`CursorOverride`) · ○ sound |
| Keys drawn on screen | Screen Studio 4, CursorClip | ○ — keystroke **text** is banned by architecture (`noAppSourceReadsKeystrokeText`); a shortcut overlay from key codes and modifiers stays legal |
| Motion blur | most | ● |
| Camera background removal | Screen Studio 4 (beta), open recorders | ● |
| Camera face tracking | Screen Studio 4 | ○ — `2026-10-23-a-camera-that-reads-the-presenter.md` designs it |
| Camera colour looks / LUTs | Screen Studio 4 | ○ |
| Camera layouts, switch per segment | Prequel, open recorders | ◐ — position and size; no per-segment layout regions |
| Split screen, stacked for vertical | Screen Studio 4, an open-source recorder | ○ |
| Edit by transcript | Screen Studio 4, Descript, Tella | ● sentences and words |
| Filler words detected and removed | Screen Studio 4 | ◐ removable by hand, word by word; not detected |
| Shorten pauses | Screen Studio 4 | ● silence finding and removal |
| On-device captions | most | ● |
| Mask sensitive text automatically | Screen Studio 4 | ○ — manual redaction; Soredemo can do better (the log knows a click on a secure field) |
| Teleprompter | ScreenKite, Prequel, CursorClip | ○ |
| Export presets by platform | open recorders | ◐ — three by destination (web, person, editor), not by platform |
| Export shows size AND time estimate | an open-source recorder | ● — both, the time from this Mac's measured encoder rate (2026-10-26, `ca4a19a`) |
| Export stages and "show in Finder" | most | ● show in Finder; ◐ stages |
| Faster export | Screen Studio 4 (3×) | not measured against them |
| Share link | Loom, Screen Studio (beta) | **○ by rule** — nothing leaves the machine without a person sending it |
| Interactive walkthrough export | interactive-demo tools, per seat | design written (`2026-10-23-interactive-walkthrough-export.md`) |
| Save the last 15 seconds | nobody | ● |
| Chapters from the recording | an open-source recorder (AI) | ● on device |
| A crash does not cost the take | an open-source recorder (recovery) | ● |
| Why a zoom happened, reviewable | **nobody** | ● — the observation log; the product's thesis |

## What to take from it

Ranked by what a viewer of the finished video notices, and by what only Soredemo can do.

1. **Zoom you can read and shape on the timeline.** Show each block's ease-in, hold and
   ease-out; let either edge be dragged while the easing keeps its length; snap edges to cuts
   without changing a moved block's length; refuse an overlap rather than nesting. Every
   competitor's zoom editing is converging on this, and Soredemo's zoom is the product's centre.
2. **Zoom that knows what the person was doing.** Typing, scrolling and dragging framed
   differently from a click — the one competitor doing typing does it from pixels; Soredemo has
   the accessibility element.
3. **Masking that proposes itself** — from the log (a click on a secure field) and on-device text
   recognition, each with its reason, accepted by a person. Screen Studio 4 scans pixels only.
4. **An export screen that says what it will cost** — size and time before pressing, named stages
   while running, and platform presets that set the four controls the destination presets already
   do.
5. **The camera as a layout** — per-segment regions (full screen, hidden, corner) with
   transitions, and split screen stacked for vertical exports.
6. **Keys drawn as keys**, from key codes and modifiers only — the privacy rule stands.
7. **Loupe and spotlight** — two ways to point at a detail without a full zoom.

Not taken: share links (the publishing rule), cloud workspaces, an AI agent that edits without
asking (automation proposes; the person decides — an on-device assistant that proposes is idea 7
of `2026-10-22-what-macos-27-makes-possible.md`).

## The adjacent field: agents, YC and Product Hunt (2026-10-27)

Asked for by the owner: what YC's 2025–26 batches and Product Hunt's launches suggest, to go past
the recorders rather than match them. Sources at the end of this section.

| Signal | Who | What it means here |
| --- | --- | --- |
| **Agentic editing — "vibe editing"** | Cardboard (YC W26; W26's most-upvoted Hacker News launch): footage plus a goal ("3 variants", "30 s hook", "60 s recap") → a first cut, then a timeline. An open-source recorder's second version (11 Oct 2026): an agent edits the recording over MCP. A Mac recorder edited through Claude Code. Wideframe (YC W26): a local agent that organises and sequences footage | an agent that edits is becoming ordinary. What none of them has is evidence: they cut from pixels and words. An agent working from Soredemo's log can say why each cut is there, and a person accepts each |
| **Product videos that re-record themselves** | Clueso Agents (YC): logs into a web product, records the flows, and with GitHub connected flags videos a UI change made stale and regenerates them — one customer's redesign left ~700 out of date. Redemo re-films opted-in videos after a release; Demosmith does not | **corrects `2026-10-25-beyond-a-screen-recorder.md`**, which called idea 1 unclaimed. It is claimed — **for web products**, through a browser. Native Mac applications have no such tool; Soredemo's log is accessibility-based and works in any Mac application |
| Personalised and live demos | Amorphic Labs (YC): an agent records a demo per prospect; Karumi (YC): a live agent that drives the product in front of a buyer | sales tooling with share links — outside the publishing rule; noted, not followed |
| Recording → video **and** written guide | Clueso (YC), Trupeer ($3M seed, July 2025): both at about $40 a month; Arcade's Creator Studio | proven demand for what `GuideExport` already does locally |
| The screen as context for agents | a YC S26 company recording the screen and serving it to agents over an API and MCP | the log is that context without the pixels or the text — what was pressed, in which application, why it was not zoomed |
| Recorders keep launching | Smooth Recorder, Kapshot, ScreenCursor, Retina, CleanShot 5.0 (Product Hunt, 2026); Screen Studio led Product Hunt's 2025 leaderboard | the category is crowded; standing out inside it is the fight the owner does not want |

**What it changes.** The way past the category is the combination nobody has: **an agent that edits from evidence** — a director's cut whose every cut names the step it removed and why — **on native Mac applications**, where the self-updating-video tools cannot reach, local, with a person approving each proposal. The cuts a goal asks for ("the tutorial", "a 45-second launch cut", "a vertical short") are views of one take.

Sources: [Cardboard](https://www.ycombinator.com/companies/cardboard), [Wideframe](https://www.ycombinator.com/companies/wideframe),
[Clueso Agents](https://www.clueso.io/agents),
[YC repost on Clueso's agents](https://theagenttimes.com/articles/y-combinator-spotlights-ai-agents-that-auto-generate-product-a9318fb5),
[Amorphic Labs](https://www.ycombinator.com/launches/SIw-amorphic-labs-agentic-personalized-product-demo-videos-for-sales),
[Karumi](https://www.ycombinator.com/companies/karumi), [Demosmith comparison](https://demosmith.ai/blog/best-ai-demo-video-generators-2026),
[Trupeer seed](https://cmotech.uk/story/trupeer-raises-usd-3m-to-automate-ai-powered-video-creation),
[Product Hunt 2025 leaderboard](https://www.producthunt.com/leaderboard/yearly/2025),
[Product Hunt recording category](https://www.producthunt.com/categories/screenshots-and-screen-recording?order=recent_launches).

## November 2026: agents that edit became ordinary

Re-surveyed 2026-11-08, after `v0.1.0` shipped. In one month:

| What shipped | What it means here |
| --- | --- |
| a free recorder relaunched with an agent that edits the take over MCP, transcript-word cutting, zooms planned from clicks, and a CLI for scripts and agents | the closest neighbour; it plans from clicks and words, with no record of what was pressed or why a click was not framed |
| a native macOS video editor exposing its timeline to Claude, Codex and Cursor over MCP on `127.0.0.1`, with an in-app agent beside it | an agent on the timeline is now expected of an editor on this platform |
| MCP servers that let a coding agent write a demo's script, perform it, film it and cut it | the agent can be the performer as well as the editor — web first, desktop with permissions |
| recorders whose agent records and returns a share link with an event log | outside the publishing rule; not followed |
| a hosted agentic editor (YC W26): footage plus a goal gives a first cut, then a timeline, with FCP and Premiere XML out | goal-driven first cuts are a product people pay for; Soredemo already hands a cut to FCPXML |
| an agent-written slide framework whose comment mode pins a note on an element and has the agent address every note at once, driving the coding agent the person already has | the interaction model for asking an agent to fix one place, without keys of our own |

**What it changes.** Nothing about the direction, and the window is narrower. Agents that edit
are ordinary; **an agent whose every cut names the step it removed and why, that proposes and
never accepts, on native Mac applications, locally** is still unclaimed. That is
`../design/2026-11-08-evidence-cut-and-the-agent-surface.md`.

Distribution, measured the same day: the official Homebrew cask repository asks a project
submitted by its own author for 225 stars, 90 forks or 90 watchers; a tap the owner creates has
no threshold. A disk image is the platform's usual drag-to-Applications install, notarised as
the outermost container.

## Platform: what WWDC26 gives an editor like this one

Read in the macOS 27.0 SDK and Apple's "What's new in SwiftUI" (WWDC26, session 269). The capture
and media APIs are in `docs/design/2026-10-22-what-macos-27-makes-possible.md`; this is SwiftUI.

| API | Use here |
| --- | --- |
| `ToolbarItemGroup.visibilityPriority(_:)`, `ToolbarOverflowMenu` | the editor toolbar keeps undo, split and export visible and folds the rest, instead of truncating |
| `WritableDocument` / `DocumentWriter` with `snapshot(contentType:)` and `write(snapshot:to:previous:progress:)` | saving a project writes only what changed, off the main actor, with progress — the package format already separates media from edit |
| `.reorderable()` / `.reorderContainer(for:)` | chapters, and caption names, reordered by dragging |
| `.swipeActionsContainer()` | swipe-to-delete on the timeline's lists outside `List` |
| `confirmationDialog(_:item:)`, `alert(_:item:)` | the delete and revert confirmations bound to the item they are about |
| `appearsActive` | the editor's own surfaces dim with the window, as system controls do |
| `@State` is a macro: a class in `@State` is created once per view, lazily | removes a class of "made twice" bugs; **source-breaking** where a `@State` has a default AND is set in `init` — to be checked across the app |
| `ContentBuilder` | fewer "unable to type-check" failures in long view bodies |

## Sources

- Screen Studio 4: [prequel.sh — Screen Studio 4](https://prequel.sh/blog/screen-studio-4) (a competitor's write-up),
  [AlternativeTo news](https://alternativeto.net/news/2026/10/screen-studio-4-0-adds-transcript-editing-a-camera-cutout-tool-and-more-mouse-effects/),
  [roadmap](https://screen.studio/roadmap), [creatorstoolbox](https://creatorstoolbox.com/tools/screen-studio/news)
- ScreenKite: [changelog](https://www.screenkite.com/changelog), [July 2026 update](https://screenkite.substack.com/p/screenkite-july-2026-update-sketch)
- Prequel: [prequel.sh](https://prequel.sh/); CursorClip: [features](https://cursorclip.com/features/), [changelog](https://cursorclip.com/changelog/)
- New launches: [Product Hunt category](https://www.producthunt.com/categories/screenshots-and-screen-recording?order=recent_launches), [Lumiko](https://www.producthunt.com/products/lumiko), [Smooth Recorder](https://www.producthunt.com/products/smooth-recorder), [Retina](https://www.producthunt.com/products/retina-2)
- Round-ups (vendor-written; for names, not rankings): [supademo](https://supademo.com/blog/screen-studio-alternatives), [screencharm](https://screencharm.com/blog/screen-studio-alternative), [zoomcap](https://zoomcap.live/blog/screen-studio-alternatives), [rekort](https://rekort.app/blog/screen-studio-alternative)
- Free and open: [GitHub topic](https://github.com/topics/screen-studio-alternative)
- SwiftUI: [WWDC26 session 269](https://developer.apple.com/videos/play/wwdc2026/269), [MacGeneration](https://www.macg.co/macos/2026/07/swiftui-en-manque-de-maturite-sur-mac-apple-apporte-de-nouvelles-reponses-309799)
