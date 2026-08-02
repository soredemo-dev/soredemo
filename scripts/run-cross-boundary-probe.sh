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

swift build

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
  -I .build/debug \
  -L .build/debug \
  -lSoredemoCore \
  -o "$OUT/probe" \
  Soredemo/Support/Minting.swift \
  Soredemo/Capture/CGGeometryBridge.swift \
  Soredemo/Capture/CaptureSource.swift \
  Soredemo/Capture/CaptureSession.swift \
  Soredemo/UI/ProjectDocument.swift \
  scripts/cross-boundary-digest-probe.swift

"$OUT/probe" "$@"
