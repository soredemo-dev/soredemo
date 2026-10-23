#!/bin/bash
# Builds and runs `scripts/cross-boundary-digest-probe.swift`.
#
# The probe compiles the REAL app sources — not copies — against the package's
# debug build products, so it can never pass while the shipping code is wrong.
# The authoritative list is the `swiftc` invocation below; do not restate it
# here, where it would drift out of date without failing anything.
#
# Nothing runs this automatically. See the probe's header for why, and the
# Task 18 report for the observation it was run to produce.
set -euo pipefail

cd "$(dirname "$0")/.."

# `swift build` below resolves its SDK through xcrun and produces .swiftmodule
# files stamped with it. The `xcrun swiftc` further down must use the SAME one,
# and an inherited SDKROOT breaks that: this machine's login profile exports
# SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk (26.5) while
# `swift build` picks Xcode-beta's 27.0, so every run launched from anything
# that sources the profile dies with "cannot load module 'Graph' built with SDK
# 'macosx27.0' when using SDK 'macosx26.5'".
#
# Measured while mutation-testing this probe: nineteen consecutive runs failed
# identically, and the failure is indistinguishable from a mutation that broke
# the build — which is exactly the wrong thing for a mutation harness to be
# unable to tell apart. Unset it here so the two compilers agree by
# construction, and print what they agreed on rather than leaving it implicit.
unset SDKROOT
echo "SDK: $(xcrun --sdk macosx --show-sdk-path) ($(xcrun --sdk macosx --show-sdk-version))"
# `--sdk macosx` and not the bare form: on this machine the bare form answers with a
# CommandLineTools path that xcodebuild then cannot locate, while `--sdk macosx` gives
# the SDK `swift build` actually passes. Measured by scripts/scan-sdk-deprecations.py.

# `--product` explicitly: a bare `swift build` compiles every target but emits no
# ARCHIVE, so `-lSoredemoHeadless` below would silently link whatever stale .a happened
# to be lying around from an earlier build. That is how this probe came to be linking an
# archive built on 2026-08-06, three phases before the targets it names existed.
swift build --package-path Core --product SoredemoCore --product SoredemoHeadless

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# These four mirror the app target's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
# and SWIFT_APPROACHABLE_CONCURRENCY = YES (read off the real `xcodebuild -scheme
# Soredemo` invocation, not guessed). Without them the probe compiles under
# DIFFERENT LANGUAGE SEMANTICS from the code it is checking: unannotated
# declarations are nonisolated here and MainActor-isolated there, so code can
# pass this probe and fail `xcodebuild`, which is exactly what happened in
# Task 7. Keep them in step with the pbxproj.
#
# **The capture and compositing sources are IMPORTED, not recompiled here** (Phase
# 3A-4). Every one of them used to live in the Xcode app target, where nothing but
# this probe could compile them, so listing them file by file was the only way to
# reach them. They are package targets now — `Capture` and `Compositing`, both
# vended by `SoredemoCore` — so recompiling their sources would build a SECOND copy
# under different flags and check that copy instead of the one the app links. What
# is still listed below is what genuinely remains app-target-only.
#
# `-I .build/debug/Modules` is where SwiftPM writes `.swiftmodule` files; the bare
# `.build/debug` path alone stopped resolving `import Graph` the moment a probe input
# needed it. `-lSoredemoHeadless` is the product `Capture` and `Compositing` are vended
# by, which had no reason to be linked while their sources were recompiled inline — and
# both products are declared `type: .static` in the manifest for the same reason: without
# it SwiftPM emits no archive at all and there is nothing here to link against.
#
# A `#` comment does NOT survive inside a backslash-continued command line —
# bash joins the continued line first, so a comment here silently truncates
# the whole `xcrun swiftc` invocation to zero arguments and spawns the next
# physical line as an unrelated, failing command (`-swift-version: command
# not found`). Measured by running this script after a previous edit put the
# comment where this one used to be: `set -euo pipefail` made the truncated
# `xcrun swiftc` (no input files) abort the script before the bogus second
# command ever ran. Comments belong outside the continuation, as above.
# **The list below is now EVERY app source but one, and it is checked.**
#
# It used to omit the recording surfaces — RecordingBar, MenuBarRecorder, SettingsWindow and
# ContentView, where RecordingCoordinator lives — and the reason recorded here was the app
# lifecycle: they were said to depend on a coordinator that "lives in ContentView.swift with
# the app lifecycle this probe does not compile". That was wrong, and wrong in the direction
# that keeps an omission alive: MenuBarRecorder named `SoredemoApp` for its two window ids and
# NOTHING ELSE, RecordingBar names MenuBarRecorderPanel, ContentView names RecordingBarPresenter.
# Four files transitively unreachable over two string constants. They live in `WindowID` now
# (`Soredemo/App/WindowID.swift`, whose header carries the measurement), and the four compile
# here like everything else — which is what § 17 of the probe needed to exist at all.
#
# `Soredemo/App/SoredemoApp.swift` is the one file that stays out, and structurally rather than
# by judgement: it carries `@main` and this binary has its own entry point, so the two do not
# link. That exemption is named in `Core/Tests/AppSourceTests/ProbeCoverageTests.swift`, which
# fails if any OTHER app source is missing from the invocation below — so this list can no
# longer drift the way it did, and a new app file is a red test rather than a silent gap. The
# invocation stays the single authority on what is compiled; the test reads it, it does not
# restate it.
xcrun swiftc \
  -swift-version 6 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -target arm64-apple-macos26.0 \
  -I Core/.build/debug \
  -I Core/.build/debug/Modules \
  -L Core/.build/debug \
  -lSoredemoCore \
  -lSoredemoHeadless \
  -o "$OUT/probe" \
  Soredemo/App/BuildProvenance.swift \
  Soredemo/App/WindowID.swift \
  Soredemo/App/KeyboardFocus.swift \
  Soredemo/App/UndoRecording.swift \
  Soredemo/App/WindowDrag.swift \
  Soredemo/App/BareKeys.swift \
  Soredemo/App/BareKeyMonitor.swift \
  Soredemo/Recording/OwnWindowReporter.swift \
  Soredemo/App/AppLanguage.swift \
  Soredemo/App/UnsavedWorkGuard.swift \
  Soredemo/App/UpdateCheck.swift \
  Soredemo/App/Clipboard.swift \
  Soredemo/App/Appearance.swift \
  Soredemo/App/EditorCloseGuard.swift \
  Soredemo/App/EditorWindowPresence.swift \
  Soredemo/App/GlobalHotkey.swift \
  Soredemo/App/PermissionRequests.swift \
  Soredemo/DesignSystem/DesignTokens.swift \
  Soredemo/DesignSystem/LiveSlider.swift \
  Soredemo/Editor/ContentView.swift \
  Soredemo/Recording/RecordingCoordinator.swift \
  Soredemo/Recording/RecordingClock.swift \
  Soredemo/Recording/MicrophoneSilenceWatch.swift \
  Soredemo/Recording/AudioRoute.swift \
  Soredemo/Recording/TakeWakeLock.swift \
  Soredemo/Recording/DiskHeadroom.swift \
  Soredemo/Recording/SleepPause.swift \
  Soredemo/Recording/RecordingPreferences.swift \
  Soredemo/Recording/CameraController.swift \
  Soredemo/Recording/TakeGuards.swift \
  Soredemo/Project/TemporaryFileMediaSink.swift \
  Soredemo/Project/RecordingName.swift \
  Soredemo/Recording/CameraSelfView.swift \
  Soredemo/Recording/DesktopIcons.swift \
  Soredemo/Project/ImportedRecording.swift \
  Soredemo/DesignSystem/SystemCursorShape.swift \
  Soredemo/Recording/CountdownPanel.swift \
  Soredemo/Recording/RecordingBar.swift \
  Soredemo/Recording/NotchSurface.swift \
  Soredemo/Recording/NotchSurfacePanel.swift \
  Soredemo/Recording/MenuBarRecorder.swift \
  Soredemo/Settings/SettingsWindow.swift \
  Soredemo/Project/ProjectDocument.swift \
  Soredemo/Editor/PreviewView.swift \
  Soredemo/Editor/StageWindow.swift \
  Soredemo/Editor/EditorPreview.swift \
  Soredemo/Editor/FinalCutXMLExport.swift \
  Soredemo/Inspector/CameraOverlayControls.swift \
  Soredemo/Inspector/OutputControls.swift \
  Soredemo/Inspector/GIFControls.swift \
  Soredemo/Inspector/ZoomAmountControls.swift \
  Soredemo/Inspector/AudioControls.swift \
  Soredemo/Editor/EditorViewModel.swift \
  Soredemo/Export/ExportQueue.swift \
  Soredemo/Export/CodecVerdicts.swift \
  Soredemo/Recording/RegionPickerOverlay.swift \
  Soredemo/Editor/FramingReview.swift \
  Soredemo/Inspector/StageStylePicker.swift \
  Soredemo/Inspector/WallpaperGallery.swift \
  Soredemo/Editor/ScrubAudio.swift \
  Soredemo/Editor/TimelineEditor.swift \
  Soredemo/Editor/TimelineEditorModel.swift \
  Soredemo/Editor/EditorToolbar.swift \
  Soredemo/Editor/AtPlayhead.swift \
  Soredemo/Editor/CaptionCueTracker.swift \
  Soredemo/DesignSystem/Theme.swift \
  Soredemo/DesignSystem/Palette.swift \
  Soredemo/App/WindowConfigurator.swift \
  Soredemo/Recording/TargetPickerOverlay.swift \
  Soredemo/Settings/PermissionsWindow.swift \
  Soredemo/Editor/Filmstrip.swift \
  Soredemo/Editor/PreviewOverlay.swift \
  Soredemo/Editor/CanvasBar.swift \
  Soredemo/Editor/TransportBar.swift \
  Soredemo/Project/ProjectStore.swift \
  Soredemo/Inspector/SystemCaptionStyle.swift \
  Soredemo/Inspector/CaptionsPanel.swift \
  Soredemo/Inspector/CaptionsModel.swift \
  Soredemo/Inspector/CaptionField.swift \
  Soredemo/Editor/SafeFrameOverlay.swift \
  Soredemo/App/EditorWindowStyle.swift \
  Soredemo/App/WindowSizeFloor.swift \
  Soredemo/App/FullScreenEntry.swift \
  Soredemo/App/WindowObservers.swift \
  Soredemo/DesignSystem/Tooltip.swift \
  Soredemo/Inspector/CaptionLines.swift \
  Soredemo/Editor/CaptionEditor.swift \
  Soredemo/Editor/CaptionWaveform.swift \
  Soredemo/Inspector/TranscriptPanel.swift \
  Soredemo/Inspector/TextPanel.swift \
  Soredemo/Inspector/ChaptersPanel.swift \
  Soredemo/Inspector/ChapterSuggester.swift \
  Soredemo/Inspector/RedactionPanel.swift \
  Soredemo/Inspector/AnnotationPanel.swift \
  scripts/cross-boundary-digest-probe.swift

# **Always to a file as well as to the terminal.**
#
# A run on 2026-09-15 printed "PROBE FAILED (1 of 473 checks)" through a `grep` that kept only
# the verdict, and three runs afterwards passed. Which check failed is gone — so the only thing
# that could be said about it is that something failed once, which is not evidence anybody can
# act on. The log costs nothing and is the difference between a flake somebody can investigate
# and a rumour.
LOG="${SOREDEMO_PROBE_LOG:-$OUT/probe.log}"
set -o pipefail
"$OUT/probe" "$@" 2>&1 | tee "$LOG"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo "" >&2
  echo "The whole run is in $LOG — read the FAIL line there rather than re-running," >&2
  echo "which is how a check that fails one time in twenty becomes a rumour." >&2
fi
exit "$STATUS"
