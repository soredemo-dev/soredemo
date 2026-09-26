#!/bin/bash
#
# Builds, signs and notarises a Developer ID copy of Soredemo — the `free-recorder-release`
# row's mechanical half.
#
# **It does not publish anything, and that is deliberate.** The last thing it does is leave a
# stapled .app and a .zip in dist/ and print where they are. Uploading, tagging a release,
# or announcing is a separate, human act — see the publishing rule in README.md. Nothing here
# talks to a server except Apple's notary service, which is a signing step, not a release.
#
# **The gates run first and a red tree stops the build.** Shipping is the one moment where
# "the tests were failing but the feature works" costs the most, so this refuses rather than
# warns.
#
# Credentials are read from a notarytool keychain profile, never from arguments — an
# app-specific password on a command line ends up in shell history. Create one once with:
#
#   xcrun notarytool store-credentials soredemo-notary \
#     --apple-id <your Apple ID> --team-id GJRVCWA2U3 --password <app-specific password>
#
# Then: scripts/build-release.sh
#
# Skip notarisation (a local build, or you have no credentials yet) with:
#   SOREDEMO_SKIP_NOTARIZE=1 scripts/build-release.sh

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${SOREDEMO_NOTARY_PROFILE:-soredemo-notary}"
DIST="dist"
ARCHIVE="$DIST/Soredemo.xcarchive"
EXPORTED="$DIST/export"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# **A release is built from a commit, not from a working tree.** The binary's identity block
# names the commit it was stamped with; from a dirty tree that name describes code that exists
# nowhere else. Checked first, before an hour of gates.
if ! git diff --quiet || ! git diff --cached --quiet; then
  if [ "${SOREDEMO_ALLOW_DIRTY:-0}" != "1" ]; then
    echo "The tree has uncommitted changes. Commit them, or set SOREDEMO_ALLOW_DIRTY=1 for a" >&2
    echo "build whose identity block will say -dirty." >&2
    git status --short >&2
    exit 1
  fi
fi

say "1/6  The four gates, and the app's own tests"
# Each is the whole gate, not a subset: a release built from a tree where one was skipped is
# a release nobody can say anything about.
#
# `--no-parallel` because the full suite run in parallel has hung inside Apple's test helper
# with nothing wrong in the code, and a release is the worst place to learn which kind of red
# this is. Serial is slower and it finishes.
swift test --package-path Core --no-parallel
scripts/check-strict-memory-safety.sh
scripts/run-cross-boundary-probe.sh
# No `-quiet` on this one: it emitted "the following command failed with exit code 0 but
# produced no further output" on a successful build, which under `set -e` would abort a
# release for nothing. The archive below keeps `-quiet` — it has not shown the same fault,
# and its output is long.
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Release build \
  CODE_SIGNING_ALLOWED=NO | tail -5
# The app target's tests are not in any of the four: `swift test` never builds the app, so a
# release could ship with its own suite red. This one refuses to pass having run nothing.
scripts/run-app-tests.sh

say "2/6  Archive"
rm -rf "$DIST"
mkdir -p "$DIST"
# Stamped for the archive only; see build-provenance.sh for why the placeholder goes back.
scripts/build-provenance.sh stamp
trap 'scripts/build-provenance.sh placeholder' EXIT
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Release \
  -archivePath "$ARCHIVE" archive -quiet

say "3/6  Export, Developer ID"
# Written per run rather than checked in: it contains the team ID, and a stale copy that
# disagrees with the project's DEVELOPMENT_TEAM fails at export with a confusing message.
TEAM=$(xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -showBuildSettings 2>/dev/null \
       | awk -F' = ' '/ DEVELOPMENT_TEAM = /{print $2; exit}')
if [ -z "$TEAM" ]; then
  echo "no DEVELOPMENT_TEAM in the project's build settings — set one in Xcode first" >&2
  exit 1
fi
cat > "$DIST/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$DIST/ExportOptions.plist" -exportPath "$EXPORTED" -quiet

APP="$EXPORTED/Soredemo.app"
[ -d "$APP" ] || { echo "export produced no Soredemo.app in $EXPORTED" >&2; exit 1; }

say "4/6  Verify the signature before asking Apple about it"
# `--strict` and the hardened-runtime check locally: notarisation rejects the same faults
# after a round trip that costs minutes.
codesign --verify --deep --strict --verbose=2 "$APP"
# **The entitlements the app records with, read off the artefact.** Release once lacked the
# camera entitlement that Debug had, and under the hardened runtime that means no camera — in
# the one build nobody had run. The project-level check is
# `releaseBuildsTheAppWithTheSameSettingsAsDebug`; this one looks at what is being shipped.
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p -)
echo "$ENTITLEMENTS"
for needed in com.apple.security.device.camera com.apple.security.device.audio-input; do
  case "$ENTITLEMENTS" in
    *"\"$needed\" => true"*) ;;
    *) echo "the exported app lacks $needed — it cannot record with it" >&2; exit 1 ;;
  esac
done
# The output is captured before being searched, NOT piped into `grep -q`. Under `pipefail`
# that pipeline fails on a MATCH: `grep -q` exits as soon as it finds one, `codesign` takes
# a SIGPIPE writing the rest, and its non-zero status becomes the pipeline's. The first
# draft of this check therefore rejected every correctly hardened build.
SIGNATURE=$(codesign -d --verbose=4 "$APP" 2>&1)
case "$SIGNATURE" in
  *"flags="*"runtime"*) ;;
  *) echo "the exported app is not hardened — notarisation will reject it" >&2; exit 1 ;;
esac

ZIP="$DIST/Soredemo.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${SOREDEMO_SKIP_NOTARIZE:-0}" = "1" ]; then
  say "5/6  Notarisation SKIPPED (SOREDEMO_SKIP_NOTARIZE=1)"
  echo "The app is signed but not notarised. macOS will refuse to open it on another machine."
else
  say "5/6  Notarise"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  # Re-zip AFTER stapling: the ticket lives in the .app, and the zip made above predates it.
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun stapler validate "$APP"
fi

say "6/6  Done — nothing has been published"
echo "  app: $APP"
echo "  zip: $ZIP"
echo
echo "Publishing is a separate human act. Nothing above uploaded, tagged or announced."
