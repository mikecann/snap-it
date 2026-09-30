#!/usr/bin/env bash
# Install snap-it's dependencies and start its login item from this clone.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/setup_mac.sh"
bash "$SCRIPT_DIR/install-launchagent.sh"
