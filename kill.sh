#!/usr/bin/env bash
# kill.sh - stop the snap-it daemon.
# Usage:  bash kill.sh

pkill -f "snap-it.py" 2>/dev/null && echo "snap-it stopped." || echo "No running instance found."
