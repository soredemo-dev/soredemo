#!/bin/bash
# Builds Soredemo.app with build-time provenance baked into
# Soredemo/App/BuildProvenance.swift, so a subject block printed by the
# running binary (--dump-permissions, --present-picker) reports which BUILD
# produced it, not the checkout's current state at launch. See that file's
# doc comment and task-7-report.md, "Fix round 3", for why a runtime `git`
# read at app-launch time is the wrong instrument for this question.
#
# Does NOT touch project.pbxproj — BuildProvenance.swift already exists,
# committed as a deliberately-fake placeholder, and Xcode's
# PBXFileSystemSynchronizedRootGroup (Phase 1 finding F8) picks up the
# stamped contents with zero project-file changes. scripts/build-provenance.sh
# writes both forms.
#
# Prints the RESOLVED .app path at the end, read back from this exact
# xcodebuild invocation's own build settings rather than assumed fixed —
# DerivedData is not guaranteed stable across builds, and `open` against a
# stale remembered path is the other half of the "which build" problem this
# script exists to close.
#
# Builds into Xcode's normal DerivedData, not /tmp: this app needs a stable
# location for Screen Recording / TCC grants to keep applying across runs,
# and /tmp is periodically cleaned.
set -euo pipefail

cd "$(dirname "$0")/.."

# Stamped for this build only: the placeholder goes back on exit, success or not, so a stamped
# copy is never left in the tree to be committed — see build-provenance.sh for what that cost.
scripts/build-provenance.sh stamp
trap 'scripts/build-provenance.sh placeholder' EXIT
COMMIT=$(sed -n 's/.*static let commit = "\(.*\)"/\1/p' Soredemo/App/BuildProvenance.swift)
BUILT_AT=$(sed -n 's/.*static let builtAt = "\(.*\)"/\1/p' Soredemo/App/BuildProvenance.swift)
echo

xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug build

# Read the path back from THIS build's own settings rather than guessing —
# the whole point of printing it at all.
BUILD_SETTINGS=$(xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug -showBuildSettings 2>/dev/null)
TARGET_BUILD_DIR=$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = /{print $2; exit}')
FULL_PRODUCT_NAME=$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = /{print $2; exit}')
APP_PATH="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"

echo
echo "Built: commit=${COMMIT}  builtAt=${BUILT_AT}"
echo "App:   ${APP_PATH}"
echo
echo "This exact path is what --present-picker's identity block should echo"
echo "back (bundle identifier / executable path) — if it does not, something"
echo "other than this .app is what actually ran."
echo
echo "Run with (pick a --stdout path outside /tmp, e.g. under \$HOME):"
echo "  open -W -n -a \"${APP_PATH}\" --stdout ~/soredemo-picker.log --args --present-picker"
echo "  cat ~/soredemo-picker.log"
