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

xcrun swiftc \
  -swift-version 6 \
  -target arm64-apple-macos26.0 \
  -I .build/debug \
  -L .build/debug \
  -lSoredemoCore \
  -o "$OUT/probe" \
  Soredemo/Support/Minting.swift \
  Soredemo/Capture/CGGeometryBridge.swift \
  Soredemo/UI/ProjectDocument.swift \
  scripts/cross-boundary-digest-probe.swift

"$OUT/probe" "$@"
