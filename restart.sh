#!/usr/bin/env bash
# Restart the login item, or run in the background if it is not installed.
# Usage: bash restart.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
LOG="$HOME/Library/Logs/snap-it.log"
PLIST_PATH="$HOME/Library/LaunchAgents/com.mikerosoft.snap-it.plist"
LEGACY_PLIST_PATH="$HOME/Library/LaunchAgents/com.mikerosoft.mac-screenshot.plist"

if [ ! -x "$VENV/bin/python3" ]; then
  echo "ERROR: venv not found at $VENV"
  echo "Run setup first: bash \"$SCRIPT_DIR/setup_mac.sh\""
  exit 1
fi

echo "Stopping existing snap-it instances..."
pkill -f "snap-it.py" 2>/dev/null || true
sleep 0.3

if [ -f "$PLIST_PATH" ] || [ -f "$LEGACY_PLIST_PATH" ]; then
  bash "$SCRIPT_DIR/install-launchagent.sh"
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
echo "Launching snap-it..."
nohup "$VENV/bin/python3" "$SCRIPT_DIR/snap-it.py" > /dev/null 2>> "$LOG" &
echo "Started (pid $!). Hotkey: F11"
echo "Tail log: tail -f \"$LOG\""
