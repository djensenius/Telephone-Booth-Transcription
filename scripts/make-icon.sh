#!/usr/bin/env bash
# Render Resources/AppIconSource.png into app icon assets.
#
# iOS uses the modern single-size 1024 icon format with light / dark / tinted
# appearances for fallback compatibility. iOS 26 and macOS 26 use the layered
# Icon Composer document at Resources/AppIcon.icon.
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

# Dark appearance uses a muted copper stroke on warm charcoal. It stays within
# the ink-and-paper palette without the harsh white-on-black inversion.
dark_composite="$root/Resources/AppIcon-dark.png"
tinted_composite="$root/Resources/AppIcon-tinted.png"
fg_white="$root/Resources/.AppIcon-fg-white.png"
fg_dark="$root/Resources/.AppIcon-fg-dark.png"

magick "$foreground" -fill white -colorize 100% -depth 8 "$fg_white"
magick "$foreground" -fill "#C99B63" -colorize 100% -depth 8 "$fg_dark"
magick -size 1024x1024 "xc:#29231F" "$fg_dark" -compose over -composite \
  -alpha remove -alpha off -depth 8 "$dark_composite"
magick -size 1024x1024 xc:black "$fg_white" -compose over -composite \
  -colorspace sRGB -depth 8 "$tinted_composite"

rm -f "$mask" "$fg_white" "$fg_dark"

# Emit the iOS fallback appiconset: light / dark / tinted single-size entries.
# iOS 26 and macOS 26 use Resources/AppIcon.icon below.
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

# Emit the iOS/macOS 26 Liquid Glass icon. Xcode 26/actool compile the Icon
# Composer document into Assets.car for the new layered icon system.
# The background belongs in Icon Composer's document fill, not in a flattened
# PNG layer. Foreground art is cropped so Icon Composer can center it as a real
# layer instead of treating a 1024px transparent canvas as the foreground.
rm -rf "$icon_composer"
mkdir -p "$icon_composer_assets"
magick "$foreground" -trim +repage -resize 720x -depth 8 "$icon_composer_assets/brushstroke.png"
cat > "$icon_composer/icon.json" <<JSON
{
  "color-space-for-untagged-svg-colors" : "display-p3",
  "fill-specializations" : [
    {
      "value" : {
        "linear-gradient" : [
          "srgb:0.94902,0.88235,0.75294,1.00000",
          "srgb:0.85098,0.74902,0.58431,1.00000"
        ]
      }
    },
    {
      "appearance" : "dark",
      "value" : {
        "solid" : "srgb:0.16078,0.13725,0.12157,1.00000"
      }
    }
  ],
  "groups" : [
    {
      "blend-mode" : "normal",
      "layers" : [
        {
          "blend-mode" : "normal",
          "fill-specializations" : [
            {
              "value" : "automatic"
            },
            {
              "appearance" : "dark",
              "value" : {
                "solid" : "srgb:0.78824,0.60784,0.38824,1.00000"
              }
            }
          ],
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
