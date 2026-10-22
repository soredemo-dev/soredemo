# Audit, and how a free recorder beats the paid ones

2026-10-22. Asked for as: find the holes, research how to be better than the subscription
recorders in UI/UX, system design and edge-case testing, and get the code ready to be open
source — free, no watermark, and better than the paid tools anyway.

Every "present" and "absent" below was checked against the code, with a positive control for
each search that came back empty. Every number about a competitor carries its source, and those
sources are blogs and listings, not measurements; treat them as reported, not proven.

## 1. Holes

### Fixed in this pass

**V1 — a shared project could open any file on the Mac (path traversal).** A `.soredemo` package
is a document people send each other, and `project.json`'s `mediaFilenames` was decoded without
any check and appended to `media/`. A manifest naming `../../Users/someone/Movies/private.mov`
opened that file as the recording — any file this unsandboxed app can read — and saving the
project afterwards would have carried it into the next package the person shared. Two more ways
in, with a safe name: `media/clip.mov` as a symbolic link to elsewhere, or the `media` folder
itself as a link. All three are now refused: `ProjectSnapshot`'s decoder applies the rule
`writeSidecar` already applied on the way out (`ProjectPackageIO.isSafeMediaName`), and
`ProjectPackageIO.mediaFile(named:in:)` refuses an entry that is not an ordinary file in an
ordinary folder, asked with `lstat` so a link describes itself. Four mutations, four reds.

### Found and not yet fixed — ranked

| # | What | Severity | Why |
| --- | --- | --- | --- |
| R1 | **A crash during a take loses the take.** No movie fragments on the master writer, so the segment being written is unreadable without `finishWriting`; and the launch sweep (`TemporaryFileMediaSink.sweepLeftoverDirectories`) deletes every scratch package, including segments that WERE finished and recordings never saved | **high** — silent, total data loss | the 2026-10-16 crash (`EXC_BAD_ACCESS`, thread 10) was during a take; if it hit mid-segment, that recording is gone |
| R2 | The 2026-10-16 crash itself: `EXC_BAD_ACCESS (address 0x0)` on a background thread, during a call, possibly with an external display | unknown until the backtrace | no crash report is written while Xcode's debugger is attached; the backtrace is needed |
| R3 | No disk-space check before or during a take | **Fixed 2026-10-22** — medium | a full disk mid-take fails the writer; with R1 that is a lost take, without a word beforehand |
| R4 | No sleep/wake handling | **Fixed 2026-10-22** — medium | `TakeWakeLock` stops *idle* sleep; a closed lid or Apple menu → Sleep still sleeps mid-take, and nothing records why the stream stopped |
| R5 | Sharing a project shares its evidence | **Fixed 2026-10-23** — medium (privacy) | the observation log keeps the accessibility title under each click — window titles, button labels, sometimes a document's or an email's name. Correct for the editor; a surprise in a file somebody sends on |
| R6 | Unbounded reads of a shared package | **Fixed 2026-10-22** — low | `JSONLReader.linesOfFile` and the manifest read whole files into memory; a crafted multi-gigabyte log exhausts memory. Needs the person to open the file |
| R8 | A screenshot can fail on a transient system error | **Fixed 2026-10-22** — low–medium | probe § 31.1 failed once in three runs on 27.0.1 (26A434) with `SCStreamErrorInternalError` (-3811, "failed to start due to video/audio capture failure") and passed the next two. The person sees "could not be taken" for something one retry would have answered. Retry once on that code only |
| R9 | The take's displayed time runs slow under a busy main thread | **Fixed 2026-10-23** — low | `RecordingClock` adds up a fixed interval per tick on the main actor; delayed ticks are lost time, so the notch's clock undercounts. Measured: one tick where twenty were due, in gate 5 on 2026-10-22. The recording itself is unaffected. Fix: read the elapsed time from what the writer has written, not from ticks |
| R7 | XML 1.0 forbids control characters | **Fixed 2026-10-22** — low | a name containing U+0000–U+0008 makes an FCPXML Final Cut cannot parse; `FinalCutXML.escaped` escapes the five entities and not these |

### Checked and sound

Update check: HTTPS to `api.github.com` only, a release page accepted only on `https://github.com`,
opened in the browser, nothing downloaded or installed. FCPXML escapes all five entities.
Keystrokes: an allow-list of shortcut identifiers; ordinary typing never reaches the log. Picture
and background file names validated (`isSafeImageFilename`). No credentials in the tree (a search
for key/secret/token/password literals found none). Commit authors use GitHub's no-reply address.
Hardened runtime on; sandbox off, deliberately, for accessibility observation — which is what
made V1 serious and is why every name from a package must be treated as hostile.

## 2. What the paid tools are criticised for

| Product | Price (reported) | What users complain about |
| --- | --- | --- |
| Screen Studio | ~$29/month or $108/year; exporting needs a subscription; old one-time licence no longer sold [1][2] | exports that take hours (up to 2 h for a 30-minute video on an M1 Air) [1]; **no export queue** — one at a time, by hand [3]; long recordings hard to edit on the timeline; very large files [1] |
| FocuSee | $19.99/month or $49.99/year [4] | crashes on modest hardware; multi-monitor bugs [4][5] |
| CleanShot X | $29 once, or $8/month with cloud [6] | September 2026 reviews report macOS 27 compatibility problems [7] |
| a Rust recorder | free, open source (AGPL/MIT split) [8] | sharing-first; desktop app on Tauri rather than native [8] |

What they share: the cost is a subscription, the slow part is export, the fragile part is
anything unusual (two monitors, a long take, low memory), and the data lives in their cloud.

## 3. How to stand out — six claims, each one checkable

A free tool does not win by matching a feature list. It wins by being **the one people trust with
the take they cannot redo.** Each claim below is something the code can prove and a competitor's
marketing cannot.

1. **"You will never lose a take."** Fragmented master files, recovery instead of sweeping, a
   disk-space preflight, and a reason recorded for every stream that stopped (R1, R3, R4). No
   competitor advertises it; every one of them loses a take on a crash.
2. **"Every zoom says why."** Already unique: the accessibility element under each click and the
   reason a click was *not* zoomed to, reviewable and overridable. Make it visible in the first
   minute — the review panel, not a setting.
3. **"Export is not the waiting room."** Screen Studio's loudest complaint. `ExportQueue` exists;
   the claim to earn is exporting in the background while editing, with an honest ETA, and a
   measured export-speed number in the README beside the competitors' reported ones.
4. **"Edit it from your agent."** Pillar 4's local MCP server (`FEATURES.md`): "cut the dead air,
   zoom on every click in the settings pane, export 9:16" from Claude Code or Codex. Nothing in
   this market has it, and the approval rule (`AGENTS.md`) makes it safe to ship.
5. **"Nothing leaves your Mac."** No account, no telemetry, no cloud, no watermark — stated, and
   checkable because the source is open. Pair it with R5: a *Share project* that leaves the
   evidence out unless asked.
6. **"Native, and it shows."** Swift and ScreenCaptureKit, not a web view; VoiceOver labels on the
   custom controls (timeline, waveform, transcript — `FEATURES.md` notes they get none for free);
   ten languages already.

## 4. UI/UX, in the order it would move people

| # | Change | Why it matters |
| --- | --- | --- |
| 1 | **Recover the last take** on launch instead of deleting it | the trust claim above; turns a crash into an inconvenience |
| 2 | **Picture mode** for screenshots — no timeline, *Export* and *Copy* first | a screenshot opened in a video editor reads as a bug |
| 3 | **Pre-flight in the notch**: disk space, permissions, microphone hears something, speakers-into-mic | catches the failures that cost a take before the take |
| 4 | **Background export with a queue and a real ETA** | the competitor's loudest complaint |
| 5 | **Style presets** saved and shared as a file | the look people spend the most time recreating |
| 6 | **A sample project on first launch** | shows the zoom review and the reasons without a recording |
| 7 | **Long-take timeline**: chapters, a minimap, zoom-to-selection | "more than 10 minutes is hard to edit" [1] |
| 8 | **Keyboard-only editing and a shortcut sheet** | accessibility, and speed for the people who make many demos |

## 5. Edge cases with no test today

Each wants a test that fails first. Grouped by where it breaks.

- **The machine:** disk full mid-take; lid closed / sleep mid-take; wake into a different display
  arrangement; screen locked mid-take (secure input from `loginwindow`, which already breaks four
  probe checks when the screen locks — see the memory note).
- **Audio:** microphone unplugged mid-take; default output changed mid-take (headphones in or
  out); a call app's virtual device as the default (Teams' loopback is on this Mac); a 6-channel
  or 96 kHz microphone.
- **Displays:** external display unplugged mid-take (reconfiguration is handled, unplug is not
  posed — probe § 29 skips on one display); a window dragged to another display mid-take.
- **Files:** a project opened from a read-only volume; a path with emoji or right-to-left text; a
  package whose manifest and media disagree; the same project open twice; a 2-hour take (memory
  growth is sampled for 30 s by § 28; the 30-minute soak is listed in `TESTING.md` as a gap).
- **The user:** Stop pressed twice; Stop during the countdown; quitting during an export; deleting
  the project's folder in Finder while it is open.

## 6. Open-source readiness: architecture and organisation

**What is already better than most open-source apps:** a Foundation-only core enforced by a build
plugin (rule 1), view models for the editor (`EditorViewModel`, `TimelineEditorModel`), design
documents for every decision, a probe that runs real captures, mutation-checked tests, an MIT
licence, `README`, `CONTRIBUTING`, `NOTICE`.

**What a contributor will trip on** — measured line counts, and what each file is doing too much of:

| File | Lines | Single-responsibility split |
| --- | --- | --- |
| `Core/Sources/Capture/CaptureSession.swift` | 2563 | stream lifecycle · segment ledger · audio routing · observation routing · diagnostics — five types |
| `Soredemo/Editor/StageWindow.swift` | 1777 | layout · export orchestration · load pipeline · menus — move export and loading into view models |
| `Soredemo/Recording/RecordingCoordinator.swift` | 1273 | preferences · camera · take lifecycle · picture capture · opening files — a `RecordingPreferences` store and a `TakeController` |
| `Core/Sources/Compositing/StageCompositor.swift` | 1183 | 25 process-global `nonisolated(unsafe) static var` seams across Compositing — the dependency-inversion debt: a renderer configured by globals is why there can be only one editor, and why tests must serialise |
| `Soredemo/Inspector/CaptionsPanel.swift` | 1049 | view and caption-editing logic in one file — a `CaptionsModel` |

**Missing for contributors:** `SECURITY.md` (where to report V1-class problems privately),
`CODE_OF_CONDUCT.md`, issue and pull-request templates, CI that runs gates 1–2 on every pull
request (`TESTING.md`: "CI — none"), and a short architecture map in the README — `AGENTS.md` is
over six hundred lines and reads as a rulebook, not an introduction.

## 7. Proposed order

1. R1 (never lose a take) — design, measure fragmented writing and recovery, then build.
2. R2 — needs the backtrace.
3. `SECURITY.md` + CI for gates 1–2 — cheap, and what an open-source user checks first.
4. R3, R4 as part of the notch pre-flight.
5. Split `RecordingCoordinator`, then `CaptureSession`, behind the existing tests.
6. R5 — *Share project* without evidence.

## Sources

1. Trainn, "Screen Studio reviews" (2026-09-02) — https://trainn.co/blog/screen-studio-reviews/
2. Trainn, "Screen Studio pricing" (2026-08-26) — https://trainn.co/blog/screen-studio-pricing/
3. Screen Studio feedback board, "export multi task or queue" — https://hub.screen.studio/p/export-multi-task-or-queue
4. G2, FocuSee — https://www.g2.com/products/focusee
5. Software Advice, FocuSee — https://www.softwareadvice.com/screen-recording/focusee-profile/
6. Nexasphere, "Screenshot tools for developers in 2026" — https://nexasphere.io/blog/screenshot-tools-developers-2026
7. Setapp, CleanShot X listing and reviews — https://setapp.com/apps/cleanshot
8. a Rust recorder, "Open source screen recorder" — https://a Rust recorder/open-source-screen-recorder
