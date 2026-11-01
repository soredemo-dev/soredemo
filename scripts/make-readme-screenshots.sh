#!/bin/zsh
# The README's screenshots, taken from the built app rather than mocked: each surface is opened by
# one of the app's own verification flags (--show-notch, --show-countdown,
# --open-video) or by an accessibility press, and captured as its own window. Nothing here sends a
# click or a key, so the app in front is never touched — but the windows do appear on screen for a
# few seconds each.
#
#   scripts/build-app-for-verification.sh && scripts/make-readme-screenshots.sh
#
# The editor needs a picture. It gets the Soredemo website (../soredemo-web/out) scrolled as a
# short clip, so no recording of anybody's screen goes into the repository.
#
# Needs Google Chrome, the Screen Recording grant for screencapture and Accessibility for the
# presses — both held by whatever runs this, not by the app.
set -euo pipefail
cd "$(dirname "$0")/.."
unset SDKROOT

out=docs/screenshots
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
site=../soredemo-web/out
app=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Soredemo-*/Build/Products/Debug/Soredemo.app 2>/dev/null | head -1)
[ -n "$app" ] || { echo "make-readme-screenshots: no built Soredemo.app — run scripts/build-app-for-verification.sh" >&2; exit 1; }
[ -x "$chrome" ] || { echo "make-readme-screenshots: Google Chrome is needed to render the demo clip" >&2; exit 1; }
[ -f "$site/index.html" ] || { echo "make-readme-screenshots: $site/index.html is missing — build the website first" >&2; exit 1; }
# The user's own copy, run from Xcode, would be the window measured — and quitting ours would not
# be the only thing that ended.
if pgrep -f "Soredemo.app/Contents/MacOS/Soredemo" >/dev/null; then
  echo "make-readme-screenshots: Soredemo is already running — quit it first" >&2; exit 1
fi

work=$(mktemp -d -t soredemo-readme-screenshots)
server=""
cleanup() {
  [ -n "$server" ] && kill "$server" 2>/dev/null
  pkill -f "$app/Contents/MacOS/Soredemo" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
xcrun swiftc -O scripts/readme-screenshot-ui.swift -o "$work/ui"

# The website, served on a port nothing else holds (Next's export uses absolute paths, so a
# file:// URL loses its stylesheets), rendered tall, then panned as a 1440 x 900 clip.
port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$site" >/dev/null 2>&1 &
server=$!
sleep 1
"$chrome" --headless=new --hide-scrollbars --virtual-time-budget=6000 --window-size=1440,3600 \
  --screenshot="$work/site.png" "http://127.0.0.1:$port/" >/dev/null 2>&1
[ -s "$work/site.png" ] || { echo "make-readme-screenshots: Chrome rendered nothing" >&2; exit 1; }
xcrun swift - "$work/site.png" "$work/demo.mov" <<'SWIFT' 2>/dev/null
import AVFoundation
import CoreGraphics
import ImageIO
let arguments = CommandLine.arguments
let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil)!
let page = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let width = 1440, height = 900, rate: Int32 = 30
// Where the view rests, a second apart; the moves between are eased.
let stops: [Double] = [0, 0, 560, 560, 1340, 1340, 2280, 2280]
let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: arguments[2]), fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for frame in 0...((stops.count - 1) * Int(rate)) {
    let t = Double(frame) / Double(rate), leg = min(Int(t), stops.count - 2), f = t - Double(leg)
    let y = stops[leg] + (stops[leg + 1] - stops[leg]) * f * f * (3 - 2 * f)
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    CVPixelBufferLockBaseAddress(buffer!, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.draw(page, in: CGRect(x: 0, y: Double(height - page.height) + y,
                                  width: Double(page.width), height: Double(page.height)))
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    while !input.isReadyForMoreMediaData { usleep(1000) }
    adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: rate))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
exit(writer.status == .completed ? 0 : 1)
SWIFT
kill "$server"; server=""

mkdir -p "$out"
pid=""
launch() {  # launch <seconds to settle> <flags…>
  local settle=$1; shift
  # In English, whatever this Mac's language: the README is.
  open -g -n -a "$app" --args -AppleLanguages "(en)" "$@"
  # One instance at a time: with two, the windows listed would be some other launch's.
  for _ in {1..50}; do pid=$(pgrep -n -f "$app/Contents/MacOS/Soredemo" || true); [ -n "$pid" ] && break; sleep 0.2; done
  [ "$(pgrep -f "$app/Contents/MacOS/Soredemo" | wc -l | tr -d ' ')" = 1 ] \
    || { echo "make-readme-screenshots: more than one Soredemo running" >&2; exit 1; }
  [ -n "$pid" ] || { echo "make-readme-screenshots: Soredemo did not start for $*" >&2; exit 1; }
  sleep "$settle"
}
quit() {
  kill "$pid" 2>/dev/null || true
  while pgrep -f "$app/Contents/MacOS/Soredemo" >/dev/null; do sleep 0.2; done
  pid=""
}
# The id of the app's window matching an awk condition over: id layer x y width height — the
# largest when several do. Refuses rather than capturing nothing.
window() {
  # Asked again for up to five seconds: a window can take a moment longer on one launch.
  local id=""
  for _ in {1..25}; do
    id=$("$work/ui" windows "$pid" | awk "$1 { a = \$5 * \$6; if (a > best) { best = a; id = \$1 } } END { print id }")
    [ -n "$id" ] && break
    sleep 0.2
  done
  [ -n "$id" ] || { echo "make-readme-screenshots: no window where $1" >&2; "$work/ui" windows "$pid" >&2; exit 1; }
  echo "$id"
}
shoot() {  # shoot <window id> <name> [widest]
  [ -n "$1" ] || exit 1
  screencapture -x -l "$1" "$out/$2.png"
  [ -s "$out/$2.png" ] || { echo "make-readme-screenshots: nothing captured for $2" >&2; exit 1; }
  # A whole window at Retina scale is megabytes in git for detail a README cannot show.
  [ -z "${3:-}" ] || sips -Z "$3" "$out/$2.png" >/dev/null
  echo "  $out/$2.png"
}

# The notch, one state at a time. Its panel sits at the top of the screen at a status level.
for state in glance open live-expanded finished; do
  launch 2 --show-notch "$state"
  shoot "$(window '$4 == 0 && $2 > 0')" "notch-$state"
  quit
done

# The countdown, a second in: the ring part drained round the record eye.
launch 1.6 --show-countdown 5
shoot "$(window '$2 > 0')" countdown
quit

# **Not the floating recording bar**: on a Mac with a notch the notch hosts the take, and the
# bar draws nothing (`NotchSurfacePresenter.hostsTheTake`).

# **Not the menu bar's panel.** On a Mac with a notch the status item is often among those the
# menu bar hides, and it is not in the accessibility tree either; the open notch shows the same
# choices.
# The editor on the clip, a few seconds in, and its export settings.
launch 7 --open-video "$work/demo.mov"
editor=$(window '$2 == 0')
shoot "$editor" editor 1800
"$work/ui" press "$pid" "Export…"
sleep 1.5
shoot "$(window "\$2 == 0 && \$1 != $editor")" export-settings 1800
quit

echo "make-readme-screenshots: $(ls "$out"/*.png | wc -l | tr -d ' ') screenshots in $out"
