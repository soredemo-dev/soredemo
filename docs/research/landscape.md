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
| **Polished demo recorders** — auto-zoom, drawn cursor, backgrounds | Screen Studio, ScreenKite, Screen Charm, FocuSee, Cursorful, Prequel, CursorClip, Rekort, Smooth Recorder, Lumiko, Retina; free and open: a Rust recorder, an Electron recorder, an Electron recorder, and several newer open projects | a product demo or tutorial that looks edited when recording stops | everything |
| **Editors that record** | Camtasia, ScreenFlow, Descript, Tella | a long tutorial cut on a full timeline; Descript and Tella edit by transcript | the timeline, transcript editing, export |
| **Async video messages** | Loom, Vidyard, Screencastify, ScreenPal, Zoom clips | a quick message with a share link and viewer analytics | share links — which Soredemo deliberately does not do (AGENTS.md, the publishing rule) |
| **Capture utilities** | CleanShot X, Snagit, QuickTime, a streaming studio, ShareX, Bandicam, FlashBack, Icecream, Movavi, Clipchamp | screenshots, raw recordings, streaming | screenshot mode and raw capture only |

**Free products doing the same job exist and are getting better.** an Electron recorder is MIT-licensed,
free for commercial use and widely recommended as the free pick; a Rust recorder has a free tier; Retina is
free in beta; several newer open projects, one of them native Swift, ship auto-zoom, a timeline,
captions and platform export presets. So "free" alone does not set Soredemo apart. What does is
the observation log (below).

## What shipped recently

| Product | Recent release | What is new |
| --- | --- | --- |
| Screen Studio | 4.0, 2 Oct 2026 | glass loupe (a lens magnifies one detail while the rest stays in view); camera cut out of its background (beta), face tracking, "hide during silence"; camera colour grading, 12 looks and LUTs; **edit by transcript** — delete sentences, remove detected filler words, shorten pauses; split-screen layouts (side by side, stacked for vertical); sharper zoomed text from an on-device model; exports up to 3× faster; key presses drawn as keys; redesigned click ripple; caption fonts and animations; project sharing link (beta); a scan that masks e-mails, card numbers and API keys in every frame. Roadmap: on-device voice enhancement. 4.0 projects do not open in 3.x |
| ScreenKite | 1.14–1.16, summer–autumn 2026 | on-device transcription; noise reduction suite; an AI editing agent that asks before changing anything; scene transitions; teleprompter; cursor style themes; per-track audio placement; multi-language audio tracks with subtitle sidecars; 120/144 fps capture; the editor opens on the display where recording stopped |
| a Rust recorder | desktop 0.6, Aug–Sep 2026 | rebuilt editor with a crop tool and inspector; **export screen that shows estimated file size and export time**; record straight into an open project; 3D scenes and animated text; split-screen editing (0.5.1); recording recovery |
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
| Split screen, stacked for vertical | Screen Studio 4, a Rust recorder | ○ |
| Edit by transcript | Screen Studio 4, Descript, Tella | ● sentences and words |
| Filler words detected and removed | Screen Studio 4 | ◐ removable by hand, word by word; not detected |
| Shorten pauses | Screen Studio 4 | ● silence finding and removal |
| On-device captions | most | ● |
| Mask sensitive text automatically | Screen Studio 4 | ○ — manual redaction; Soredemo can do better (the log knows a click on a secure field) |
| Teleprompter | ScreenKite, Prequel, CursorClip | ○ |
| Export presets by platform | open recorders | ◐ — three by destination (web, person, editor), not by platform |
| Export shows size AND time estimate | a Rust recorder 0.6 | ● — both, the time from this Mac's measured encoder rate (2026-10-26, `ca4a19a`) |
| Export stages and "show in Finder" | most | ● show in Finder; ◐ stages |
| Faster export | Screen Studio 4 (3×) | not measured against them |
| Share link | Loom, Screen Studio (beta) | **○ by rule** — nothing leaves the machine without a person sending it |
| Interactive walkthrough export | interactive-demo tools, per seat | design written (`2026-10-23-interactive-walkthrough-export.md`) |
| Save the last 15 seconds | nobody | ● |
| Chapters from the recording | a Rust recorder (AI) | ● on device |
| A crash does not cost the take | a Rust recorder (recovery) | ● |
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
- a Rust recorder: [changelog](https://a Rust recorder/changelog), [desktop changelog](https://a Rust recorder/changelog/desktop), [v0.6](https://a Rust recorder/blog/cap-v06)
- Prequel: [prequel.sh](https://prequel.sh/); CursorClip: [features](https://cursorclip.com/features/), [changelog](https://cursorclip.com/changelog/)
- New launches: [Product Hunt category](https://www.producthunt.com/categories/screenshots-and-screen-recording?order=recent_launches), [Lumiko](https://www.producthunt.com/products/lumiko), [Smooth Recorder](https://www.producthunt.com/products/smooth-recorder), [Retina](https://www.producthunt.com/products/retina-2)
- Round-ups (vendor-written; for names, not rankings): [supademo](https://supademo.com/blog/screen-studio-alternatives), [screencharm](https://screencharm.com/blog/screen-studio-alternative), [zoomcap](https://zoomcap.live/blog/screen-studio-alternatives), [rekort](https://rekort.app/blog/screen-studio-alternative)
- Free and open: [an Electron recorder](https://github.com/an Electron recorder), [GitHub topic](https://github.com/topics/screen-studio-alternative)
- SwiftUI: [WWDC26 session 269](https://developer.apple.com/videos/play/wwdc2026/269), [MacGeneration](https://www.macg.co/macos/2026/07/swiftui-en-manque-de-maturite-sur-mac-apple-apporte-de-nouvelles-reponses-309799)
