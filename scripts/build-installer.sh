#!/usr/bin/env bash
# Builds the native macOS installer wizard at Installer/build/Loam Installer.app, with Loam.app inside it as the
# payload it installs. macOS only. Usage: build-installer.sh [debug|release]
#
#   Contents/MacOS/LoamInstaller            the wizard
#   Contents/Resources/Payload/Loam.app      the app it installs (built and signed by build-app.sh)
#   Contents/Resources/Loam.icns             the icon
#
# The wizard copies the payload to /Applications (or ~/Applications), links the `loam` command line into ~/.local/bin
# and opens the app: what the install script does, natively. A zip and a dmg land in Installer/build/dist/.
set -euo pipefail
[ -n "${LOAM_BUILD_LOCKED:-}" ] || LOAM_BUILD_LANE=app exec "$(dirname "$0")/build-lock.sh" "$0" "$@"
cd "$(dirname "$0")/.."
root="$PWD"

config="${1:-release}"
version="${LOAM_VERSION:-$(cat "$root/VERSION")}"

echo "== Loam.app ($config)"
LOAM_RELEASE="${LOAM_RELEASE:-1}" "$root/scripts/build-app.sh" "$config"

echo "== The wizard"
swift build -c "$config" --package-path Installer
bin="$(swift build -c "$config" --package-path Installer --show-bin-path)"

app="$root/Installer/build/Loam Installer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Payload"
cp "$bin/LoamInstaller" "$app/Contents/MacOS/LoamInstaller"
cp -R "$root/App/build/Loam.app" "$app/Contents/Resources/Payload/Loam.app"
cp "$root/App/Resources/Loam.icns" "$app/Contents/Resources/"
cp "$root/LICENSE" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Loam Installer</string>
    <key>CFBundleDisplayName</key><string>Install Loam</string>
    <key>CFBundleIdentifier</key><string>com.azilone.loam.installer</string>
    <key>CFBundleExecutable</key><string>LoamInstaller</string>
    <key>CFBundleIconFile</key><string>Loam</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The wizard is signed ad hoc: the payload it carries was signed by build-app.sh, and its own signature travels
# with it when the wizard copies it.
codesign --force --sign - "$app" >/dev/null 2>&1
codesign --verify --strict "$app"

dist="$root/Installer/build/dist"
mkdir -p "$dist"
rm -f "$dist/Loam Installer-$version.zip" "$dist/Loam Installer.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/Loam Installer-$version.zip"
hdiutil create -volname "Loam Installer" -srcfolder "$app" -ov -format UDZO "$dist/Loam Installer.dmg" >/dev/null

echo "Built $app"
echo "  zip: $dist/Loam Installer-$version.zip"
echo "  dmg: $dist/Loam Installer.dmg"
