#!/usr/bin/env bash
# Remove only snap-it's current and legacy login items.
# Run: bash uninstall-launchagent.sh
set -euo pipefail

for label in com.mikerosoft.snap-it com.mikerosoft.mac-screenshot; do
  plist_path="$HOME/Library/LaunchAgents/$label.plist"
  if [ -f "$plist_path" ]; then
    launchctl unload "$plist_path" 2>/dev/null || true
    rm "$plist_path"
  fi
done

echo "snap-it login item removed (if installed)."
