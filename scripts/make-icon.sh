#!/usr/bin/env bash
# Render Resources/AppIconSource.png into the macOS icon.
#
# The generated source background is stripped away. The final icon uses the
# gt3pro-style background plus the extracted brushstroke foreground.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
source_png="$root/Resources/AppIconSource.png"
default_reference_background="$HOME/Developer/gt3pro/Icons/scooter-bkgrd.png"
reference_background="${REFERENCE_BACKGROUND:-}"
background="$root/Resources/AppIcon-background.png"
foreground="$root/Resources/AppIcon-foreground.png"
composite="$root/Resources/AppIcon-composite.png"
mask="$root/Resources/.AppIcon-mask.png"
iconset="$root/Resources/AppIcon.iconset"
icns="$root/Resources/AppIcon.icns"

if ! command -v magick >/dev/null 2>&1; then
  echo "magick not found — brew install imagemagick" >&2
  exit 1
fi

if [[ ! -f "$source_png" ]]; then
  echo "missing $source_png" >&2
  exit 1
fi

if [[ -z "$reference_background" && -f "$default_reference_background" ]]; then
  reference_background="$default_reference_background"
fi

if [[ -n "$reference_background" || ! -f "$background" ]]; then
  if [[ ! -f "$reference_background" ]]; then
    echo "missing reference background $reference_background" >&2
    exit 1
  fi
  magick "$reference_background" -resize 1024x1024! -depth 8 "$background"
fi

magick "$source_png" -resize 1024x1024! \
  -alpha off \
  -colorspace Gray \
  -negate \
  -level 34%,82% \
  -blur 0x0.25 \
  "$mask"
magick "$source_png" -resize 1024x1024! "$mask" \
  -compose CopyOpacity \
  -composite \
  -depth 8 \
  "$foreground"
magick "$background" "$foreground" -composite -depth 8 "$composite"
rm -f "$mask"

rm -rf "$iconset"
mkdir -p "$iconset"

render() {
  local size="$1" out="$2"
  magick "$composite" -resize "${size}x${size}!" -depth 8 "$out"
}

declare -a entries=(
  "16    icon_16x16.png"
  "32    icon_16x16@2x.png"
  "32    icon_32x32.png"
  "64    icon_32x32@2x.png"
  "128   icon_128x128.png"
  "256   icon_128x128@2x.png"
  "256   icon_256x256.png"
  "512   icon_256x256@2x.png"
  "512   icon_512x512.png"
  "1024  icon_512x512@2x.png"
)

for entry in "${entries[@]}"; do
  size="${entry%% *}"
  name="${entry##* }"
  render "$size" "$iconset/$name"
done

iconutil -c icns "$iconset" -o "$icns"
echo "wrote $icns"
