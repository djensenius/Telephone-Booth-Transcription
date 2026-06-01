#!/usr/bin/env bash
# Render the iOS app icon appearance variants (Light / Dark / Tinted) into
# Resources/Assets.xcassets/AppIcon.appiconset.
#
# The variants are derived from the same sumi-ink brush-stroke source used by
# scripts/make-icon.sh:
#   - Light:   the warm-background composite (black brush stroke on warm paper).
#   - Dark:    the brush stroke recoloured to warm off-white on a dark ground.
#   - Tinted:  a grayscale luminance mask (light stroke on black) that the system
#              recolours with the user's chosen tint.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
composite="$root/Resources/AppIcon-composite.png"
foreground="$root/Resources/AppIcon-foreground.png"
appiconset="$root/Resources/Assets.xcassets/AppIcon.appiconset"

if ! command -v magick >/dev/null 2>&1; then
  echo "magick not found — brew install imagemagick" >&2
  exit 1
fi

for f in "$composite" "$foreground"; do
  if [[ ! -f "$f" ]]; then
    echo "missing $f — run scripts/make-icon.sh first" >&2
    exit 1
  fi
done

mkdir -p "$appiconset"

# Light: warm-paper composite, flattened (iOS icons must be fully opaque).
magick "$composite" -resize 1024x1024! -alpha remove -alpha off -depth 8 \
  "$appiconset/AppIcon-light-1024.png"

# Dark: warm off-white brush stroke on a dark warm ground.
# Extract the stroke alpha, paint it off-white, then flatten on a dark ground.
magick "$foreground" -resize 1024x1024! -alpha extract "$appiconset/.alpha.png"
magick -size 1024x1024 "xc:#efe6d6" "$appiconset/.alpha.png" \
  -alpha off -compose CopyOpacity -composite "$appiconset/.stroke.png"
magick -size 1024x1024 "xc:#1c1814" "$appiconset/.stroke.png" -composite \
  -alpha remove -alpha off -depth 8 \
  "$appiconset/AppIcon-dark-1024.png"

# Tinted: grayscale luminance mask — light stroke on black, system applies tint.
magick -size 1024x1024 "xc:black" "$appiconset/.alpha.png" \
  -compose CopyOpacity -composite -background black -alpha remove -alpha off \
  -colorspace Gray -depth 8 \
  "$appiconset/AppIcon-tinted-1024.png"

rm -f "$appiconset/.alpha.png" "$appiconset/.stroke.png"

cat > "$appiconset/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon-light-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIcon-dark-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "AppIcon-tinted-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "wrote $appiconset"
