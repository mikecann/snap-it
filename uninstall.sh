#!/usr/bin/env bash
# Remove Snap It and its login item. Screenshots and the log are left alone.
set -euo pipefail
APP="${SNAP_IT_APP_PATH:-$HOME/Applications/Snap It.app}"
# Stop only processes running from this exact destination, including isolated test installs.
app_pids() {
  local PID
  while read -r PID; do
    if [[ "$(ps -p "$PID" -o comm= 2>/dev/null || true)" == "$APP/Contents/MacOS/SnapIt" ]]; then echo "$PID"; fi
  done < <(pgrep -x SnapIt || true)
}
stop_app() {
  local PID WAIT
  while read -r PID; do
    [[ -n "$PID" ]] || continue
    kill -TERM "$PID" 2>/dev/null || true
    for WAIT in {1..30}; do
      if ! kill -0 "$PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo 'Snap It is still running at this install path. Quit it before continuing.' >&2
      return 1
    fi
  done < <(app_pids)
}
# Remove only our own bundle.
if [[ -e "$APP" || -L "$APP" ]]; then
  if [[ -L "$APP" || "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != 'com.mikerosoft.snap-it' ]]; then
    echo "An unrelated item exists at $APP; leaving it alone." >&2
    exit 1
  fi
  stop_app
  "$APP/Contents/MacOS/SnapIt" --unregister-login-item || true
  rm -rf "$APP"
  echo "Removed Snap It from $APP and its login item."
else
  echo "Snap It isn't installed at $APP."
fi
