# What macOS 27 makes possible, and the features only Soredemo can build

2026-10-22. Asked for as: research the new macOS, iOS and iPadOS frameworks, brainstorm features
other recorders do not have, smoother UI/UX, and keep the code MVVM and clean.

## Method

**The SDK first, the web second.** Web coverage of macOS 27's capture and media APIs is thin and
contradictory — one search result doubted that `SCRecordingEditor` exists at all. The headers on
this machine settle it, so every API below was read in the macOS 27.0 SDK (Xcode 27, 26A428 /
27.0.1 26A434) before it was written down. Apple's WWDC26 macOS guide supplied the frameworks the
headers cannot describe in prose.

## What is new, and what it is for here

| API (read in the SDK) | What it does | What Soredemo does with it |
| --- | --- | --- |
| `SCStreamErrorInsufficientStorage` (ScreenCaptureKit) | the stream says the disk is full, by name | R3 of the audit: a full disk is reported as a full disk, and the take is stopped and kept rather than lost |
| `AVAssetExportSession.configureForResumableExport` and its `ResumptionFailureReason`s | an export interrupted by a quit or a crash resumes instead of restarting | **"export survives a crash"** — the paid tools' loudest complaint is export time; losing an hour of export to a crash is the worst version of it |
| `NSStatusItem.expandedInterfaceDelegate`, `NSStatusItemExpandedInterfaceSession` | a status item that shows its own panel (not a menu) joins the menu bar's keyboard navigation and menu tracking | the menu bar panel stops being a window that happens to sit under the icon: arrow keys and sliding across the menu bar work the way they do for the system's own items |
| `SCStreamFrameInfoVideoOrientation`, `SCRecordingOutput.mixesAudioWithMicrophone` | per-frame orientation; a single mixed track | a rotated device or display is drawn upright without guessing; a "one track, ready to post" export option |
| `kAudioDevicePropertySuggestedReferenceDevice` (Core Audio) | the device the system suggests as a clock reference | the reference for aligning microphone and system audio when they come from different devices |
| `NSScreen.touchCapabilities` (AppKit) | whether a display takes touch | touches drawn like clicks when a demo is made on a touch display |
| Foundation Models: image prompts and on-device Vision tools (OCR, barcodes) | the on-device model can look at a frame and read it | titles, chapter names and alt text from what is *on screen*, not only from what was said |
| Core AI | load and run your own model on device, Apple Silicon only | a better person-segmentation or speech model than the system's, shipped with the app |
| App Intents entity and intent schemas; Spotlight semantic index; View Annotations | content Siri and Spotlight can find and act on | "find the demo where I clicked Export" — searchable by the observation log, which nobody else has |
| Generated subtitles and subtitle styles (WWDC26 session 256); Translation | system subtitle generation; on-device translation | subtitles in ten languages from one recording, without a service |
| SwiftUI document-based apps with direct disk access (session 269) | large documents read and written incrementally | opening a two-hour project without loading all of it |

## Features only Soredemo can build

Other recorders see pixels and a cursor. Soredemo also has the **observation log**: which
accessibility element was under every click, what kind it was, what the window was. Every idea
below is built on that, which is why a competitor cannot copy it by adding a slider.

1. **Interactive walkthrough export.** Every click is already an element with a position and a
   title. Export the take as a self-contained web page where each step is a still frame and the
   viewer clicks the highlighted control to advance. The paid interactive-demo tools charge per
   seat for this; here it is a derived export of evidence already on disk. **Biggest
   differentiator on this list.**
2. **Redaction that proposes itself.** The log knows when the click was on a secure text field,
   and Vision OCR can find e-mail addresses and keys in a frame. Proposed as redactions with the
   reason beside each one; a person accepts them. Every other recorder blurs by hand.
3. **"This demo is out of date."** Re-record the same flow later and compare the two logs: a
   button renamed, a step added, a window moved. The comparison says which steps changed, so a
   documentation video can be redone in the parts that moved and nothing else.
4. **Retake one step.** Steps are known from the clicks, so one step can be re-recorded and spliced
   in at its boundary, keeping the rest of the take.
5. **Search recordings by what happened in them.** Spotlight entities from the log and the
   transcript: "the recording where I opened Preferences and said 'billing'".
6. **Activity-aware framing.** The zoom today follows clicks. Typing into a field, scrolling a
   list and dragging a slider each want a different camera: hold on the field, follow the scroll,
   frame the drag's whole path. The log already separates them (typing only by timing, never
   content — the privacy rule stands).
7. **Edit by asking, on device.** Foundation Models with tools over the edit model: "cut the
   silences, zoom on every click in the settings window, export 9:16". Free because it is on
   device, and every change arrives as a proposal with an undo step — automation proposes, the
   person decides.
8. **Alt text and a description for every export.** The on-device model reads the frames and the
   transcript and writes the GIF's alt text and the video's description, for a person to edit.

## Smoother UI/UX

- **A command palette (⌘K)** over every editor action, with the shortcut shown beside each.
- **Spotlight around the cursor**: dim everything outside a radius, on timeline regions.
- **Camera layouts by segment**: full-screen face for the introduction, corner during the demo,
  hidden for a close-up.
- **Per-track trim**: microphone, system audio and video trimmed independently.
- **Click sounds**, optional, from a small built-in set.
- **Export presets saved by name** and shared as a file.
- **Hover-scrub on the timeline**, and the preview never blocks while an export runs.
- **First-run sample project** that shows the zoom reasons without asking for a recording first.

## Keeping it MVVM and clean while this lands

Every feature above follows the same seam, and new code that does not is the first thing review
asks about:

- **Pure logic in `Core`** (Foundation only, enforced by the build plugin): the walkthrough's step
  list, the drift comparison, the redaction proposals, the activity classifier. Tested with no
  screen and no permission.
- **Platform calls in the runnable tier** (`Capture`, `Compositing`): ScreenCaptureKit, resumable
  export, Vision OCR.
- **A view model per surface** in the app (`@Observable`), views that only bind. The god objects
  the audit measured — `CaptureSession` 2563 lines, `StageWindow` 1777, `RecordingCoordinator`
  1273 — are split before features are added to them, not after.
- **Every automatic value carries its origin** and a person's override wins (the producer-value
  rule), so the proposals in 2, 6, 7 and 8 are the same mechanism, not four.

## Proposed order

1. Resumable export, and `SCStreamErrorInsufficientStorage` in R3 — small, and they protect work.
2. The expanded-interface status item — small, and every user touches the menu bar.
3. Interactive walkthrough export — the one feature that makes Soredemo a different category.
4. Self-proposing redaction — the privacy promise made visible.
5. Activity-aware framing, then retake-one-step and drift detection.

## Sources

- Apple, WWDC26 macOS guide — https://developer.apple.com/wwdc26/guides/macos/
- Apple Newsroom, new intelligence frameworks (June 2026) — https://www.apple.com/newsroom/2026/06/apple-aids-app-development-with-new-intelligence-frameworks-and-advanced-tools/
- Apple, ScreenCaptureKit documentation — https://developer.apple.com/documentation/screencapturekit
- The macOS 27.0 SDK headers on this machine: `ScreenCaptureKit/SCError.h`, `AVFoundation/AVAssetExportSession.h`, `AppKit/NSStatusItem.h`, `AppKit/NSStatusItemExpandedInterfaceSession.h`, `CoreAudio/AudioHardware.h`.
