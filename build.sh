#!/bin/zsh
# Builds "build/Pen Driver.app". Pass --install to copy it to /Applications.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --arch arm64
APP="build/Pen Driver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PenDriver "$APP/Contents/MacOS/PenDriver"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Input Monitoring / Accessibility grants across rebuilds.
IDENTITIES="$(security find-identity -v -p codesigning)"
IDENTITY="${PEN_DRIVER_IDENTITY:-$( { grep 'Developer ID Application' <<<"$IDENTITIES"; grep 'Apple Development' <<<"$IDENTITIES"; } | awk 'NR==1 {print $2}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x PenDriver 2>/dev/null && sleep 0.5 || true
  rm -rf "/Applications/Pen Driver.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Pen Driver.app"
fi
