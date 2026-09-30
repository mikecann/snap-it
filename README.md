# <img src="icons/snap-it.png" width="24" height="24" alt=""> snap-it

Press F11 to grab part of the screen and start marking it up

macOS

<!-- media: hero -->
<!-- ![snap-it](docs/hero.png) -->
<!-- /media: hero -->

## What it is

A little background helper for macOS. You press F11, drag out the bit of the screen you want, and it saves it to `~/Desktop/Screenshots` with a timestamp name, copies it to the clipboard and opens it in Preview so you can scribble on it straight away.

It starts on login, so once it's set up you can mostly forget about it.

Previously called `mac-screenshot`.

![snap-it banner](docs/header.webp)

## Get it

Paste this into your AI coding agent (Claude Code, Codex, Cursor...):

> Clone https://github.com/mikecann/snap-it and make it my own. It's one of Mike
> Cann's personal tools, so read the README first, change anything specific to his
> setup to suit mine, then help me get it running.

### Or set it up by hand

You'll need macOS, Git and Python 3.10 or newer with `venv` and `pip`. The setup script looks for Homebrew Python or `python3` on PATH. If you need Python, install it with `brew install python@3.12`.

```bash
git clone https://github.com/mikecann/snap-it.git
cd snap-it
bash install.sh
```

This creates `.venv`, installs `pynput`, and starts a LaunchAgent that runs again when you log in. Keep the clone where you want it to live. If you move it, rerun `bash install-launchagent.sh` from its new location.

Then grant permissions in macOS:

1. Open **System Settings > Privacy & Security > Accessibility**.
2. Add the Python interpreter used by `.venv/bin/python3` (or Python.app if macOS lists it) and enable it. For a manually started daemon, allow the terminal app too if prompted.
3. Allow **Screen Recording** if macOS asks.
4. Run `bash restart.sh`, then press F11.

No API keys or `.env` file are needed.

## Using it

Press F11 and drag out a region. The saved PNG is copied to your clipboard and opened in Preview for markup. Press Escape during selection to cancel.

Files are named like `Screenshot 2026-09-30 at 10.42.05 - Safari.png`, using the frontmost app's name when it is available.

```bash
# Set up dependencies without installing a login item
bash setup_mac.sh

# Install or update the login item
bash install-launchagent.sh

# Restart after code changes, or start manually without a login item
bash restart.sh

# Stop a manually started daemon
bash kill.sh

# Remove the login item and stop its managed daemon
bash uninstall-launchagent.sh
```

The installer replaces the previous login item if it finds one. It leaves existing screenshots and logs alone. Uninstalling keeps your clone, `.venv`, screenshots and logs.

## Settings

Edit the constants at the top of `snap-it.py`, then run `bash restart.sh`:

- `HOTKEY` defaults to `<f11>`.
- `SAVE_DIR` defaults to `~/Desktop/Screenshots`.
- `LOG_FILE` defaults to `~/Library/Logs/snap-it.log`.

Settings live in the source file. If you customised an earlier clone, copy those values into this one before installing.

## Troubleshooting

Check the log after restarting:

```bash
tail -f ~/Library/Logs/snap-it.log
```

If F11 does nothing, check Accessibility permissions and any macOS keyboard shortcut using that key. Depending on your keyboard's function-key setting, you may need Fn + F11.

The login item lives at `~/Library/LaunchAgents/com.mikerosoft.snap-it.plist`. It restarts the daemon if it exits, so use `uninstall-launchagent.sh` to stop an installed daemon. `kill.sh` is for manual background runs.

## Development

```bash
python3 -m unittest discover -s tests -v
python3 -m compileall -q snap-it.py tests
for script in *.sh; do bash -n "$script"; done
```

The tests use temporary homes and stub native commands, so they don't install a real login item or require screen permissions. After changing the daemon, run `bash restart.sh` on a Mac with permission and check F11 capture, clipboard paste, Preview and the log.

## Art

`docs/header.webp` is a generated banner for the public site. `icons/snap-it.png` is `monitor.png` from the [FamFamFam Silk](https://www.famfamfam.com/lab/icons/silk/) set by Mark James, licensed under [CC BY 2.5](https://creativecommons.org/licenses/by/2.5/). That icon retains its original licence.

## More tools

You can find my other tools at [mikerosoft.app](https://mikerosoft.app).

MIT licensed.
