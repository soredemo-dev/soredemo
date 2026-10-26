#!/bin/zsh
# The brand kit in assets/, drawn from the app's own daruma figure (Core's DarumaFigure), so the
# website's mark and the app's are one geometry. Writes the SVGs through a Core test, puts the new
# character into the wordmarks and lockups in place of the old mark, rasterises the PNGs with
# Chrome, builds the favicon, and removes the old logomark files.
#
#   scripts/make-character-assets.sh
#
# Needs Google Chrome (for the PNGs). The old files are in git; nothing here is unrecoverable.
set -euo pipefail
# Re-runnable: a pattern that matches nothing (the old files already gone) is not an error.
setopt null_glob
cd "$(dirname "$0")/.."
unset SDKROOT
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$chrome" ] || { echo "make-character-assets: Google Chrome is needed to rasterise the PNGs" >&2; exit 2; }
work=$(mktemp -d -t soredemo-character-assets)
trap 'rm -rf "$work"' EXIT

SOREDEMO_MAKE_CHARACTER_ASSETS="$work/kit" swift test --package-path Core --filter makeCharacterAssets > "$work/test.log" 2>&1 \
  || { tail -30 "$work/test.log" >&2; exit 1; }
[ -f "$work/kit/svg/soredemo-character.svg" ] || { echo "make-character-assets: the generator wrote nothing" >&2; exit 1; }

# The old mark goes; the wordmarks and lockups are edited in place below.
rm -f assets/svg/soredemo-logomark*.svg assets/png/logomark/soredemo-logomark-*.png assets/svg/soredemo-character*.svg assets/svg/soredemo-app-icon*.svg
rm -f assets/png/soredemo-app-icon*.png
rm -rf assets/svg/expressions assets/svg/colours assets/png/character assets/png/logomark
cp -R "$work/kit/svg/." assets/svg/

python3 -I - "$work" <<'PY'
import re, sys, pathlib
work = pathlib.Path(sys.argv[1])
def group(name):
    text = (work / 'kit/svg' / name).read_text()
    return re.search(r'<svg[^>]*>(.*)</svg>', text, re.S).group(1)
ink = paper = group('soredemo-character.svg')
# Each wordmark and lockup opens with the mark as one group placed by a translate and a scale;
# the character takes its place at the same scale, centred on its own body (50, 52).
for name in ['soredemo-wordmark', 'soredemo-japanese-wordmark', 'soredemo-horizontal-lockup']:
    for colour, mark in [('black', ink), ('white', paper)]:
        path = pathlib.Path(f'assets/svg/{name}-{colour}.svg')
        text = path.read_text()
        new, count = re.subn(r'<g transform="translate\(([\d.]+) ([\d.]+)\) scale\(([\d.]+)\) translate\(-50 -5\d\)">.*?</g>(?=<path d="m)',
                             lambda m: f'<g transform="translate({m[1]} {m[2]}) scale({m[3]}) translate(-50 -52)">{mark}</g>', text, count=1, flags=re.S)
        if count != 1:
            sys.exit(f'make-character-assets: no mark group found in {path}')
        path.write_text(new)
PY

# One PNG per SVG: rendered by Chrome at the size the SVG names (scaled up for small ones, then
# reduced), on a transparent ground.
render() {  # render <svg> <png> <width> <height>
  local src=$1 dst=$2 w=$3 h=$4 big=$(( $3 < 512 ? 4 : 1 ))
  python3 -I - "$src" "$work/r.svg" $(( w * big )) $(( h * big )) <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'width="[\d.]+" height="[\d.]+"', f'width="{sys.argv[3]}" height="{sys.argv[4]}"', s, count=1)
open(sys.argv[2], 'w').write(s)
PY
  "$chrome" --headless=new --hide-scrollbars --default-background-color=00000000 \
    --window-size=$(( w * big )),$(( h * big )) --screenshot="$dst" "file://$work/r.svg" >/dev/null 2>&1
  [ -s "$dst" ] || { echo "make-character-assets: Chrome rendered nothing for $src" >&2; exit 1; }
  [ $big -eq 1 ] || sips -z $h $w "$dst" >/dev/null
}
mkdir -p assets/png/character assets/png/menubar assets/favicon
for source in assets/svg/soredemo-character.svg assets/svg/soredemo-character-black.svg assets/svg/soredemo-character-white.svg assets/svg/colours/*.svg; do
  for size in 32 64 128 256 512 1024 2048; do
    render "$source" "assets/png/character/$(basename "${source%.svg}")-$size.png" $size $size
  done
done
for expression in assets/svg/expressions/*.svg; do
  render "$expression" "assets/png/character/$(basename "${expression%.svg}")-512.png" 512 512
done
render assets/svg/soredemo-app-icon.svg assets/png/soredemo-app-icon-1024.png 1024 1024
render assets/svg/soredemo-app-icon-ink.svg assets/png/soredemo-app-icon-ink-1024.png 1024 1024
render assets/svg/soredemo-app-icon-bare.svg assets/png/soredemo-app-icon-bare-1024.png 1024 1024
render assets/svg/soredemo-menubar-template.svg assets/png/menubar/menubarTemplate.png 18 18
render assets/svg/soredemo-menubar-template.svg assets/png/menubar/menubarTemplate@2x.png 36 36
for size in 16 32 48 64 128 256 512; do
  render assets/svg/soredemo-favicon.svg assets/favicon/favicon-$size.png $size $size
done
cp assets/svg/soredemo-favicon.svg assets/favicon/favicon.svg
for name in soredemo-wordmark soredemo-japanese-wordmark soredemo-horizontal-lockup; do
  for colour in black white; do
    dims=$(grep -o 'width="[0-9]*" height="[0-9]*"' assets/svg/$name-$colour.svg | head -1 | tr -dc '0-9 ')
    render assets/svg/$name-$colour.svg assets/png/$name-$colour.png ${=dims}
  done
done

# The app's own icon: Icon Composer's two layers, the fallback set's ten sizes, and one image per
# icon a person can choose (AppIconChoice) — the face window's for Settings' thumbnail.
cp "$work/kit/icon/body.svg" "$work/kit/icon/eyes.svg" Soredemo/Resources/AppIcon.icon/Assets/
set=Soredemo/Resources/Assets.xcassets/AppIcon.appiconset
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 256:icon_128x128@2x \
            256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  render assets/svg/soredemo-app-icon.svg "$set/${spec#*:}.png" ${spec%%:*} ${spec%%:*}
done
rm -rf Soredemo/Resources/Assets.xcassets/AppIconVermilion.imageset
for spec in Window: Bare:-bare Ink:-ink; do
  alt=Soredemo/Resources/Assets.xcassets/AppIcon${spec%%:*}.imageset suffix=${spec#*:}
  mkdir -p $alt
  render assets/svg/soredemo-app-icon$suffix.svg $alt/app-icon-512.png 512 512
  render assets/svg/soredemo-app-icon$suffix.svg $alt/app-icon-1024.png 1024 1024
  rm -f $alt/app-icon-ink-512.png $alt/app-icon-ink-1024.png
  cat > $alt/Contents.json <<'JSON'
{
  "images" : [
    { "filename" : "app-icon-512.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "app-icon-1024.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "original" }
}
JSON
done

# favicon.ico: the 16–256 PNGs, each stored whole (an ICO may carry PNG images).
python3 -I - <<'PY'
import struct, pathlib
sizes = [16, 32, 48, 64, 128, 256]
images = [pathlib.Path(f'assets/favicon/favicon-{s}.png').read_bytes() for s in sizes]
header = struct.pack('<HHH', 0, 1, len(images))
offset = 6 + 16 * len(images)
entries, blobs = b'', b''
for size, data in zip(sizes, images):
    entries += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset + len(blobs))
    blobs += data
pathlib.Path('assets/favicon/favicon.ico').write_bytes(header + entries + blobs)
PY

# The preview: every colour and expression on light and dark.
python3 -I - "$work/preview.html" <<'PY'
import sys, pathlib, re
def inner(p): return re.search(r'<svg[^>]*>(.*)</svg>', pathlib.Path(p).read_text(), re.S).group(1)
def tile(p): return f'<svg viewBox="0 0 100 100" width="150" height="150">{inner(p)}</svg>'
colours = ['colours/soredemo-character-shu', 'colours/soredemo-character-ink', 'colours/soredemo-character-gold',
           'colours/soredemo-character-shu-bare', 'colours/soredemo-character-ink-bare', 'colours/soredemo-character-gold-bare']
faces = sorted(pathlib.Path('assets/svg/expressions').glob('*.svg'))
row = lambda items: '<div class="r">' + ''.join(tile(i) for i in items) + '</div>'
html = ('<html><body style="margin:0;font:600 28px -apple-system;background:#F4F3EF">'
        '<style>.r{display:flex;gap:28px;padding:20px 48px}.d{background:#16171B;color:#F4F3EF}h{display:block;padding:36px 48px 0}</style>'
        '<h>Soredemo — the daruma</h>' + row([f'assets/svg/{c}.svg' for c in colours]) + row(faces)
        + '<div class="d"><h>On dark</h>' + row([f'assets/svg/colours/soredemo-character-{c}.svg' for c in ['shu', 'paper', 'gold', 'shu-bare', 'paper-bare', 'gold-bare']] + ['assets/svg/soredemo-character-white.svg']) + '</div></body></html>')
pathlib.Path(sys.argv[1]).write_text(html)
PY
mkdir -p assets/preview
"$chrome" --headless=new --hide-scrollbars --window-size=1700,1100 --screenshot=assets/preview/soredemo-brand-preview.png "file://$work/preview.html" >/dev/null 2>&1
echo "make-character-assets: $(find assets -type f | wc -l | tr -d ' ') files in assets/"
