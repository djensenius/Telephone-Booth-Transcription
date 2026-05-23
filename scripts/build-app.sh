#!/usr/bin/env bash
# Builds a real macOS .app bundle around the SwiftPM executable.
#
# Output: ./build/Telephone Booth Transcription.app
#
# Not codesigned / notarized — for local use or as a CI artifact. To distribute,
# run `codesign --deep --options runtime --sign "Developer ID Application: ..."`
# and `xcrun notarytool submit ...` separately; we deliberately do not bake
# Apple secrets into this scaffolding.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

config="${CONFIG:-release}"
exe_name="telephone-booth-transcription"
app_name="Telephone Booth Transcription"
bundle_id="dev.djensenius.telephone-booth-transcription"
version="0.1.0"

echo "▶ swift build -c $config"
swift build -c "$config"

binary_path="$(swift build -c "$config" --show-bin-path)/$exe_name"
if [[ ! -x "$binary_path" ]]; then
  echo "missing built binary at $binary_path" >&2
  exit 1
fi

if [[ ! -f "Resources/AppIcon.icns" ]]; then
  echo "▶ Resources/AppIcon.icns not found, generating"
  ./scripts/make-icon.sh
fi

out_dir="$root/build"
app="$out_dir/$app_name.app"
echo "▶ assembling $app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"

cp "$binary_path" "$app/Contents/MacOS/$exe_name"
cp "Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>en</string>
    <key>CFBundleExecutable</key>                 <string>$exe_name</string>
    <key>CFBundleIconFile</key>                   <string>AppIcon</string>
    <key>CFBundleIdentifier</key>                 <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
    <key>CFBundleName</key>                       <string>$app_name</string>
    <key>CFBundleDisplayName</key>                <string>$app_name</string>
    <key>CFBundlePackageType</key>                <string>APPL</string>
    <key>CFBundleShortVersionString</key>         <string>$version</string>
    <key>CFBundleVersion</key>                    <string>$version</string>
    <key>LSMinimumSystemVersion</key>             <string>26.0</string>
    <key>LSApplicationCategoryType</key>          <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>            <true/>
    <key>NSHumanReadableCopyright</key>           <string>© David Jensenius</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Transcription Booth uses on-device speech recognition to convert audio to text when the built-in macOS transcription backend is selected.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Transcription Booth needs microphone access only if you point a client at the macOS Speech backend with a live audio source.</string>
</dict>
</plist>
PLIST

# Apply ad-hoc signature so the binary is launchable on the build machine.
codesign --force --sign - "$app" >/dev/null 2>&1 || true

echo "✅ wrote $app"
