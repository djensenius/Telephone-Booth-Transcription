#!/usr/bin/env bash
# Builds the real macOS .app bundle from the Xcode project.
#
# Output: ./build/Transcriber.app
#
# Ad-hoc/no-signing build for local use or as a CI artifact. To distribute,
# run `codesign --deep --options runtime --sign "Developer ID Application: ..."`
# and `xcrun notarytool submit ...` separately; we deliberately do not bake
# Apple secrets into this scaffolding.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

config="${CONFIG:-Release}"
app_name="Transcriber"
project="TelephoneBoothTranscription.xcodeproj"
scheme="TranscriptionApp"
derived="$root/build/DerivedData"

if [[ -f "project.yml" && -x "$(command -v xcodegen || true)" ]]; then
  echo "▶ xcodegen generate"
  xcodegen generate --spec project.yml
fi

if [[ ! -f "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-light-1024.png" \
   || ! -f "Resources/AppIcon.icon/icon.json" ]]; then
  echo "▶ app icon assets not found, generating"
  ./scripts/make-icon.sh
fi

out_dir="$root/build"
app="$out_dir/$app_name.app"
echo "▶ xcodebuild $scheme ($config)"
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=safe.bareRepository \
GIT_CONFIG_VALUE_0=all \
xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -configuration "$config" \
  -derivedDataPath "$derived" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM= \
  build

rm -rf "$app"
mkdir -p "$out_dir"

product="$derived/Build/Products/$config/$app_name.app"
if [[ ! -d "$product" ]]; then
  echo "missing built app at $product" >&2
  exit 1
fi

cp -R "$product" "$app"

plist="$app/Contents/Info.plist"
if [[ -f "$plist" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$plist"
fi

echo "✅ wrote $app"
