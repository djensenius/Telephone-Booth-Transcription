#!/usr/bin/env bash
# Rasterize Resources/AppIcon.svg to a complete .icns bundle.
#
# Output: Resources/AppIcon.icns (and the intermediate Resources/AppIcon.iconset/).
#
# Dependencies (any one of):
#   - rsvg-convert  (preferred — sharpest output, `brew install librsvg`)
#   - magick        (ImageMagick — `brew install imagemagick`)
#   - qlmanage      (built into macOS; lower quality but always available)
# Plus iconutil + sips (both shipped with macOS).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
svg="$root/Resources/AppIcon.svg"
iconset="$root/Resources/AppIcon.iconset"
icns="$root/Resources/AppIcon.icns"

if [[ ! -f "$svg" ]]; then
  echo "missing $svg" >&2
  exit 1
fi

rasterizer=""
if command -v rsvg-convert >/dev/null 2>&1; then
  rasterizer="rsvg"
elif command -v magick >/dev/null 2>&1; then
  rasterizer="magick"
elif command -v qlmanage >/dev/null 2>&1; then
  rasterizer="qlmanage"
else
  echo "need rsvg-convert, magick, or qlmanage" >&2
  exit 1
fi

echo "rasterizer: $rasterizer"

rm -rf "$iconset"
mkdir -p "$iconset"

render() {
  local size="$1" out="$2"
  case "$rasterizer" in
    rsvg)
      rsvg-convert -w "$size" -h "$size" "$svg" -o "$out"
      ;;
    magick)
      magick -background none -density 600 -resize "${size}x${size}" "$svg" "$out"
      ;;
    qlmanage)
      local tmp
      tmp="$(mktemp -d)"
      qlmanage -t -s 1024 -o "$tmp" "$svg" >/dev/null
      sips -z "$size" "$size" "$tmp"/*.png --out "$out" >/dev/null
      rm -rf "$tmp"
      ;;
  esac
}

# Sizes required for a complete .icns by iconutil:
#   16, 32, 64, 128, 256, 512, 1024 (the 1024 is "512x512@2x")
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
