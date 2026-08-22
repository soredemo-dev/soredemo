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
  Soredemo/App/UnsavedWorkGuard.swift \
  Soredemo/UI/DesignTokens.swift \
  Soredemo/UI/ProjectDocument.swift \
  Soredemo/UI/PreviewView.swift \
  Soredemo/UI/StageWindow.swift \
  Soredemo/UI/FramingReview.swift \
  Soredemo/UI/StageStylePicker.swift \
  Soredemo/UI/TimelineEditor.swift \
  Soredemo/UI/ProjectStore.swift \
  Soredemo/UI/CaptionsPanel.swift \
  Soredemo/UI/TextPanel.swift \
  Soredemo/UI/RedactionPanel.swift \
  scripts/cross-boundary-digest-probe.swift

"$OUT/probe" "$@"
