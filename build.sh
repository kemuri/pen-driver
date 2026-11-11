#!/bin/zsh
# Builds "build/wdrive.app" and installs it to /Applications, the copy that runs (see
# Scripts/install.sh).
#   --release      universal (Apple silicon + Intel), Developer ID, hardened runtime: ready to notarize
#   --no-install   leave it in build/
set -euo pipefail
cd "${0:A:h}"

RELEASE=0; INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1 ;;
    --no-install) INSTALL=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if (( RELEASE )); then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(--arch arm64); fi
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/wdrive"

APP="build/wdrive.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM records the deployment target as the SDK too, and macOS draws an app's controls for the
# SDK it says it was built with: without this, the controls of that older macOS.
MINOS="$(vtool -show-build "$BIN" | awk '/minos/ {print $2; exit}')"
vtool -set-build-version macos "$MINOS" "$(xcrun --show-sdk-version)" -replace -output "$APP/Contents/MacOS/wdrive" "$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Input Monitoring / Accessibility grants across rebuilds.
IDENTITIES="$(security find-identity -v -p codesigning)"
if (( RELEASE )); then
  # Notarization needs Developer ID, the hardened runtime and a secure timestamp.
  IDENTITY="${WDRIVE_IDENTITY:-$(grep 'Developer ID Application' <<<"$IDENTITIES" | awk 'NR==1 {print $2}')}"
  [[ -n "$IDENTITY" ]] || { echo "A release needs a Developer ID Application certificate." >&2; exit 1; }
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  IDENTITY="${WDRIVE_IDENTITY:-$( { grep 'Developer ID Application' <<<"$IDENTITIES"; grep 'Apple Development' <<<"$IDENTITIES"; } | awk 'NR==1 {print $2}')}"
  codesign --force --sign "${IDENTITY:--}" "$APP"
fi
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if (( INSTALL )); then Scripts/install.sh "$APP"; fi
