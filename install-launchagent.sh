#!/usr/bin/env bash
# Install snap-it as a login item. Run: bash install-launchagent.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/com.mikerosoft.snap-it.plist"
LEGACY_PLIST_PATH="$PLIST_DIR/com.mikerosoft.mac-screenshot.plist"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
LOG="$HOME/Library/Logs/snap-it.log"

if [ ! -x "$PYTHON" ]; then
  echo "ERROR: venv not found. Run setup first:"
  echo "  bash \"$SCRIPT_DIR/setup_mac.sh\""
  exit 1
fi

mkdir -p "$PLIST_DIR" "$(dirname "$LOG")"

# Serialize paths rather than interpolating XML: clones may contain '&' or '<'.
"$PYTHON" - "$PLIST_PATH" "$PYTHON" "$SCRIPT_DIR/snap-it.py" "$LOG" <<'PY'
import plistlib
import sys

path, python, script, log = sys.argv[1:]
with open(path, 'wb') as file:
    plistlib.dump({
        'Label': 'com.mikerosoft.snap-it',
        'ProgramArguments': [python, script],
        'RunAtLoad': True,
        'KeepAlive': True,
        'StandardOutPath': log,
        'StandardErrorPath': log,
    }, file)
PY

# Retire the old login item so a renamed install cannot run two hotkey listeners.
# Existing screenshots and logs stay where they are; there are no saved settings.
if [ -f "$LEGACY_PLIST_PATH" ]; then
  launchctl unload "$LEGACY_PLIST_PATH" 2>/dev/null || true
  rm "$LEGACY_PLIST_PATH"
fi

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Installed and started snap-it as a login item."
echo ""
echo "  Hotkey:     F11"
echo "  Save dir:   ~/Desktop/Screenshots"
echo "  Log:        $LOG"
echo ""
echo "To remove:  bash \"$SCRIPT_DIR/uninstall-launchagent.sh\""
