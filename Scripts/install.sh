#!/bin/zsh
# Puts an app bundle (default build/wdrive.app) in /Applications, the copy that runs. A running
# wdrive, from there or anywhere else, is quit first and started again from there.
set -euo pipefail
cd "${0:A:h}/.."

APP="${1:-build/wdrive.app}"
INSTALLED="/Applications/wdrive.app"
[[ -d "$APP" ]] || { echo "No app at $APP." >&2; exit 1; }

RUNNING=0
if pkill -x wdrive; then
  RUNNING=1
  for _ in {1..50}; do pgrep -xq wdrive || break; sleep 0.1; done
fi
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
echo "Installed to $INSTALLED"
if (( RUNNING )); then open "$INSTALLED"; fi
