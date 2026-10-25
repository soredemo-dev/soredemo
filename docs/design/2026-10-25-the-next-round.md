# The next round

2026-10-25. The owner asked for the editor's layout and features, what others ship, the ideas
already written, the newest SwiftUI APIs, the app's transitions and export speed to be researched
and taken forward. This is the research that was not already in `docs/research/landscape.md`
(today's competitive table, which this does not repeat), each item checked against the macOS 27
SDK or the code before it is planned, and the order.

## Export speed: measure before changing anything

The export already takes the fast road: `MP4Exporter` reads with `AVAssetReader`, composites in
Core Image on a Metal device (`CoreImageFrameRenderer`) and writes with `AVAssetWriter` — the same
road another project measured at about 3× an `AVAssetExportSession`
([pull request](https://github.com/another project/pull/15), the author's own numbers).
**Accelerate's vImage is a CPU library**; on a path that is already GPU end to end, there is no
reason to expect it to help, and no source found that compares it with Core Image for video.

So the work is a measurement first: per frame, how long in decode, composite, pixel-format
conversion and encode, on a real recording — and only then the change it points at. The likely
ones, each to be confirmed or discarded by that measurement:

- the compositor's output in the encoder's own format (4:2:0 biplanar) rather than BGRA, so the
  encoder converts nothing;
- reading, compositing and writing overlapped rather than in step;
- `CIContext` caching of intermediates switched off for a frame that never repeats.

## The editor's layout: the SDK's own answers

Checked in the macOS 27 SDK's SwiftUI interface:

| API | Present | Use |
| --- | --- | --- |
| `ToolbarItem…visibilityPriority(_:)` (`.low` / `.automatic` / `.high`) | yes | Save and Export stay; the rest fold first when the window narrows |
| `ToolbarOverflowMenu` | yes | the folded items, named, not truncated |
| `EnvironmentValues.appearsActive` | yes (SwiftUICore) | the editor's own surfaces dim with the window, as system controls do |
| `toolbarMinimizeBehavior` | **no** on macOS | not used |

Seen on the running editor today and fixed: every inspector list was `.sidebar` (one line per row),
so its explanations were cut off; the background's fifth source was off the edge. Seen and not
yet fixed: the canvas bar's first control is cut at narrow widths.

## Transitions

Apple's guidance is that motion has a purpose and is never the only carrier of information, that
custom animation respects Reduce Motion (a dissolve instead), and that large flying or oscillating
motion is avoided ([HIG — Motion](https://developer-mdn.apple.com/design/human-interface-guidelines/foundations/motion),
[App Store reduced-motion criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria)).
Where the app moves today without a reason it can name — or moves where a reason exists and
does not — is to be listed by looking, then each change made with the Reduce Motion branch
beside it. Candidates already known: the inspector's tab switch (an instant swap), the panel's
selection (a jump), the editor opening from a finished take.

## Ideas already written, and their next step

| Idea | State | Next |
| --- | --- | --- |
| each click's application (bundle id) | designed | build |
| is this demo out of date | designed (`2026-10-25-is-this-demo-out-of-date.md`) | build on the above |
| a daruma that answers | built (`2026-10-25-a-daruma-that-answers.md`) | look at the header in the running panel |
| zoom by typing / scrolling / dragging | landscape item 2 | design |
| masking proposed from the log | landscape item 3 | design |
| export cost before pressing | landscape item 4; size shown, time not | the measurement above gives the time |

## Order

Commit what is built (owner, 2026-10-25) — done, in four commits. Then: the daruma that answers
— done; the export measurement;
the toolbar's priorities and the canvas bar; bundle identifiers and the out-of-date check;
transitions; then landscape items 2–4.
