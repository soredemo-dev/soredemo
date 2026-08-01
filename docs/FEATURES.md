# Features and frameworks

*What Soredemo does, and the Apple framework behind each piece. Four pillars.*

Target: macOS 26, Apple Silicon, Swift 6.4 strict concurrency, SwiftUI. Built against the macOS 27
SDK — see `ARCHITECTURE.md` D2 for why those two numbers differ.

> **Anything marked macOS 27 below is above the deployment floor and cannot be used.** Those rows are
> kept because they describe capability we would want, not because they are available. Do not plan
> Phase 4 or Phase 5 work on them without either raising the floor or finding a macOS 26 equivalent.

---

## Pillar 1 — Screen recording

Record a product demonstration, and record *what happened* alongside it.

### What you build

| Feature | Notes |
| --- | --- |
| Display and window capture | Up to 4K, 30/60fps |
| System audio + microphone | Independent tracks so they can be mixed later |
| Pointer-free master | The cursor is **not** baked into the recording — it is drawn at composite time. This is what makes custom cursors, smoothing, and click effects possible after the fact |
| One clock | A single time origin across video, audio, pointer, clicks, keys, and accessibility data. Everything downstream depends on this |
| Input evidence | Pointer path, click type and position, and the UI control under each click |
| Filtered keyboard | Approved shortcuts (⌘C, ⇧⌘Z) recorded as identifiers; ordinary typing is never recorded; secure input suppresses capture entirely |
| Pause and resume | All tracks retimed |
| Permission onboarding | Each permission degrades precisely — losing Accessibility loses smart framing, not the recording |

### Frameworks

**ScreenCaptureKit** — the whole capture path.

| Type | Use |
| --- | --- |
| `SCShareableContent` | Enumerate displays and windows |
| `SCContentFilter` | What to capture: a display, a window, or a display minus specific apps |
| `SCStreamConfiguration` | Resolution, frame rate, pixel format, `capturesAudio`, `excludesCurrentProcessAudio`, `showsCursor = false` |
| `SCStream` + `SCStreamOutput` | The stream and its sample callbacks |
| **`SCRecordingOutput`** | **macOS 15+. Records a stream straight to a file — no manual `AVAssetWriter`.** Use this for the master unless you need frame-level control |
| **`SCContentSharingPicker`** | **macOS 14+. The system source picker, the Video menu-bar item, and Presenter Overlay for free**, handing back a ready-made `SCContentFilter`. Do not build a custom picker first |

**Timing** — `CMClock`, `CMTime`, `CMSampleBuffer` (Core Media). Take `CMClock.hostTimeClock` once at session start and derive every timestamp from it. A sample arriving before the origin, or moving backwards, is an error, not something to clamp.

**Audio** — `AVCaptureDevice` + `AVCaptureSession` for the microphone; system audio comes from `SCStreamConfiguration.capturesAudio`. `AVAudioFormat`/`AVAudioPCMBuffer` for buffers.

**Input events** — `CGEvent.tapCreate` (Core Graphics) for pointer and clicks. Requires the **Input Monitoring** permission. Listen-only tap; never consume events.

**Accessibility** — `AXUIElementCopyElementAtPosition`, `AXUIElementCopyAttributeValue` with `kAXRoleAttribute`, `kAXFrameAttribute`, `kAXTitleAttribute`. Requires the **Accessibility** permission. Prefer a well-bounded descendant when the hit is a large container.

**Permissions** — `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`; `AVCaptureDevice.requestAccess(for: .audio)`; `AXIsProcessTrustedWithOptions`; `IOHIDCheckAccess` for Input Monitoring. Entitlements in the app sandbox and usage strings in `Info.plist`.

**Storage** — `FileManager`, `UTType` (UniformTypeIdentifiers) for the recording package.

---

## Pillar 2 — Video editing

Turn one raw recording into something worth posting. **Not an NLE** — four operations, plus automatic framing.

### What you build

| Feature | Notes |
| --- | --- |
| **Automatic framing** | Zoom targets derived from clicks and the accessibility control under them. When the control is not usable, fall back to the pointer and **say why** |
| Spring camera motion | Settles without overshoot, carries velocity across a re-aim, ignores jitter |
| Trim, cut, speed | The whole edit surface. No ripple, no snapping, no multicam |
| **Transcript editing** | Delete words from the transcript to cut the video. The primary editing surface |
| Captions | Word-timed, styled, burned or sidecar |
| Backgrounds and card | Solid, gradient, wallpaper, image; padding, corner radius, shadow |
| Cursor treatment | Smoothing, custom cursors, click ripples, keystroke badges |
| Motion blur | On fast camera moves |
| Aspect variants | 16:9, 9:16, 1:1 — **re-framed, not cropped** |
| Export | MP4 (H.264/HEVC), MOV (ProRes), GIF, up to 4K/240fps, P3 and BT.2020 |

### Frameworks

**Composition and playback**

| Type | Use |
| --- | --- |
| `AVAsset`, `AVAssetTrack` | Reading the master |
| `AVMutableComposition` | Trim, cut, speed — assemble the edit |
| `AVMutableVideoComposition` | Per-frame instructions |
| `AVVideoCompositing` | **Custom compositor protocol — this is where your renderer plugs in** |
| `AVAssetReader` / `AVAssetReaderTrackOutput` | Keyframe-aware seeking, frame-by-frame reads |
| `AVPlayer` + `AVPlayerLayer` | Preview playback |
| `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` | Frame-accurate export |
| `AVAssetExportSession` | The simple export path when you do not need per-frame control |

**Rendering** — `CIContext`, `CIFilter`, `CIImage` (Core Image); `CIKernel`/`CIColorKernel` written in Metal Shading Language and compiled by a SwiftPM build-tool plugin; `MTLDevice`, `MTLCommandQueue`, `MTLTexture` (Metal); `CVPixelBuffer`, `CVPixelBufferPool`, `IOSurface` (Core Video) for zero-copy.

**One render path for preview and export.** Same time, same project, same size must produce an identical frame. Prove it with golden-image tests.

**Frame timing** — **`CADisplayLink`.** `CVDisplayLink` is deprecated (macOS 14/15); on AppKit use `NSView.displayLink(target:selector:)` or `NSWindow`/`NSScreen` equivalents. Do not copy older `CVDisplayLink` code.

**Encode** — `VideoToolbox` (`VTCompressionSession`) for hardware H.264/HEVC/ProRes; `AVVideoCodecType.hevc`/`.h264`/`.proRes422`. `CGImageDestination` (Image I/O) for GIF and poster frames.

**Speech and captions**

| Type | Use |
| --- | --- |
| **`SpeechAnalyzer` + `SpeechTranscriber`** | macOS 26+. On-device streaming transcription with **OS-managed models — nothing to bundle, no API key, no per-minute cost** |
| `AssetInventory` | Check installed locales and download missing speech assets on first run |
| `AVCaptionRenderer`, `AVCaption` | Caption rendering and styling for a custom player UI |
| Generated subtitles | macOS 27 — on-device transcription **and on-device translation** of existing subtitles |

**Transcript UI** — **TextKit 2** (`NSTextLayoutManager`, `NSTextContentStorage`, `NSTextSelection`). Text layout, selection, and hit-testing are core concerns here, not details, because the transcript *is* the editor.

**Colour** — `CGColorSpace` for sRGB, Display P3, BT.709, BT.2020; `AVVideoColorPropertiesKey` on the writer.

---

## Pillar 3 — Launch video

The demo is the raw material. The launch video is what you actually post.

### What you build

| Feature | Notes |
| --- | --- |
| Title and text scenes | Hook, feature name, call to action |
| Product-proof scenes | Real footage from the demo, framed |
| Scene transitions | Cross-fade, push, scale — whole-scene, not clip-level |
| Background music | Optional, with ducking under narration |
| Poster frame | A still for social cards and READMEs |
| Written steps | A Markdown walkthrough derived from what was clicked and said |
| Post draft | Platform-specific copy |
| Platform profiles | Instagram Reels needs **9:16 and 5–90 s**; Threads ≤5 min; X has its own limits. These are compile-time constraints, not export-time surprises |

### Frameworks

**Text and shapes** — `CATextLayer`, `CALayer`, `CAGradientLayer`, `CAShapeLayer` (Core Animation); `CTFont`, `CTFramesetter` (Core Text) for precise typography; `CAAnimation`/`CAKeyframeAnimation` for scene motion.

**Compositing into video** — `AVVideoCompositionCoreAnimationTool` bridges a Core Animation layer tree into an `AVMutableVideoComposition`. This is the standard path for titles over video and it avoids rendering text yourself.

**Transitions** — `CIFilter` built-ins (`CIDissolveTransition`, `CISwipeTransition`, `CICopyMachineTransition`) or custom Metal kernels.

**Audio** — `AVAudioEngine`, `AVAudioMixerNode`, `AVAudioUnitEQ` for music and ducking; `AVAudioFile` for assets.

**Beat sync (optional)** — **Music Understanding framework** (macOS 27) analyses audio on-device across six dimensions. Spike this before writing beat detection by hand.

**Copy generation** — **Foundation Models**. Use `@Generable` guided generation so the output is a typed Swift structure with citation fields, not free prose. **Phrase facts the project already established; never supply facts it lacks.** `LanguageModelSession` for multi-turn. Free Private Cloud Compute tier applies under 2M downloads.

**Still export** — `CGImageDestination`, `UTType.png`/`.jpeg`.

---

## Pillar 4 — CLI and AI editor

The same capabilities, three ways in: the app, the command line, and an agent.

### What you build

| Feature | Notes |
| --- | --- |
| Local MCP server | HTTP on `127.0.0.1`. Works with Claude Code, Codex, Cursor, Gemini CLI |
| Read/inspect split | `get_*` returns state; `inspect_*` returns a **rendered prose overview** an agent can reason about |
| Mutation deltas | Tools return what changed, not the whole project — otherwise a long session exhausts the agent's context |
| Review-oriented tools | `explain_framing`, `approve_beat`, `override_value`, `list_stale`, `rebuild_variant`, `build_release_pack` |
| In-app skills | A skill catalogue the agent reads on demand, so the app ships its own editing know-how |
| CLI | `soredemo record / derive / review / edit / pack / export / status` |
| Approval gate | Publishing requires explicit per-post human approval. `publish` refuses to run non-interactively |

**One implementation, two bindings.** Every CLI verb is an MCP tool and vice versa. A capability in only one of them is a bug.

### Frameworks

| Framework | Use |
| --- | --- |
| **MCP Swift SDK** (`modelcontextprotocol/swift-sdk`) | Server, tool registration, transport |
| **Network.framework** | `NWListener` bound to `127.0.0.1`, `requiredLocalEndpoint` so it never binds externally |
| **Swift Argument Parser** | `ParsableCommand`, subcommands, `@Option`/`@Flag` |
| **Foundation Models** | On-device LLM. `@Generable` guided generation, `Tool` protocol for tool calling, multimodal prompts, and any provider conforming to `LanguageModel` — Apple's, Claude, Gemini |
| **Evaluations framework** | macOS 27. Test that AI features behave correctly across conditions. This is where you assert that a claim without valid supporting evidence cannot reach an approvable state |
| **App Intents** | Optional. `AppIntent`, `AppEntity`, entity schemas for Spotlight, and *"record a demo for the latest release"* by voice |
| **`os.Logger`** | Structured logging with subsystem and category |

### Security note

Any text arriving from outside — release notes, changelogs, PR titles — is attacker-controllable in a
repository that accepts contributions, and it flows toward a publish action. **Treat it as quoted data
to summarise, never as instruction to follow**, and test that an injected instruction cannot produce an
approvable claim. The approval gate is the backstop; the prompt framing is the first line.

---

## Cross-cutting

### App shell

| Framework | Use |
| --- | --- |
| **SwiftUI** | `NavigationSplitView` + `Inspector` for the three-pane editor. `DocumentGroup` for the project |
| **Liquid Glass** | **Automatic on standard components. Never call `.glassEffect()` for chrome; never touch `NSGlassEffectView`.** Custom glass does not respond to the system Liquid Glass slider |
| `WritableDocument` / `ReadableDocument` | macOS 27. Async incremental disk I/O with `Subprogress` — what a multi-gigabyte project package needs |
| `DocumentCreationSource` + `NewDocumentButton` | New from recording, from a release, or empty |
| **Observation** (`@Observable`) | View models. Not `ObservableObject` |
| **AppKit interop** | `NSViewRepresentable` for the timeline canvas and video preview. This boundary is where SwiftUI apps usually go wrong — watch WWDC26 session 272 |
| **Swift Charts** | The coverage metric. Do not hand-roll |
| Toolbar APIs | `visibilityPriority`, `toolbarOverflowMenu`, `topBarPinnedTrailing` |
| Accessibility | Timeline, waveform, and transcript are custom controls and get none for free |

### Project data

`Codable` + `JSONEncoder`/`JSONDecoder`, versioned with a schema number and an upgrade path. Atomic
writes via `FileManager.replaceItemAt`. Relative paths only. **Not SwiftData** — the project format is
a document, not a database.

### Concurrency

Swift 6.4 strict concurrency. `actor` for capture and render pipelines, `@MainActor` for UI,
`Sendable` across every boundary. `AsyncSequence`/`AsyncStream` for sample delivery and progress.
Swift 6.4 allows `async` in `defer`, which is directly useful for capture-session teardown.

### GitHub integration

`URLSession` against the GitHub REST API. Poll on launch and on a timer — **no webhook, no server**.
Keychain (`Security` framework) for the token.

### Distribution

Sparkle for updates · `Security`/`codesign`/`notarytool` for signing and notarisation · Icon Composer
for the layered Liquid Glass app icon · SF Symbols 8 · String Catalogs for localisation.

### Testing

**Swift Testing** (`@Test`, `#expect`, `#require`) — not XCTest for new work. Golden-image tests for
render parity. Evaluations framework for anything the model touches.

---

## Build order implication

Pillar 1 is self-contained and can ship alone as a free recorder. Pillar 2 depends on Pillar 1's
output. Pillar 3 depends on Pillar 2. Pillar 4 wraps all three and should be built once the surface it
wraps is stable — an agent API over a changing model is rework.

See `ROADMAP.md`.

---

# Appendix — the platform, and what was considered

## macOS 27 "Golden Gate"

| | |
| --- | --- |
| Shipped | ~14 September 2026 |
| Architecture | **Apple Silicon only.** Intel and Rosetta 2 ended |
| Character | Stability and performance release, in the spirit of Snow Leopard |
| Swift | 6.4 · **Xcode** 27 · **Metal** 4.1 |

macOS 27 also flags Intel apps that **stop working in macOS 28**, and Rosetta is no longer restored on
upgrade. Apple's Intel wind-down is faster than most people assume.

## Swift 6.4 — what actually helps here

| Feature | Why it matters for this project |
| --- | --- |
| **`async` in `defer`** | Cleanup runs whether a function returns or throws. Directly useful for capture-session teardown, where a leaked `SCStream` costs the user their next recording |
| **Iteration over noncopyable types** | `for-in` over `Span` and `InlineArray` — the frame pipeline can iterate without copying |
| `anyAppleOS` | Simplified availability syntax. Rarely needed under a single-OS floor, but cleaner when it is |
| `@diagnose` | Finer-grained warning control |
| Foundation URL parsing up to **4× faster** | Free win anywhere paths are handled in bulk |
| Swift Testing ↔ XCTest interop | Not needed for a fresh codebase, but it exists |

## SwiftUI in the 2027 releases

- **Document API** — `WritableDocument`/`ReadableDocument`, async incremental disk I/O, `Subprogress`
  progress reporting, `DocumentCreationSource` + `NewDocumentButton`
- **Reordering in any container** — `reorderable()` + `reorderContainer(for:)` works in `List`,
  `ScrollView`, lazy stacks, and custom layouts. Use it for story beats and media lists. It is a *list*
  primitive, so the timeline canvas still needs its own hit-testing
- **Toolbar control** — `visibilityPriority`, `toolbarOverflowMenu`, `topBarPinnedTrailing`,
  `toolbarMinimizeBehavior`. An editor has many toolbar items and a resizable window
- **`ContentBuilder`** replaces the per-container `ViewBuilder` overloads, collapsing type-checking to
  one path. Meaningfully faster compiles on a large SwiftUI codebase
- **`@State` is a macro** — classes stored in it initialise lazily, once per view lifetime
- `swipeActionsContainer` on any `ScrollView`; `navigationTransition(.crossFade)`
- **AppKit interop** — `NSViewRepresentable` for the timeline canvas and preview. This boundary is where
  SwiftUI apps usually go wrong

## Considered and rejected

Recorded so these are decisions, not questions that come back every few weeks.

| Framework | Why not |
| --- | --- |
| **Core AI** | Loads and runs *your own* models on-device. This product's reasoning comes from the derivation graph; no custom model is needed |
| **MLX** | Same reason. Genuinely impressive — Metal 4, GPU neural accelerators, distributed training over Thunderbolt — and irrelevant here |
| **SwiftData** | The project is a document users open, move, and version. Not a store. Do not introduce a second persistence story |
| **MetalFX** | Neural temporal upscaling for games. This renders at native resolution |
| **Image Playground** | Generative images contradict the thesis: everything is derived from what happened |
| **RealityKit, USDKit, Spatial Preview** | No spatial content |
| **NowPlaying** | This produces video; it is not a playback app |
| **App Attest, Trust Insights** | No server to attest to |
| **PencilKit, PaperKit, WidgetKit, Live Activities** | No surface for them |
| **Core Image RAW v9** | Improved sharpness and colour, but there is no still-photography path |

## Tooling and business, for later

| Framework | When |
| --- | --- |
| **StoreKit group and organisation subscriptions** | This is literally the Team tier in `PRODUCT.md` § Packaging. Read before designing billing |
| **MetricKit** (new in the 2027 releases) | Crash and hang telemetry, local-first |
| **Xcode Cloud** | CI. Worth it for a solo developer once the test suite is real |
| **DiskImageKit** (new in macOS 27) | Built on Apple Sparse Image Format with stacked images. Relevant at `.dmg` build time, though `create-dmg` is probably still simpler |
| **Icon Composer** | The layered Liquid Glass app icon, built from `soredemo-brand-kit/` |
| **SF Symbols 8** | 7,000+ symbols aligned to the system font |
| **App Intents** | *"Record a demo for the latest release"* by voice, and Spotlight indexing of past demos. `AppIntentsTesting` validates through real system pathways. Phase 8 at the earliest |

## WWDC26 sessions worth watching

| # | Session | For |
| --- | --- | --- |
| [250](https://developer.apple.com/videos/play/wwdc2026/250) | Principles of great design | Liquid Glass and the native-chrome rule |
| [269](https://developer.apple.com/videos/play/wwdc2026/269) | What's new in SwiftUI | Document API, reordering, toolbars |
| [272](https://developer.apple.com/videos/play/wwdc2026/272) | Use SwiftUI with AppKit and UIKit | The timeline canvas boundary |
| [289](https://developer.apple.com/videos/play/wwdc2026/289) | Modernize your AppKit app | Same |
| [321](https://developer.apple.com/videos/play/wwdc2026/321) | Lazy stacks and scrolling | The media browser |
| [322](https://developer.apple.com/videos/play/wwdc2026/322) | Compose advanced graphics effects with SwiftUI | Watch before writing Metal for something the framework does |
| [370](https://developer.apple.com/videos/play/wwdc2026/370) | Elevate your text experience with TextKit | The transcript editor |
| [220](https://developer.apple.com/videos/play/wwdc2026/220) | Refine accessibility for custom controls | Timeline, waveform, transcript |
| [256](https://developer.apple.com/videos/play/wwdc2026/256) | Generated subtitles and subtitle styles | Captions **and on-device translation** |
| [253](https://developer.apple.com/videos/play/wwdc2026/253) | Meet the Music Understanding framework | Beat sync |
| [241](https://developer.apple.com/videos/play/wwdc2026/241) | What's new in the Foundation Models framework | Guided generation, multi-provider |
| [242](https://developer.apple.com/videos/play/wwdc2026/242) | Build agentic app experiences | The agent surface |
| [298](https://developer.apple.com/videos/play/wwdc2026/298) | Meet the Evaluations framework | Testing the citation guard |
| **[347](https://developer.apple.com/videos/play/wwdc2026/347)** | **Secure your app: mitigate risks to agentic features** | **Watch before building post generation** |
| [262](https://developer.apple.com/videos/play/wwdc2026/262) | What's new in Swift | 6.4 language features |
| [259](https://developer.apple.com/videos/play/wwdc2026/259) | Xcode, agents, and you | Xcode 27's SwiftUI skills |
| [277 (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/277) | Bring advanced speech-to-text with SpeechAnalyzer | Transcription |
