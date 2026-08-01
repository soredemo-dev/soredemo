# Features and frameworks

*What Soredemo does, and the Apple framework behind each piece. Four pillars.*

Target: macOS 27, Apple Silicon, Swift 6.4 strict concurrency, SwiftUI.

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
