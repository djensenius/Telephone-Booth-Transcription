#!/usr/bin/env bash
# Render Resources/AppIconSource.png into the unified app-icon asset catalog.
#
# macOS 26 (Tahoe) and iOS 18+ both mask, round, and apply Liquid Glass to a
# *full-bleed* icon supplied through an asset catalog — the app must NOT bake
# its own rounded rectangle (doing so lands the macOS icon in "squircle jail":
# a flat hard-rounded square that ignores the system's Liquid Glass treatment).
# So we emit one appiconset, shared by both targets, holding full-bleed icon
# families: the iOS single-size 1024 "universal" format (light / dark / tinted)
# and a single full-bleed `mac` idiom 1024 (declared 512x512@2x, the largest
# slot actool accepts for the mac idiom) that compiles into Assets.car +
# AppIcon.icns. A pure "universal" icon with no platform is left *unassigned*
# for the macOS target by actool (the app would ship with no icon at all), so
# the mac idiom entry is required.
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
appiconset="$root/Resources/Assets.xcassets/AppIcon.appiconset"

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

# Extract the brushstroke as a foreground with a transparent field.
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

# Light appearance: gt3pro background + ink brushstroke.
magick "$background" "$foreground" -composite -depth 8 "$composite"

# Dark appearance: dimmed background, white brushstroke so the ink stays
# legible on a dark field. Tinted appearance: white brushstroke on black for
# the system to colourise.
dark_composite="$root/Resources/AppIcon-dark.png"
tinted_composite="$root/Resources/AppIcon-tinted.png"
fg_white="$root/Resources/.AppIcon-fg-white.png"
bg_dark="$root/Resources/.AppIcon-bg-dark.png"

magick "$foreground" -fill white -colorize 100% -depth 8 "$fg_white"
magick "$background" -modulate 10 -depth 8 "$bg_dark"
magick "$bg_dark" "$fg_white" -compose over -composite -depth 8 "$dark_composite"
magick -size 1024x1024 xc:black "$fg_white" -compose over -composite \
  -colorspace sRGB -depth 8 "$tinted_composite"

rm -f "$mask" "$fg_white" "$bg_dark"

# Emit a single full-bleed 1024 app icon (light / dark / tinted) shared by the
# macOS + iOS targets. This is the modern Xcode 26 / macOS 26 (Tahoe)
# single-size app-icon format: the system masks the full-bleed art and applies
# its own Liquid Glass treatment on both platforms.
#
# The previous build shipped a legacy multi-size `mac` idiom iconset
# (16…512 @1x/@2x). On macOS 26 that legacy path bypasses Liquid Glass and
# lands the icon in "squircle jail" (a flat hard-rounded square). We replace it
# with a single full-bleed 1024 `mac` entry so macOS applies Liquid Glass
# itself. The art stays full-bleed — no hand-baked rounding. (macOS only takes
# the light appearance; dark / tinted variants are iOS-only.)
mkdir -p "$appiconset"
magick "$composite" -resize 1024x1024! -depth 8 "$appiconset/AppIcon-light-1024.png"
magick "$dark_composite" -resize 1024x1024! -depth 8 "$appiconset/AppIcon-dark-1024.png"
magick "$tinted_composite" -resize 1024x1024! -depth 8 "$appiconset/AppIcon-tinted-1024.png"

# Remove any stale legacy mac-idiom renditions from earlier runs.
rm -f "$appiconset"/AppIcon-mac-*.png

cat > "$appiconset/Contents.json" <<JSON
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
    },
    {
      "filename" : "AppIcon-light-1024.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "wrote $appiconset"
