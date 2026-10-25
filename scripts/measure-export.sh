#!/bin/zsh
# Where an export's time goes: decode, the stage's composite, and the encode, on two sources at a
# Retina display's size — one whose every frame changes, one that barely moves, as most of a
# screen recording does. Prints the machine and the commit above the numbers.
#
#   scripts/measure-export.sh [seconds]      default 10
#
# Needs ffmpeg for the sources. Nothing is written in the repository; the sources and the
# exports are made in a temporary directory and removed.
set -euo pipefail
cd "$(dirname "$0")/.."
unset SDKROOT
seconds=${1:-10}
command -v ffmpeg >/dev/null || { echo "measure-export: ffmpeg is needed to make the sources" >&2; exit 2; }
work=$(mktemp -d -t soredemo-measure-export)
trap 'rm -rf "$work"' EXIT

size=3024x1964
# H.264 from the hardware encoder, as the app records.
ffmpeg -loglevel error -f lavfi -i "testsrc2=size=${size}:rate=60" -t "$seconds" \
  -c:v h264_videotoolbox -b:v 40M -pix_fmt yuv420p "$work/busy.mov"
ffmpeg -loglevel error -f lavfi -i "smptebars=size=${size}:rate=60" \
  -vf "drawbox=x='mod(t*400,2800)':y=900:w=120:h=120:color=black:t=fill" -t "$seconds" \
  -c:v h264_videotoolbox -b:v 20M -pix_fmt yuv420p "$work/calm.mov"

echo "machine: $(sysctl -n machdep.cpu.brand_string), $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "commit:  $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- Core/Sources || echo ' + uncommitted Core/Sources changes')"
echo "build:   swift test, debug — Core Image and the encoder run the same either way; the Swift around them does not"
for movie in busy calm; do
  log="$work/$movie.log"
  if ! SOREDEMO_MEASURE_EXPORT="$work/$movie.mov" swift test --package-path Core \
      --filter exportSpeedBreakdown > "$log" 2>&1; then
    echo "measure-export: the measurement failed on $movie; its log follows" >&2
    tail -40 "$log" >&2
    exit 1
  fi
  grep -q "EXPORT SPEED" "$log" || { echo "measure-export: no measurement printed for $movie" >&2; exit 1; }
  sed -n '/EXPORT SPEED/,/export, ProRes/p' "$log"
done
