#!/bin/zsh
# Builds a notarized disk image: build/PenDriver-<version>.dmg (version from Resources/Info.plist).
#   --publish        also create a draft GitHub release v<version> with the DMG attached (needs gh)
#   --no-notarize    stop before notarizing, to check the build and the disk image locally
#
# Notarization reads credentials stored in the keychain once with:
#   xcrun notarytool store-credentials pen-driver --apple-id <apple-id> --team-id <team-id>
# (it asks for an app-specific password from account.apple.com). PEN_DRIVER_NOTARY_PROFILE picks
# another profile name.
set -euo pipefail
cd "${0:A:h}/.."

PUBLISH=0; NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
(( PUBLISH && !NOTARIZE )) && { echo "--publish needs notarization." >&2; exit 2; }

PROFILE="${PEN_DRIVER_NOTARY_PROFILE:-pen-driver}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
APP="build/Pen Driver.app"
DMG="build/PenDriver-$VERSION.dmg"

if (( PUBLISH )); then
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first." >&2; exit 1; }
  git fetch -q origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{upstream}')" ]] || { echo "Push this commit first." >&2; exit 1; }
  ! gh release view "$TAG" >/dev/null 2>&1 || { echo "Release $TAG already exists; bump the version in Resources/Info.plist." >&2; exit 1; }
fi

notarize() {
  echo "Notarizing $(basename "$1")…"
  local out status id
  out="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)"
  status="$(plutil -extract status raw - <<<"$out")"
  id="$(plutil -extract id raw - <<<"$out")"
  if [[ "$status" != Accepted ]]; then
    echo "Notarization $status ($id):" >&2
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
}

./build.sh --release
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')"

# The app itself gets a ticket too, so it also passes Gatekeeper offline once copied out of the image.
if (( NOTARIZE )); then
  ZIP="$(mktemp -d)/PenDriver.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
fi

# Disk image: the app next to a link to Applications to drag it onto.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Pen Driver" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if (( NOTARIZE )); then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
echo "Built $DMG"

if (( PUBLISH )); then
  gh release create "$TAG" "$DMG" --draft --target "$(git rev-parse HEAD)" \
    --title "Pen Driver $VERSION" --generate-notes
  echo "Draft release $TAG created; review and publish it on GitHub."
fi
