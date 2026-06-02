#!/usr/bin/env bash
# Render Resources/AppIconSource.png into the unified app-icon asset catalog.
#
# macOS 26 (Tahoe) and iOS 18+ both mask, round, and apply Liquid Glass to a
# *full-bleed* icon supplied through an asset catalog — the app must NOT bake
# its own rounded rectangle (doing so lands the macOS icon in "squircle jail":
# a flat hard-rounded square that ignores the system's Liquid Glass treatment).
# So we emit one appiconset, shared by both targets, holding two full-bleed icon
# families: the iOS single-size 1024 "universal" format (light / dark / tinted)
# and the macOS multi-size `mac` idiom iconset that actool compiles into
# Assets.car + AppIcon.icns.
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

# Emit the appiconset shared by the macOS + iOS targets. Two icon families live
# side by side in one set:
#
#   * iOS  — the modern single-size 1024 "universal" format (platform: ios) with
#     light / dark / tinted appearances. iOS masks + Liquid-Glasses the
#     full-bleed art itself.
#   * macOS — the traditional multi-size `mac` idiom iconset (16…512 @1x/@2x).
#     This is the format every sibling Mac app (gt3pro, Rhizome, FluxHaus) ships
#     and the one actool actually compiles into Assets.car + AppIcon.icns on
#     macOS 26. Shipping a bare `.icns` via CFBundleIconFile is what lands the
#     icon in "squircle jail"; routing it through a `mac` idiom catalog lets
#     Tahoe apply its own Liquid Glass mask. The art stays full-bleed — no
#     hand-baked rounding.
#
# actool filters each entry by platform, so the iOS slots are ignored on a macOS
# build and vice versa, with no "unassigned children" warnings.
mkdir -p "$appiconset"
magick "$composite" -resize 1024x1024! -depth 8 "$appiconset/AppIcon-light-1024.png"
magick "$dark_composite" -resize 1024x1024! -depth 8 "$appiconset/AppIcon-dark-1024.png"
magick "$tinted_composite" -resize 1024x1024! -depth 8 "$appiconset/AppIcon-tinted-1024.png"

# macOS multi-size renditions, derived from the light composite.
mac_images=""
for size in 16 32 128 256 512; do
  px1=$size
  px2=$((size * 2))
  magick "$composite" -resize ${px1}x${px1}! -depth 8 "$appiconset/AppIcon-mac-${size}.png"
  magick "$composite" -resize ${px2}x${px2}! -depth 8 "$appiconset/AppIcon-mac-${size}@2x.png"
  mac_images="$mac_images
    {
      \"filename\" : \"AppIcon-mac-${size}.png\",
      \"idiom\" : \"mac\",
      \"scale\" : \"1x\",
      \"size\" : \"${size}x${size}\"
    },
    {
      \"filename\" : \"AppIcon-mac-${size}@2x.png\",
      \"idiom\" : \"mac\",
      \"scale\" : \"2x\",
      \"size\" : \"${size}x${size}\"
    },"
done

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
    },${mac_images%,}
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "wrote $appiconset"
