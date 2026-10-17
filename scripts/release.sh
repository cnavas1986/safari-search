#!/bin/bash
#
# Builds a Developer ID-signed, notarized "Tab Search.dmg" for sharing.
#
#   scripts/release.sh                 build, sign, notarize, staple
#   scripts/release.sh --no-notarize   build and sign only (quick local check)
#   scripts/release.sh --publish       also create a GitHub Release v<version>
#
# Needs a "Developer ID Application" certificate in the keychain and a
# notarytool profile (default "TabSearch", override with NOTARY_PROFILE):
#   xcrun notarytool store-credentials TabSearch --apple-id <email> --team-id <team>
#
# The version is the app's MARKETING_VERSION. Output goes to build/release/.

set -euo pipefail

NOTARIZE=1
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --publish) PUBLISH=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [[ $PUBLISH == 1 && $NOTARIZE == 0 ]]; then
  echo "--publish needs a notarized build; drop --no-notarize." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Tab Search/Tab Search.xcodeproj"
SCHEME="Tab Search"
APP_NAME="Tab Search"
NOTARY_PROFILE="${NOTARY_PROFILE:-TabSearch}"
OUT="$ROOT/build/release"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# The signing identity and team come from the keychain, so neither is
# hard-coded in the repo.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
if [[ -z "$IDENTITY" ]]; then
  echo "No 'Developer ID Application' certificate found in the keychain." >&2
  echo "Create one in Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 1
fi
TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$IDENTITY")"

VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | sed -n 's/^ *MARKETING_VERSION = //p' | head -1)"
DMG="$OUT/$APP_NAME $VERSION.dmg"

echo "Version:  $VERSION"
echo "Identity: $IDENTITY"

if [[ $PUBLISH == 1 ]] && gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "GitHub Release v$VERSION already exists. Bump MARKETING_VERSION first." >&2
  exit 1
fi

notarize() {
  local file="$1"
  local log="$OUT/notary-$(basename "$file").json"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$log"
  local status id
  status="$(plutil -extract status raw "$log" 2>/dev/null || echo unknown)"
  id="$(plutil -extract id raw "$log" 2>/dev/null || echo)"
  echo "Notarization: $status"
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
    exit 1
  fi
}

rm -rf "$OUT"
mkdir -p "$OUT"

step "Archiving (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$OUT/$APP_NAME.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates \
  archive -quiet

step "Exporting with Developer ID"
cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/$APP_NAME.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
  -allowProvisioningUpdates -quiet
APP="$OUT/export/$APP_NAME.app"

step "Checking signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Captured first: grep -q exiting early would fail the pipe under pipefail.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if ! grep -q "^Authority=Developer ID Application" <<<"$SIGNATURE"; then
  echo "The exported app isn't signed with Developer ID." >&2
  exit 1
fi
grep -E "^Authority=Developer ID Application|^TeamIdentifier" <<<"$SIGNATURE"

if [[ $NOTARIZE == 1 ]]; then
  # Notarize and staple the app itself too, so it still opens offline after
  # being copied out of the disk image.
  step "Notarizing the app (usually a few minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
  notarize "$OUT/$APP_NAME.zip"
  xcrun stapler staple "$APP"
fi

step "Building disk image"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" -quiet
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  step "Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"

  step "Gatekeeper check"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi

if [[ $PUBLISH == 1 ]]; then
  step "Publishing GitHub Release v$VERSION"
  gh release create "v$VERSION" "$DMG" --title "Tab Search $VERSION" --generate-notes
fi

step "Done"
echo "$DMG"
