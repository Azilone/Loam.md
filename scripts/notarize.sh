#!/usr/bin/env bash
# Builds a release of Loam.app others can open: signed with a Developer ID under the hardened runtime, notarized by
# Apple, stapled, zipped at dist/Loam-<version>.zip. Usage: make dist
#
# Needs, once: an Apple Developer account, its "Developer ID Application" certificate in the login keychain, and a
# notarytool profile (xcrun notarytool store-credentials loam-notary --apple-id … --team-id … --password …).
#   LOAM_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   LOAM_NOTARY_PROFILE  the profile's name (default loam-notary)
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

identity="${LOAM_SIGN_IDENTITY:-}"
profile="${LOAM_NOTARY_PROFILE:-loam-notary}"
if [ -z "$identity" ]; then
  echo "notarize: set LOAM_SIGN_IDENTITY to your \"Developer ID Application: …\" certificate (security find-identity -v -p codesigning)" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -qF "$identity"; then
  echo "notarize: no codesigning identity \"$identity\" in the keychain" >&2
  exit 1
fi

./scripts/build-app.sh release
app="$root/App/build/Loam.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"

# Inside out, as build-app.sh does, now with the identity, a secure timestamp and the hardened runtime.
sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
for library in "$app"/Contents/Frameworks/*.dylib; do sign "$library"; done
sign "$app/Contents/Helpers/loam"
sign --entitlements "$root/App/Loam.entitlements" "$app"
codesign --verify --strict --deep "$app"

mkdir -p dist
upload="$(mktemp -d)/Loam.zip"
ditto -c -k --keepParent "$app" "$upload"
xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"

zip="dist/Loam-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "Notarized $root/$zip"
