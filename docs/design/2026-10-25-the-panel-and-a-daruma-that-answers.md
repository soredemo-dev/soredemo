# The menu bar panel, and a daruma that answers

2026-10-25. The owner asked for the panel's UI/UX to be researched and improved, for the daruma
to be part of how the app behaves rather than only its logo, and whether a red interface is a
good idea. This is the research and the proposal; nothing here is built yet.

## What the panel does today, read from the code and a screenshot

1. **Four ways to start, and they look like two kinds of thing.** Each target card (Screen,
   Window, Area) *starts* — it opens the system picker narrowed to its kind
   (`MenuBarTargets.swift`). "Start Recording" opens the same picker un-narrowed
   (`beginOpenRecording()`). A person reads the cards as a choice and the red button as the act,
   and pressing a card skips the button they were looking at.
2. **The Screen card's line is cut off** — "A whole d…": a 10-point single line in a third of a
   288-point panel. Window's and Area's fit by luck of length; any language longer than English
   cuts all three.
3. **Two kinds of row that behave alike look unalike.** Microphone and camera are bare text;
   frame rate and countdown sit on filled pills. All four are pickers.
4. **Frame rate sits at the same level as the microphone.** It is a set-once choice; the
   microphone is checked before nearly every take.
5. **Secondary text is faint over glass.** "Point at it" and "Drag it out" on a light wallpaper
   read below the panel's own primary text by a wide margin; the panel's material is the system's,
   the text colour over it is ours.
6. **The header is a 16-point logo and a word** — the one place the mark has room, used as a
   label.

## Research

**Recorders.** a Rust recorder's panel: targets as large icon buttons, each with a disclosure for *which*
display or window, and the recording mode as a small segmented icon group beside the title; the
less-used commands live in the status item's menu. Dockable shows live thumbnails of what will
be recorded. Several recorders turn the menu bar item into the recording indicator, as Soredemo
now does. A recurring warning from developers: UI placed over the menu bar fights macOS.
[Dockable docs](https://videowiki.onrender.com/docs/dockable-recorder/recording-your-screen) ·
[an issue report](https://paraspeech.userjot.com/board/p/recording-ui-no-longer-shows-when-in-a-full-screen-app) ·
the owner's own screenshots in `~/Documents/screen recorders/`.

**Red as an interface colour.** The convention across design systems is that red means error,
danger and destruction, and that a brand red used for ordinary controls makes branding read as
feedback and a destructive action read as a normal one
([UXcel](https://app.uxcel.com/courses/design-systems-intro/color-systems-439/handling-edge-cases-and-functional-conflicts-7079),
[UX Movement](https://uxmovement.substack.com/p/why-you-shouldnt-use-your-brand-color),
[Medium — red in interface design](https://medium.com/design-bootcamp/dealing-with-red-in-interface-design-abecd2a4f9c8)).
The products closest to this one keep red scarce: Loom's design system scopes its record red to
recording affordances only and uses a neutral and a blue elsewhere; YouTube's red is the mark,
and its interface is near-black; GNOME's capture button is white for a screenshot and red only
for a recording; Zalando reserves red for errors and makes interactive states black or white
([Loom](https://www.shadcn.io/design/loom/raw), [YouTube](https://www.shadcn.io/design/youtube),
[GNOME](https://gitlab.gnome.org/GNOME/gnome-screenshot/-/issues/227),
[Zalando](https://brand.zalando.com/identity/colour/colour-secondary/),
[Red Hat](https://ux.redhat.com/foundations/color/usage/)).

**So the accent chosen this morning was the wrong one, by the research's measure.** The palette
made shu the accent of every selected control and every link-like word, which spends the one
colour that means *recording* on things that do not record. The brand kit's own rule — "don't
put the red anywhere but the record eye" — said the same thing first.

**Mascots that are part of the product.** Characters that work in products are state machines,
not animations: idle, listening, thinking, succeeding, failing, each entered by something the
person did ([Rive mascot write-ups](https://dev.to/uianimation/how-duolingo-style-mascot-animations-in-rive-can-supercharge-your-app-or-website-39l)).
a menu-bar cat is the strongest small example on macOS: the character's speed *is* the CPU load, so
the animation carries information and never only decoration
([a menu-bar cat](https://github.com/a menu-bar cat)). The vendor material around this is
promotional; the pattern — state in, motion out, nothing gratuitous — is what is taken from it.

## Proposal

### A. The theme: ink is the accent, red only records

- `Theme.accent` becomes **sumi in the light theme and washi in the dark**, with an `onAccent`
  token for the label on it (washi on sumi, sumi on washi). Selected controls, the focused
  card, link-like words: ink.
- **Shu appears only where something records or is recording**: the Start Recording button, the
  record eye, the recording state everywhere. A red thing on screen then always means one thing.
- **Kin stays on caution**, and gains its brand meaning in one place: the moment a take is
  finished (the painted eye).
- The lanes are unchanged.

### B. The panel

1. **Choose, then start.** The cards become a choice (selected, with the ink border), and Start
   Recording starts the chosen kind. One primary action, in red, because it records. The cards'
   current one-press start stays as a double-click.
2. **The cut-off line**: the detail text wraps to two lines and the cards size to the longest
   language, measured in all ten tables.
3. **One row style** for microphone, camera and countdown; **frame rate moves to Settings**,
   where its once-chosen nature belongs, or under a disclosure.
4. **The microphone row shows a live level** before recording starts — the question a person
   has before a take is "is it hearing me", and the meter already exists for the recording state.
5. **Secondary text over glass** gets the measured contrast the opaque surfaces already have.

### B′. Let the system draw the glass (D7, applied to the panel)

Apple's guidance for Liquid Glass is that it belongs to the controls and navigation floating
above content, and that standard components adopt it on their own — which is D7's rule, and its
reason: hand-drawn glass does not follow the system's Liquid Glass setting
([WWDC25 — Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/310/),
[a summary of the SwiftUI APIs](https://dev.to/diskcleankit/liquid-glass-in-swift-official-best-practices-for-ios-26-macos-tahoe-1coo)).
The popover is the system's and already glass. **What is inside it is not**: the target cards,
the setting rows and the Start Recording button each draw their own rounded fill
(`.quaternary` at a hand-chosen opacity, a red `RoundedRectangle`). Not a breach of D7's words —
nothing calls `.glassEffect()` — but of its reason.

- **Buttons take the system's styles**: Start Recording becomes a standard prominent button,
  tinted with the record red, at the large control size; the cards become standard bordered
  buttons with a selected state, so pressed, hovered, focused and the user's glass setting are
  the system's, not ours.
- **Rows take the system's pickers** at one size, so B.3's "one row style" is the system's style.
- Liquid Glass changed again in macOS 27 (the SDK this builds with), so each control is looked at
  on 27 rather than assumed from 26's screenshots.

### B″. What 2026 says, and the two layouts tried

**macOS 27 changed Liquid Glass again**: lower default transparency, and a user slider from clear
to tinted and frosted that menus, toolbars and sidebars follow; windows share one corner radius
([Gizmodo](https://gizmodo.com/apple-fixes-the-illegible-liquid-glass-elements-on-macos-2000768705),
[AppleMagazine](https://applemagazine.com/macos-27-liquid-glass/),
[iGeeksBlog](https://www.igeeksblog.com/customize-liquid-glass-in-ios-27-macos-27/)). Only the
system's own controls follow that slider — D7's reason, now a setting every user has. Over busy
wallpapers, legibility was Tahoe's main complaint
([AppleInsider](https://appleinsider.com/articles/25/06/11/liquid-glass-is-more-than-skin-deep-on-macos-tahoe)).

**Apple's own recorder separates the target from the act**: the Screenshot toolbar offers Entire
Screen, Selected Window (new in 26) and Selected Portion, then one Capture or Record button
([Apple Support](https://support.apple.com/en-us/102618)). CleanShot 5 (September 2026) asks
"Record" or "Record in Studio Mode" at the start, and redesigned only its settings
([AlternativeTo](https://alternativeto.net/news/2026/9/cleanshot-x-5-0-introduces-studio-mode-to-turn-a-screen-recording-into-a-polished-video/)).
Glass on glass is avoided: the popover is the glass, so what is inside it is the system's
ordinary controls, not `.glass` buttons.

The Record/Screenshot switch was tried five ways in a real popover (segmented; macOS 27's
`.tabs`, which draws as a segmented control with a raised selected tab; icons in the header;
bordered toggles; large segmented). Two whole panels were then built:

- **One** — the switch as two icons in the header, one prominent Start Recording.
- **Two** — no switch at all: choose the target, then **Record** or **Screenshot**, as Apple's
  toolbar does. It removes a control, answers "four buttons that start" with two that say what
  they do, and frees the row the switch took.

**Two is recommended.** Both use the system's prominent and bordered button styles, menu pickers
for the three rows, concentric card corners, and the ink accent; the cards are selected rather
than pressed, and their detail line wraps.

### Building option two (chosen by the owner, 2026-10-25)

- **The target is a preference** — `RecordingPreferences.captureTarget`: screen, window or area,
  remembered, defaulting to the screen. The same target is chosen nearly every time, and a
  choice that resets on every open is a choice made again on every open.
- **A connected device is a target too, but not a remembered one**: `selectedDevice` lives on the
  coordinator for as long as the device is plugged in. A device has no screenshot path, so
  Screenshot is disabled while one is chosen — disabled, with its reason, not hidden.
- **One way in**: `start(_ purpose:)` sets the purpose and goes through the existing door for the
  chosen target — the display picker, pointing at a window, dragging an area, or the device.
  Which door is a pure function (`CaptureEntry.for(target:device:purpose:)`), so it is a test.
- **⇧⌘R records the chosen target**, as the Record button does. It opened the un-narrowed picker,
  a fourth way to start that the panel did not show.
- **Frame rate moves to Settings → Before recording**, beside the countdown.
- **One row style** for microphone, camera and countdown: icon, name, value, chevrons, on the
  system's `quaternary` fill with concentric corners, not a hand-chosen opacity.
- **Record** is the system's prominent button in the ink accent; **Screenshot** is the system's
  bordered button. (Record first carried its dot in the record red; the owner found it too loud on
  an idle panel, and it is now the label's own ink — red appears once something records.)

### C. The daruma that answers

Restraint first: it is never on the picture being recorded, never moves during a take except
where it carries information, and holds still under Reduce Motion. Each state is entered by
something real:

| Where | What it does | Why it is not decoration |
| --- | --- | --- |
| panel header | its record eye **looks toward** the card under the pointer | says which target the next press records |
| panel header | the eye **fills** while Start Recording is pressed down | the press is the eye being painted |
| microphone row, before a take | the daruma **sways with the input level** | a menu-bar cat's rule: motion is the level |
| countdown panel | the countdown ring is drawn **round the record eye** | one countdown in one shape, menu bar and screen alike |
| ⎋ during the countdown, or a failed start | it **tips over and rights itself** — 七転び八起き | a cancel that is not an error, shown as the thing the brand is named for |
| take finished | the **second eye is painted** (menu bar, already built) and the editor opens on it | 目入れ: the work is done |
| permissions page | **one eye per required permission** — Screen Recording and Accessibility — painted as each is granted | progress through setup, in the mark |
| editor, no recording | the daruma **waiting**, dashed eye, with the one action | an empty state that says what to do |

## Order

A first — it is small, it reverses a decision whose reason did not hold, and B and C are drawn
in its colours. Then B.1–B.2 with B′ (a behaviour fix, a bug, and the system's controls in place
of hand-drawn ones — one pass over the same file), then C's panel header and permissions page,
then the rest. Each with its own design notes, tests and a look at the running app.

## Where option two ended

As decided, with one finding. `CaptureTarget` and `CaptureEntry` (`Soredemo/Recording/CaptureEntry.swift`),
`RecordingPreferences.captureTarget`, `RecordingCoordinator.start(_:)` and `selectedDevice`;
⇧⌘R calls `start(.take)`. The cards select; `MenuBarActions` is Record and Screenshot; the
frame rate is in Settings → Before recording.

**The finding: the old rows were not drawing what their code said.** `Menu` with
`.menuStyle(.borderlessButton)` draws only its label's icon and title — the value, the chevrons
and the fill the code built were never on screen, which is why the microphone row read "System
default" with no box while Frame rate and Countdown had one. Seen on the running panel, not
inferred; `MenuBarRow` uses `.menuStyle(.button)` with a plain button style, and all three rows
now draw the same.

Tests: `CaptureEntryTests`, four — red against stubs (five failures: every door the display
picker, the target never stored), green after. Mutations, each red on its own test: a device
allowed a screenshot; the target not written. `theMenuBarPanelHasOneSettingsRowShape` now counts
the hidden menu indicator (one: `MenuBarRow`'s) and `.menu` pickers (none); red with a second
row declaring its own indicator. Looked at: the panel in the light and dark themes.

**Not done here:** the notch has its own Record/Screenshot switch and its own target buttons,
which now disagree with the panel. It is the next surface.
