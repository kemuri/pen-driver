#!/bin/zsh
# Builds "build/Pen Driver.app".
#   --install   also copy it to /Applications (quitting the running copy)
#   --release   universal (Apple silicon + Intel), Developer ID, hardened runtime: ready to notarize
set -euo pipefail
cd "${0:A:h}"

RELEASE=0; INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if (( RELEASE )); then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(--arch arm64); fi
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/PenDriver"

APP="build/Pen Driver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PenDriver"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Input Monitoring / Accessibility grants across rebuilds.
IDENTITIES="$(security find-identity -v -p codesigning)"
if (( RELEASE )); then
  # Notarization needs Developer ID, the hardened runtime and a secure timestamp.
  IDENTITY="${PEN_DRIVER_IDENTITY:-$(grep 'Developer ID Application' <<<"$IDENTITIES" | awk 'NR==1 {print $2}')}"
  [[ -n "$IDENTITY" ]] || { echo "A release needs a Developer ID Application certificate." >&2; exit 1; }
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  IDENTITY="${PEN_DRIVER_IDENTITY:-$( { grep 'Developer ID Application' <<<"$IDENTITIES"; grep 'Apple Development' <<<"$IDENTITIES"; } | awk 'NR==1 {print $2}')}"
  codesign --force --sign "${IDENTITY:--}" "$APP"
fi
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if (( INSTALL )); then
  pkill -x PenDriver 2>/dev/null && sleep 0.5 || true
  rm -rf "/Applications/Pen Driver.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Pen Driver.app"
fi
