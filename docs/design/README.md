# Design documents

**The durable record of why** (AGENTS.md, "Method"): one document per decision — the question,
the alternatives, what was chosen, and, once done, where it ended. Code comments point here.

**Every file in this directory is listed below exactly once**, and
`everyDesignDocumentIsInTheIndex` fails `swift test` when one is added without a line here or a line
names a file that is gone. Older documents describe the code as it was when they were written;
where a later one overtook part of one, that part is said in the later one. The market survey is
`../research/landscape.md`.

New documents are named `YYYY-MM-DD-what-it-decides.md`. Some of the older ones carry no date in
their name; renaming them would break the comments that cite them, so they keep their names.

## Direction

| Document | What it settles |
| --- | --- |
| [2026-11-12-the-agent-gets-a-column](2026-11-12-the-agent-gets-a-column.md) | the agent's conversation as a full-height column on the left instead of a tab in the inspector, what the agent-driven editors do, and what it will point at next |
| [2026-11-12-captions-that-know-what-was-on-screen](2026-11-12-captions-that-know-what-was-on-screen.md) | correcting captions with what was on screen: names matched by sound as well as spelling, the observation log's labels as proposed vocabulary, and the agent's caption edits bounded and revertible |
| [2026-11-11-caption-line-breaking](2026-11-11-caption-line-breaking.md) | caption line breaking and the pointer's spring, each rewritten from a specification after an audit found them following other programs' code; how both were checked |
| [2026-11-09-two-clocks-two-types](2026-11-09-two-clocks-two-types.md) | a moment on the recording and a moment in the edit as two types, so a conversion done the wrong way round does not compile; what the migration found |
| [2026-11-08-evidence-cut-and-the-agent-surface](2026-11-08-evidence-cut-and-the-agent-surface.md) | the director's cut as evidence-carrying proposals; the read-only CLI and MCP server; the agent panel, which drives the person's Claude Code or Codex and edits directly, every edit named and every turn revertible; the layers |
| [2026-10-25-beyond-a-screen-recorder](2026-10-25-beyond-a-screen-recorder.md) | what only the observation log makes possible, ranked, and the market for it |
| [2026-10-22-audit-and-how-to-stand-out](2026-10-22-audit-and-how-to-stand-out.md) | a full audit, and how a free recorder beats the paid ones |
| [2026-10-22-what-macos-27-makes-possible](2026-10-22-what-macos-27-makes-possible.md) | the macOS 27 APIs read in the SDK, and features only the observation log allows |
| [what-macos-27-changed](what-macos-27-changed.md) | what macOS 27 changed under the app, adopted and rejected |

## Foundations — the phases, and the architecture they set

| Document | What it settles |
| --- | --- |
| [2026-08-01-phase-1-foundation-design](2026-08-01-phase-1-foundation-design.md) | Phase 1: the core's types, determinism, the architecture checker |
| [2026-08-01-phase-1-carried-forward](2026-08-01-phase-1-carried-forward.md) | what Phase 1 did not deliver |
| [2026-08-02-phase-2-record-design](2026-08-02-phase-2-record-design.md) | Phase 2: recording, the observation log, the spikes |
| [2026-08-03-phase-2b-render-design](2026-08-03-phase-2b-render-design.md) | Phase 2B: render and export |
| [2026-08-04-phase-3a-foundation-design](2026-08-04-phase-3a-foundation-design.md) | Phase 3A: the layer `swift test` can reach |
| [2026-08-12-phase-3a3-capture-extraction](2026-08-12-phase-3a3-capture-extraction.md) | capture moves into the package |
| [2026-08-14-phase-3a-carried-forward](2026-08-14-phase-3a-carried-forward.md) | what Phase 3A carried forward |
| [2026-08-14-splitting-headless](2026-08-14-splitting-headless.md) | the package's runnable tier split along its real boundary |
| [2026-08-12-clock-domain-types](2026-08-12-clock-domain-types.md) | clock domains as types |
| [2026-08-12-strict-memory-safety-gate-repair](2026-08-12-strict-memory-safety-gate-repair.md) | the memory-safety gate, clean per run |
| [2026-09-27-organising-the-project](2026-09-27-organising-the-project.md) | layers, view models, and what was deleted |

## The app's structure, 2026-10

| Document | What it settles |
| --- | --- |
| [2026-10-23-splitting-the-recording-coordinator](2026-10-23-splitting-the-recording-coordinator.md) | the coordinator's camera and guards leave it |
| [2026-10-23-splitting-the-stage-window](2026-10-23-splitting-the-stage-window.md) | the editor window's sections, preview and Final Cut export leave it |
| [2026-10-23-splitting-the-captions-panel](2026-10-23-splitting-the-captions-panel.md) | the captions model leaves its panel |
| [2026-10-23-splitting-the-timeline](2026-10-23-splitting-the-timeline.md) | one view per lane, and the trim handle that moved the wrong way |
| [2026-10-23-the-timeline-model-and-its-two-clocks](2026-10-23-the-timeline-model-and-its-two-clocks.md) | source and output time, and the in point that ignored the difference |
| [2026-10-24-splitting-the-menu-bar-panel](2026-10-24-splitting-the-menu-bar-panel.md) | one view per section; the stop key spelled where it is registered |
| [2026-10-24-splitting-the-notch-surface](2026-10-24-splitting-the-notch-surface.md) | one file per role; one answer to "is this point on it" |
| [2026-10-24-splitting-the-recording-bar](2026-10-24-splitting-the-recording-bar.md) | one file per role; what the three recording surfaces share |
| [2026-10-24-the-caption-list-decides-in-its-state](2026-10-24-the-caption-list-decides-in-its-state.md) | the caption list's search and fix-everywhere offer, testable |

## Recording

| Document | What it settles |
| --- | --- |
| [2026-08-19-recorder-parity](2026-08-19-recorder-parity.md) | what the recorder must match, by owner decision |
| [what-a-filter-excludes](what-a-filter-excludes.md) | what a capture filter leaves out |
| [2026-10-25-a-window-title-is-content](2026-10-25-a-window-title-is-content.md) | why the accessibility walk does not read a window's or a web page's title |
| [2026-10-25-which-application-each-click-went-to](2026-10-25-which-application-each-click-went-to.md) | each click's application recorded as its bundle identifier, validated on decode |
| [2026-10-25-is-this-demo-out-of-date](2026-10-25-is-this-demo-out-of-date.md) | designed: whether each step's application, version and element are still there, without replaying |
| [three-tracks-one-clock](three-tracks-one-clock.md) | video, system audio and microphone on one clock |
| [surviving-a-stopped-stream](surviving-a-stopped-stream.md) | when ScreenCaptureKit stops a stream mid-take |
| [2026-08-20-window-capture-repair](2026-08-20-window-capture-repair.md) | window capture: four defects, one root |
| [2026-09-18-a-window-resized-while-the-recording-runs](2026-09-18-a-window-resized-while-the-recording-runs.md) | a window resized during a take |
| [a-window-on-the-other-display](a-window-on-the-other-display.md) | a window on a second display |
| [2026-09-28-which-display](2026-09-28-which-display.md) | which display a window or a region belongs to |
| [recording-a-phone](recording-a-phone.md) | recording an iPhone or iPad, and why it has no automatic zoom |
| [hiding-macos-furniture](hiding-macos-furniture.md) | keeping desktop icons and notifications out of the take |
| [2026-09-30-before-and-during-a-take](2026-09-30-before-and-during-a-take.md) | staying awake, notifications, headphones |
| [how-long-is-left](how-long-is-left.md) | how much disk a take has left |
| [is-the-file-a-recording](is-the-file-a-recording.md) | checking a recording before saying it worked |
| [2026-10-23-a-crash-does-not-cost-the-take](2026-10-23-a-crash-does-not-cost-the-take.md) | recovering a take after a crash |
| [2026-09-22-the-clip-buffer-costs-frames](2026-09-22-the-clip-buffer-costs-frames.md) | the cost of keeping the last fifteen seconds |
| [2026-09-30-a-screenshot-is-a-one-frame-take](2026-09-30-a-screenshot-is-a-one-frame-take.md) | screenshot mode |

## The recorder's surfaces

| Document | What it settles |
| --- | --- |
| [2026-09-27-the-recorder-lives-in-the-notch](2026-09-27-the-recorder-lives-in-the-notch.md) | the notch as the recorder |
| [2026-09-28-notch-audio-warnings](2026-09-28-notch-audio-warnings.md) | what the notch says about sound |
| [the-editor-comes-out-of-the-notch](the-editor-comes-out-of-the-notch.md) | the editor opening from the notch |
| [full-screen-and-window-behaviour](full-screen-and-window-behaviour.md) | full screen and window behaviour SwiftUI has no modifier for |

## Cursor, zoom and the camera move

| Document | What it settles |
| --- | --- |
| [2026-10-25-a-recording-knows-its-steps](2026-10-25-a-recording-knows-its-steps.md) | steps — each named press — derived from the log, on a Steps lane |
| [2026-08-19-framing-gates](2026-08-19-framing-gates.md) | the zoom target, and every reason there isn't one |
| [2026-11-04-a-read-is-stale-only-after-the-release](2026-11-04-a-read-is-stale-only-after-the-release.md) | gate 3: a read is stale when it ended after the click was let go, not when it was slow |
| [how-the-drawn-cursor-behaves](how-the-drawn-cursor-behaves.md) | the drawn cursor: shape, density, motion |
| [classifying-the-live-cursor](classifying-the-live-cursor.md) | telling cursor shapes apart while recording |
| [2026-08-25-presentation-motion](2026-08-25-presentation-motion.md) | the cursor, the camera and the pixels between them |
| [when-two-zooms-become-one](when-two-zooms-become-one.md) | merging zooms that are close |
| [2026-09-27-how-fast-the-camera-moves](2026-09-27-how-fast-the-camera-moves.md) | the camera move's speed |
| [how-deep-the-camera-goes](how-deep-the-camera-goes.md) | how far a zoom goes in |
| [2026-09-27-edges-that-line-up](2026-09-27-edges-that-line-up.md) | snapping trims and zooms to edges |
| [2026-10-23-undoing-a-zoom](2026-10-23-undoing-a-zoom.md) | zoom edits in the undo history |
| [2026-10-25-the-zoom-lane-draws-the-camera](2026-10-25-the-zoom-lane-draws-the-camera.md) | the camera's own move on the zoom lane; both edges draggable |

## The camera

| Document | What it settles |
| --- | --- |
| [camera-background-removal](camera-background-removal.md) | cutting the room out from behind a camera |
| [2026-10-23-a-camera-that-reads-the-presenter](2026-10-23-a-camera-that-reads-the-presenter.md) | a camera that follows the presenter |

## The picture

| Document | What it settles |
| --- | --- |
| [2026-08-24-colour-pipeline](2026-08-24-colour-pipeline.md) | colour from capture to export |
| [2026-09-27-light-and-dark](2026-09-27-light-and-dark.md) | the app in light and dark |
| [2026-10-25-the-daruma-theme](2026-10-25-the-daruma-theme.md) | the app's colours from the daruma: sumi, washi, shu, kin |
| [2026-10-25-the-menu-bar-counts-down-and-paints-the-eye](2026-10-25-the-menu-bar-counts-down-and-paints-the-eye.md) | the menu bar's countdown, and the second eye painted when a take finishes |
| [2026-10-25-the-panel-and-a-daruma-that-answers](2026-10-25-the-panel-and-a-daruma-that-answers.md) | research and proposal: the menu bar panel, red kept for recording, a daruma that responds |
| [2026-10-25-the-notch-says-what-the-panel-says](2026-10-25-the-notch-says-what-the-panel-says.md) | the notch's recorder in the panel's grammar: choose, then Record or Screenshot |
| [2026-10-25-a-vermilion-icon](2026-10-25-a-vermilion-icon.md) | the vermilion daruma as a Dock icon a person can choose, and why Finder keeps the black one |
| [2026-10-25-a-daruma-that-answers](2026-10-25-a-daruma-that-answers.md) | the mark drawn in code: the header's eye looks at the card under the pointer, the permissions page paints an eye per grant |
| [2026-10-25-the-next-round](2026-10-25-the-next-round.md) | research and order after the daruma: export speed measured first, toolbar priorities, transitions |
| [2026-10-25-where-an-export-spends-its-time](2026-10-25-where-an-export-spends-its-time.md) | measured: an H.264/HEVC export is as fast as the hardware encoder alone, so nothing in the code is the limit |
| [2026-10-25-the-editor-opens-as-a-window](2026-10-25-the-editor-opens-as-a-window.md) | the editor comes forward at its final size on the same desktop instead of moving into a full-screen Space |
| [2026-10-25-the-editors-layout](2026-10-25-the-editors-layout.md) | proposal: the picture's settings first and the file's in the export sheet, one bar fewer, labelled tools, an empty lane that says why |
| [2026-10-26-a-character-not-a-logo](2026-10-26-a-character-not-a-logo.md) | research and direction after the owner's Grok reference: a parametric daruma with pill eyes, a glow per state, tucked/emerging/expanding in the notch |
| [2026-10-27-the-daruma-tips-flies-and-paints](2026-10-27-the-daruma-tips-flies-and-paints.md) | poked, the daruma rocks back upright; the countdown's flies into the notch; its record eye is painted with a brush |
| [2026-10-27-what-to-improve-next](2026-10-27-what-to-improve-next.md) | the next round, ranked: ship a release, a first run that ends in a take, empty states, the Look tab grouped, zoom shaped on the timeline |
| [2026-09-25-tilting-the-card](2026-09-25-tilting-the-card.md) | tilting the card |
| [2026-09-22-the-preview-composited-at-export-resolution](2026-09-22-the-preview-composited-at-export-resolution.md) | the preview composited at export resolution |
| [2026-10-24-a-replaced-picture-is-drawn](2026-10-24-a-replaced-picture-is-drawn.md) | a picture replaced under its own name |

## Captions, transcript, text and marks

| Document | What it settles |
| --- | --- |
| [how-a-caption-is-drawn](how-a-caption-is-drawn.md) | drawing a caption |
| [what-a-caption-editor-is](what-a-caption-editor-is.md) | the caption editor |
| [teaching-the-recogniser-a-word](teaching-the-recogniser-a-word.md) | names the recogniser has never heard |
| [deleting-a-sentence](deleting-a-sentence.md) | cutting the video by deleting from the transcript |
| [filler-words](filler-words.md) | why filler words are cut by a person, not detected |
| [2026-10-24-every-caption-edit-is-undoable](2026-10-24-every-caption-edit-is-undoable.md) | fix-everywhere and subtitle import, undoable |
| [2026-09-27-chapters](2026-09-27-chapters.md) | chapters |
| [2026-09-25-the-callout](2026-09-25-the-callout.md) | the callout |
| [2026-09-27-a-picture-as-an-annotation](2026-09-27-a-picture-as-an-annotation.md) | a picture as an annotation |
| [2026-09-30-steps-and-highlights](2026-09-30-steps-and-highlights.md) | step numbers and a highlighter |

## Sound and dead air

| Document | What it settles |
| --- | --- |
| [hearing-the-scrub](hearing-the-scrub.md) | hearing the recording while dragging the playhead |
| [taking-the-room-out](taking-the-room-out.md) | noise reduction |
| [finding-dead-air](finding-dead-air.md) | finding still stretches in the picture |

## Editing and export

| Document | What it settles |
| --- | --- |
| [why-the-editor-felt-slow](why-the-editor-felt-slow.md) | the editor's performance |
| [handing-the-cut-over](handing-the-cut-over.md) | handing the cut to another editor |
| [what-the-exporter-reads](what-the-exporter-reads.md) | what the exporter reads |
| [what-a-codec-keeps](what-a-codec-keeps.md) | codecs, and transparency |
| [2026-09-27-one-frame-as-a-picture](2026-09-27-one-frame-as-a-picture.md) | exporting one frame |
| [2026-10-25-a-guide-from-the-steps](2026-10-25-a-guide-from-the-steps.md) | exporting the take as a step-by-step guide, escaped |
| [2026-10-25-where-the-element-is-in-the-picture](2026-10-25-where-the-element-is-in-the-picture.md) | a pressed element's box on the exported picture, by the cursor's road |
| [2026-10-23-interactive-walkthrough-export](2026-10-23-interactive-walkthrough-export.md) | exporting a take as a clickable walkthrough |
| [what-a-project-file-remembers](what-a-project-file-remembers.md) | what a project file keeps |

## Strings, updates and the platform

| Document | What it settles |
| --- | --- |
| [2026-09-26-a-string-shown-verbatim](2026-09-26-a-string-shown-verbatim.md) | a string shown verbatim |
| [2026-09-27-plurals-appkit-and-a-flaky-section](2026-09-27-plurals-appkit-and-a-flaky-section.md) | plurals, AppKit's plain strings, and a probe section that skipped |
| [2026-09-27-asking-whether-there-is-a-newer-release](2026-09-27-asking-whether-there-is-a-newer-release.md) | checking for a newer release |
