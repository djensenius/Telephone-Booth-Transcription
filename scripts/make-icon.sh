#!/usr/bin/env bash
# Render Resources/AppIconSource.png into the unified app-icon asset catalog.
#
# iOS uses the modern single-size 1024 icon format with light / dark / tinted
# appearances. macOS still gets the complete `mac` idiom size set like the
# sibling Telephone-Booth-Mobile macOS app so actool emits a proper AppIcon.icns.
#
# The generated source background is stripped away. The final icon uses the
# gt3pro-style background plus the extracted brushstroke foreground.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
source_png="$root/Resources/AppIconSource.png"
reference_background="${REFERENCE_BACKGROUND:-}"
warm_background="#E8D5B7"
background="$root/Resources/AppIcon-background.png"
foreground="$root/Resources/AppIcon-foreground.png"
composite="$root/Resources/AppIcon-composite.png"
mask="$root/Resources/.AppIcon-mask.png"
appiconset="$root/Resources/Assets.xcassets/AppIcon.appiconset"
icon_composer="$root/Resources/AppIcon.icon"
icon_composer_assets="$icon_composer/Assets"

if ! command -v magick >/dev/null 2>&1; then
  echo "magick not found — brew install imagemagick" >&2
  exit 1
fi

if [[ ! -f "$source_png" ]]; then
  echo "missing $source_png" >&2
  exit 1
fi

if [[ -n "$reference_background" ]]; then
  if [[ ! -f "$reference_background" ]]; then
    echo "missing reference background $reference_background" >&2
    exit 1
  fi
  magick "$reference_background" -resize 1024x1024! -depth 8 "$background"
else
  magick -size 1024x1024 "xc:$warm_background" -depth 8 "$background"
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
magick "$background" -modulate 22 -depth 8 "$bg_dark"
magick "$bg_dark" "$fg_white" -compose over -composite -depth 8 "$dark_composite"
magick -size 1024x1024 xc:black "$fg_white" -compose over -composite \
  -colorspace sRGB -depth 8 "$tinted_composite"

rm -f "$mask" "$fg_white" "$bg_dark"

# Emit the iOS 26 appiconset: light / dark / tinted single-size entries.
# macOS 26 uses Resources/AppIcon.icon below instead.
mkdir -p "$appiconset"
magick "$composite" -resize 1024x1024! -depth 8 "$appiconset/AppIcon-light-1024.png"
magick "$dark_composite" -resize 1024x1024! -depth 8 "$appiconset/AppIcon-dark-1024.png"
magick "$tinted_composite" -resize 1024x1024! -depth 8 "$appiconset/AppIcon-tinted-1024.png"

# Remove stale mac-idiom renditions from earlier generator versions. macOS is
# 26+ only and uses the Icon Composer document, not legacy appiconset PNGs.
rm -f "$appiconset"/AppIcon-mac-*.png "$appiconset"/icon_*.png

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
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

# Emit the macOS 26 Liquid Glass icon. Xcode 26 prefers an Icon Composer
# document named AppIcon.icon over the legacy AppIcon.appiconset for macOS.
# The background belongs in Icon Composer's document fill, not in a flattened
# PNG layer. Foreground art is cropped so Icon Composer can center it as a real
# layer instead of treating a 1024px transparent canvas as the foreground.
rm -rf "$icon_composer"
mkdir -p "$icon_composer_assets"
magick "$foreground" -trim +repage -resize 720x -depth 8 "$icon_composer_assets/brushstroke.png"
cat > "$icon_composer/icon.json" <<JSON
{
  "color-space-for-untagged-svg-colors" : "display-p3",
  "fill" : {
    "linear-gradient" : [
      "srgb:0.94902,0.88235,0.75294,1.00000",
      "srgb:0.85098,0.74902,0.58431,1.00000"
    ]
  },
  "groups" : [
    {
      "blend-mode" : "normal",
      "layers" : [
        {
          "blend-mode" : "normal",
          "fill" : "automatic",
          "glass" : true,
          "hidden" : false,
          "image-name" : "brushstroke.png",
          "name" : "Brushstroke"
        }
      ],
      "lighting" : "individual",
      "name" : "Brushstroke",
      "shadow" : {
        "kind" : "layer-color",
        "opacity" : 0.35
      },
      "specular" : true,
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "circles" : [
      "watchOS"
    ],
    "squares" : "shared"
  }
}
JSON

echo "wrote $appiconset"
echo "wrote $icon_composer"
