# A replaced picture is drawn, not the one it replaced

2026-10-24. Found while reading `Soredemo/Inspector/AnnotationPanel.swift` (450 lines) to split
it, and then found again one file over.

## The defect

`CoreImageFrameRenderer` keeps every picture it reads out of the project's package — image
backgrounds and picture annotations both — in `backgroundImages`, keyed by the file's name. It
is never emptied; the renderer lives until the composition is rebuilt, and a change in the
inspector does not rebuild it (`StageWindow`'s `reviewRevision` comment: a style change "rebuilds
nothing; it seeks zero distance").

Both ways a person puts a picture into a project overwrite a file of the same name:
`StageStyleModel.useImageBackground` says so in as many words — "two pictures with the same name
replace each other, which is the behaviour a person expects" — and the annotation panel's
"Replace Picture…" does the same. The file on disk changes; the preview and any export from the
same session go on drawing the decoded copy of the old one, until the project is closed and
opened again. `TextArt` has the same shape for fonts and already answers it with
`forgetProjectFonts()`; pictures have no such answer. AGENTS.md's cache rule — every cache hit
paired with a proof that it invalidates — was never met for this cache.

## The decision

- `CoreImageFrameRenderer.forgetPackageImages()`, static, because the app reaches the renderer
  only as `any FrameRendering` behind `StageCompositor`. It bumps a generation; a renderer whose
  cache was filled under an older generation empties it on its next lookup. Keeps the cache
  per renderer, which is what scopes it to one project, rather than making it a process-wide
  static that would then also have to be forgotten when a project closes.
- Both adopters call it after the copy, and both copy through `ProjectStore.copyIntoPackage`,
  which gains a `packageURL:` form — this is the third and fourth copy of the same eight lines.

## The annotation tab, while it is open

Split into `Inspector/Annotations/`, three files about one tab (`ARCHITECTURE.md`'s rule of
threes):

| File | Holds |
| --- | --- |
| `AnnotationsModel.swift` | the track, the selection, and now the two timing actions and the picture's adoption |
| `AnnotationPanel.swift` | the view; the open panel stays here and hands the model a URL |
| `AnnotationInk.swift` | the five named colours |

The view decided two things a test could not reach: "Start here" keeps the length, and "End
here" refuses an end at or before the start. They move to the model as `startHere(_:at:)` and
`endHere(_:at:)`. A block whose body was not indented (the ink, weight controls) is fixed.

## How it is verified

- The renderer: one renderer, a solid red picture rendered, the file overwritten with blue and
  rendered again — still red (the cache is real) — then `forgetPackageImages()` and rendered
  again — blue. Mutations: the forget does nothing; the generation is not compared.
- The model, on a fixture whose annotation does not start at zero and is not three seconds
  long: start-here keeps the length; end-here before the start changes nothing and returns so;
  the picture is copied into the package under its own name and a same-named one replaces it;
  a hidden-file name is refused with the reason.
- App tests, the gates in order, explicit paths.

## Where it ended

As decided, plus one public read: `CoreImageFrameRenderer.packageImagesForgotten`, the number of
forgets so far, so the app's tests can show each adopter calls it without rendering a frame.
The annotation panel is 290-odd lines; the model, which reads no AppKit, 140.

Core: `aReplacedPictureIsDrawnOnceForgotten`, red under all three of its mutations, each at
its own assertion — the forget doing nothing and the generation not compared at the last;
**a renderer that never caches at the middle**, which is the proof the last one is about the
forget. App tests 295 → 300, five mutations each red on its own test: start-here resetting the
length, end-here allowed at the start, either adopter's forget removed, a hidden name accepted.

**Not seen in the running app:** choose a background, replace it with a different picture of
the same name, and see the preview change without reopening the project.
