# Beyond a screen recorder

2026-10-25. Asked for as: how Soredemo surpasses the competition — not matches it — and which
generational features would lift it out of the category. `docs/research/landscape.md` is the market
as it is; `2026-10-22-audit-and-how-to-stand-out.md` is how a free recorder wins on trust. This is
the step past both.

## The observation that decides it

**Every product in the landscape records pixels and then guesses.** Auto-zoom guesses from a
cursor; masking scans pixels for things that look like card numbers; a step-by-step guide tool
puts a red box around where the pointer was. The guide tools and the interactive-demo tools are
the closest to knowing what happened, and they only know it inside a browser, through a page's
DOM.

Soredemo already knows what happened in **any** Mac application. For every click the
observation log holds the accessibility element under it — role, title, frame — and the chain of
ancestors it sits in (`AXChainRecord`), which usually reaches the window and its title; approved
shortcuts by name; when the picture stood still. Content is deliberately not read: no keystroke text, no text inside a field
(`noAppSourceReadsKeystrokeText`, `noAppSourceReadsUserContent`). So the log is **a description of
the steps a person took, in the vocabulary of the interface itself** — "pressed the button titled
Export in the toolbar of the window titled Untitled" — with no private content in it.

A recording that knows its steps is not a video. It is closer to a script. Each idea below follows
from that, and none of them can be copied by adding a slider to a recorder that only has pixels.

## What the market says hurts

From the landscape research and the adjacent categories (sources at the end):

- **Demos go stale.** Every UI change silently invalidates onboarding videos, help-centre tutorials
  and sales walkthroughs; a demo takes four to eight hours to make, so re-recording is expensive and
  most teams let them decay. The emerging answer is to regenerate demos from end-to-end browser
  tests — web only, and only for teams who already have the tests.
- **One take, one format.** A screen recorder makes a video; a guide tool makes screenshots and
  text; an interactive-demo tool makes a clickable page, at forty to five hundred dollars a seat a
  month, with HTML capture in the top tier. The same flow is recorded three times for three tools.
- **Guides are unreliable.** Guide tools save guides with no steps, and their step text needs
  rewriting.
- **Recording is the bottleneck.** Retakes for one fumbled step; a voice-over re-recorded for one
  wrong word; nothing in another language without paying a dubbing service.

## Is there a market — checked, not assumed

**The money says yes for what ideas 2 and 3 replace.** The figures are the companies' own or
press reports of them, and the market-size reports disagree with each other by a factor of two,
so they are directions, not measurements.

| Evidence | What it shows |
| --- | --- |
| **Scribe** — guides made from clicks: Series C of $75M at a $1.3B valuation (November 2025); more than 5 million users and about 78,000 paying organisations; revenue more than doubled in a year, all as the company reports | turning recorded clicks into step-by-step documentation is a large, growing, paid market |
| **Arcade** — interactive demos: about $21.5M raised, Series A led by Kleiner Perkins (November 2024); more than 14,000 companies | a clickable walkthrough is something businesses pay for per seat |
| **Supademo**: by its founder's account seven-figure revenue, about 60,000 free users and over a thousand paying companies; **Navattic**: revenue estimates of $25–50M, from a third party | the category is not one company's |
| Digital adoption platforms: most 2026 reports put the market at roughly $1.5–2.2B, growing 11–20% a year | the buyers exist and budget for it |
| Interactive-demo prices: about $38–50 per creator per month to start; HTML capture — the format a walkthrough export produces — in tiers from about $200 to $500 a month or Enterprise | the thing Soredemo would export locally is the one competitors charge most for |
| **Scribe's desktop capture** is a paid tier; reviewers report "blank scribes" with zero steps, dropdowns and modals missed, and "would use it twice as much if I could capture my desktop" | guides from **desktop** apps are where the leader is weakest — and where an accessibility log is strongest |
| Stale demos and docs: Hacker News threads on screenshots that go stale after a few UI changes, and teams who "accept it as a cost of shipping fast"; vendors estimating 4–8 hours per demo; an open-source project regenerating demos from browser tests | the pain behind idea 1 is real and widely felt — **but no product has proved it can be sold yet** |

**What that does and does not prove.**

- **Proved:** people pay, at scale, for guides from clicks and for interactive walkthroughs, and the
  leader's desktop capture is its weak point. Ideas 2 and 3 sit on proved demand.
- **Not proved:** that anyone pays for a demo that re-records itself. The pain is real; the
  products are vendor claims and one open-source experiment. Idea 1 is the largest opportunity and
  the largest risk, which is why its first step — a read-only "is this demo out of date" check —
  is useful on its own if replay turns out to be unreliable.
- **Who Soredemo serves, given its rules.** The paid tools monetise hosting, analytics and CRM
  integration — share links Soredemo will not make (AGENTS.md, the publishing rule). So the
  customer is not a sales team buying seats; it is the people priced out of those seats: developers
  documenting their own Mac apps, open-source maintainers, technical writers, educators, solo
  founders — anyone who would host a file themselves. Free and local is the offer; the
  observation log is what makes it better rather than merely cheaper.
- **To measure before building idea 1:** whether the accessibility tree of a browser exposes web
  content well enough to find a step's element again (Chromium builds its tree only when an
  assistive technology asks for it), and how often a recorded step's element is found again
  unchanged in the same app a week later. Both are measurements on this machine, not claims to
  take from anyone.

## The ideas, ranked

Ranked by how much they rest on what only Soredemo has, how much the pain is reported, and how far
the code already is.

### 1. Living demos — a recording that can be run again

**Record once; when the app changes, Soredemo replays the steps and records the take again,
keeping every edit.**

- The steps come from the log: each click's element, found again in the live accessibility tree
  by role, title and ancestor path, and pressed. What the log does not hold — typed text — is a
  value the person supplies once, per field, in the script view; the privacy rule stands.
- **Every edit is keyed to a step, not to a second.** Zooms already survive re-derivation because
  `ZoomAdjustment` is keyed on the click (`ZoomBlock.origin`); captions, cuts, annotations and
  chapters move to step keys, so the new take inherits them where its steps match.
- **A step that cannot be found is the report.** "Step 4: no button titled Export in the toolbar
  — there is one titled Share." The replay stops there and asks, rather than guessing. That diff
  between two logs is idea 3 of `2026-10-22-what-macos-27-makes-possible.md`, now with a use.
- **Why generational:** the browser tools need a test suite and a web page; this needs only the
  take a person already made, and works for any Mac app — including the one a developer is
  building, whose demo can be re-run on every build.
- **Rules it must keep:** it drives the person's machine, so it runs only when started by a
  person, in front, with the stop key live and every step shown before it is pressed. Nothing is
  published; the result is a take in the editor like any other.

### 2. One take, every format

**The same recording exports as a video, a step-by-step guide, an interactive walkthrough, a GIF,
and subtitles — offline, from one take.**

- **The guide** — a frame per step, cropped to the element, with the step written from the
  element's own title ("Click **Export** in the toolbar"). Exact, because the title is the
  interface's, not a guess from pixels; never empty, because a step is a click the log holds.
- **The walkthrough** — `2026-10-23-interactive-walkthrough-export.md`, already designed: a
  self-contained page where the viewer clicks the highlighted control to advance.
- **Why generational:** three categories of paid tools for one flow, replaced by an export menu,
  with no seat price and nothing uploaded.

### 3. Steps as the unit of editing

**The timeline gets a step lane — each click a named step — and steps are what a person edits.**

- Delete a step (its span is cut), retake one step (record just that step and splice it at its
  boundaries — idea 4 of the macOS 27 document), retime a step, caption a step.
- The step list is also the chapter list, the guide's outline and the walkthrough's pages, so a
  change in one place is a change in all of them.
- **Why generational:** every editor in the market edits seconds; this edits what happened.

### 4. Narration written from what happened, in any language

**A draft voice-over per step, from the step's element titles and anything said, spoken by an
on-device voice — and translated.**

- Drafted by the on-device language model (Foundation Models), shown as text per step for the
  person to edit — automation proposes, the person decides.
- Spoken with the system's speech synthesis, including the person's own Personal Voice where they
  have made one; translated with the on-device Translation framework; subtitled from the same text.
- **Why generational:** a demo in ten languages without recording a word or paying a service, and
  with timing that already fits, because each line belongs to a step of known length.

### 5. The camera that knows what is on screen

Extends the zoom that already frames the accessibility element under a click:

- **Typing, scrolling and dragging framed as themselves** — hold on a field being typed into,
  follow a list being scrolled, frame a drag's whole path (idea 6 of the macOS 27 document).
- **Frame what appeared** — a sheet, a menu or a popover that opened after a click is an element
  with a frame; the camera can take it in rather than staying on the button that opened it.

### 6. Privacy from evidence

**Redactions proposed from what the log knows**: a click on a secure text field, a window
belonging to a password manager, plus on-device text recognition for addresses and keys in the
picture — each with its reason, accepted by a person. Screen Studio 4 scans pixels only; this
knows which field was secure.

### 7. A demo an agent performs and a person approves

**A written script — or an agent working from one — performs the flow while Soredemo records**, and
the log is the evidence of what was done. The local MCP server planned in `FEATURES.md` exposes
"record this flow", "cut the dead air", "export the guide"; every result arrives as a take in the
editor and nothing is sent. The publishing rule (AGENTS.md) is what makes this safe to ship.

### 8. A library you can search by what happened

Spotlight entities from the logs and transcripts — "the recording where I opened Preferences and
said billing" (idea 5 of the macOS 27 document) — and, with idea 1, a local health check: "three
of your twelve demos no longer match the app."

## What this asks of the code, in order

1. **Steps as a type** — a step is a click with its element, its span and its key; edits that are
   keyed to seconds get a step key beside them. Needed by every idea above; the zoom's key already
   is one. **The log names the application a click went to only by its display name** — the
   ancestor walk reaches the `AXApplication` root and records its title, which changes with the
   language and the version — so replay needs one more recorded field: the application's bundle
   identifier at each click, which is not content and passes the privacy rules as they stand.
   (This said "the ancestor chain stops at the window" until 2026-10-25; it does not.
   `2026-10-25-which-application-each-click-went-to.md`.)
2. **The step lane and the guide export** (ideas 3 and 2) — visible value with no new capture.
3. **The walkthrough export** (idea 2) — designed; build it on steps.
4. **Element lookup and replay** (idea 1) — read-only lookup first (does each step's element still
   exist?), which is useful on its own as the "this demo is out of date" check; pressing comes
   after.
5. **Narration** (idea 4) — on the step lane.

Not taken: anything that uploads, any share link, and any automation that changes a take without
a person seeing the change first.

## Sources

- Funding and users: [Scribe — Series C](https://scribe.com/library/scribe-raises-series-c), [Fortune on Scribe](https://fortune.com/2025/11/10/the-1-3-billion-startup-that-wants-to-tell-you-how-to-stop-wasting-time-at-work/),
  [TheSaaSNews](https://www.thesaasnews.com/news/scribe-raises-75m-series-c-at-1-3b-valuation/),
  [Arcade — Series A](https://www.arcade.software/post/series-a), [Fortune on Arcade](https://fortune.com/2024/11/21/exclusive-arcade-visual-storytelling-platform-raises-14-million-series-a-led-by-kleiner-perkins/),
  [Supademo on SaaS Club](https://saasclub.io/podcast/supademo-joseph-lee-443/), [Navattic on CB Insights](https://www.cbinsights.com/company/navattic/financials)
- Market size: [Fortune Business Insights — DAP](https://www.fortunebusinessinsights.com/digital-adoption-platform-market-107609), [SkyQuest — DAP](https://www.skyquestt.com/report/digital-adoption-platform-market)
- Desktop capture: [Guidde — Scribe desktop pricing](https://www.guidde.com/knowledge-hub/scribe-desktop-capture-pricing-guide-2026) (a competitor), [G2 — Scribe pros and cons](https://www.g2.com/products/scribe/reviews?qs=pros-and-cons), [Capterra — Scribe reviews](https://www.capterra.com/p/252555/Scribe/reviews/)
- Stale docs: [HN — outdated product documentation](https://news.ycombinator.com/item?id=43690841), [HN — self-updating screenshots](https://news.ycombinator.com/item?id=47908051), [HN — screenshots in docs](https://news.ycombinator.com/item?id=38639629)

- Stale demos and regeneration: [Vidocu — keeping tutorials current](https://vidocu.ai/blog/how-to-keep-tutorial-videos-up-to-date-when-the-ui-changes-every-sprint),
  [Leadde — updating outdated video](https://leadde.ai/blog/how-to-update-outdated-video-content),
  [daily.dev — demos that re-record themselves](https://daily.dev/posts/i-made-our-product-demo-videos-re-record-themselves-when-the-ui-changes-wjaimrq5f),
  [Puppydog — why demos take so many takes](https://www.puppydog.io/blog/product-demo-video-pain-points)
- Guide tools: [Guidde — Scribe vs Tango 2026](https://www.guidde.com/knowledge-hub/scribe-vs-tango-comparison-guide-2026) (a competitor's comparison),
  [Docsie — Scribe vs Tango](https://www.docsie.io/vs/scribe-vs-tango/)
- Interactive demos and their prices: [Peutly — interactive demo pricing 2026](https://www.peutly.com/blog/interactive-demo-software-pricing),
  [HowdyGo — interactive demo comparison](https://www.howdygo.com/blog/interactive-product-demo-comparison)
- Screen Studio 4 problems: [ScreenKite — Screen Studio 4.0 problems](https://www.screenkite.com/blog/screen-studio-4-problems-best-alternative) (a competitor's blog)
