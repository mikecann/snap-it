# Agent guidance for snap-it

## Repo purpose

Global hotkey screenshot daemon for macOS. Press F11 to enter selection-capture mode, save to `~/Desktop/Screenshots` with a timestamp name, copy to the clipboard, and open in Preview for annotation.

## Rules

- Use test-first development for non-trivial changes. Write or update the automated test first, then implement until it passes. Extract a test seam first if needed.
- When behaviour changes, update affected expectations and rerun the relevant tests, including persistence and startup contracts.
- Test before committing. Run the automated tests and shell syntax checks, then verify the actual daemon on a Mac with the required permissions. Check exit codes and the log.
- Keep source and dependencies in this clone. `install.sh` runs `setup_mac.sh` and `install-launchagent.sh`; the LaunchAgent points directly at this clone.
- Setup and installation must be self-contained and safe to repeat. Preserve unrelated LaunchAgents, existing screenshots and logs.
- There are no saved settings files. Preserve compatibility with the previous LaunchAgent label during migration; do not leave two login listeners running.
- Always use `restart.sh` to restart. Never launch the Python script directly, which can leave stale instances.
- After any code change, run `restart.sh` and tail the log to confirm clean startup. In headless CI or environments without permissions, use the stubbed tests and report that native verification remains.

## Dev workflow

```bash
python3 -m unittest discover -s tests -v
python3 -m compileall -q snap-it.py tests
for script in *.sh; do bash -n "$script"; done
bash restart.sh
tail -f ~/Library/Logs/snap-it.log
```

Check F11 selection, Escape cancellation, the saved PNG, clipboard paste and Preview after a daemon change. Tests stub native commands and use temporary homes, so they never register the developer's login item.

## First-time setup

```bash
bash install.sh
```

Or run `bash setup_mac.sh` and `bash install-launchagent.sh` separately.
Grant Accessibility permissions in System Settings > Privacy & Security > Accessibility to the Python process (and the terminal for manual runs if prompted). Allow Screen Recording when requested.

## Key files

| Path | What it is |
|---|---|
| `snap-it.py` | Global hotkey listener and screenshot logic |
| `requirements.txt` | Python dependencies |
| `install.sh` | Dependency setup and login-item installation |
| `setup_mac.sh` | Creates `.venv`, installs dependencies |
| `restart.sh` | Restarts the login item or manual background process |
| `kill.sh` | Stops a manually started instance |
| `install-launchagent.sh` | Installs or migrates the login item |
| `uninstall-launchagent.sh` | Removes this tool's current and previous login items |
| `tests/` | Permission-free daemon and installer tests |
| `~/Library/Logs/snap-it.log` | Runtime log, not in git |
| `~/Desktop/Screenshots/` | Default save directory |

## Configuration

Edit constants at the top of `snap-it.py`:

- `HOTKEY` defaults to `<f11>`.
- `SAVE_DIR` defaults to `~/Desktop/Screenshots`.
- `LOG_FILE` defaults to `~/Library/Logs/snap-it.log`.
