# Agent guidance for snap-it

Snap It is a native macOS 14+ menu bar app for screenshots and quick annotation, part of Mikerosoft. It replaces CleanShot X for Mike: press ⌘⇧4, drag out an area, and an editor opens straight away for arrows, boxes, text and so on. Swift 6 with AppKit, ScreenCaptureKit and Carbon hotkeys, no third-party dependencies or backend.

## Rules

- Use test-first development for non-trivial changes. Write or update the test in `Tests/SnapItCoreTests` first, then implement until it passes. Keep logic in `SnapItCore` so it can be tested without permissions; extract a seam first if needed.
- Always use `restart.sh` to rebuild and relaunch. Never run the binary from `.build` for real use: it isn't the signed bundle, so Screen Recording and Open at Login won't behave.
- After any app change, run `restart.sh` and tail the log to confirm a clean start. In headless CI or sandboxes without permissions, run the tests and say that a live check is still needed.
- Speed is a feature. Capture each display once and crop from the frozen image. Never request per-window images. Keep the timing lines in the log.
- Never lose an annotation. Closing an editor with unsaved changes saves and copies them, with no prompt. Quitting (including SIGTERM from `restart.sh`) commits every unsaved editor first. A document only counts as saved once its write succeeds; a failed write puts the image on the clipboard and keeps the editor open.
- Keep `com.mikerosoft.snap-it` and its designated signing requirement stable so the Screen Recording grant survives rebuilds.
- Setup must be safe to repeat. Preserve unrelated apps, LaunchAgents, screenshots and logs. The only LaunchAgent `restart.sh` touches is the old Python daemon's `com.mikerosoft.snap-it.plist`, which it removes.
- Keep binaries, staged bundles and private paths out of Git. No em dashes in copy.

## Code layout

- `Sources/SnapItCore`: everything testable. `Geometry.swift` (global points, display-local points and pixels, selection clamping), `Naming.swift` (file names), `Annotation.swift` (tools, shapes, hit-testing, handles), `ShapePaths.swift` (tapered arrow and other paths), `Document.swift` (annotation state with undo/redo and dirty tracking), `Crop.swift`, `Pixelator.swift`, `Renderer.swift` (one drawing path for canvas and export), `TextStyle.swift`, `PNGWriter.swift` (PNG with DPI), `OpenedImage.swift` (scale and save path for opened files), `Settings.swift` (UserDefaults).
- `Sources/SnapIt`: the app. `main.swift`, `AppDelegate.swift` (menu bar item, hotkeys, login item, capture flow, main menu), `HotKeys.swift` (Carbon), `ScreenCapturer.swift` (ScreenCaptureKit), `Overlay.swift` (frozen selection overlay and loupe), `Output.swift` (save, clipboard, sound), `EditorWindowController.swift`, `EditorToolbar.swift`, `CanvasView.swift`, `Log.swift`.
- `Tests/SnapItCoreTests`: geometry, naming, shapes, hit-testing, undo/redo, crop, settings, and pixel checks of flattened renders.
- `restart.sh`: release build, `.app` bundle, stable signing, install to `~/Applications/Snap It.app`, old daemon cleanup, launch. `uninstall.sh`: removes the app and its login item.
- `scripts/pack-icon.swift`: fallback ICNS writer when `iconutil` is unavailable.
- `~/Library/Logs/snap-it.log`: runtime log, not in Git. `~/Screenshots`: default save folder.

## Build and verify

```bash
swift build
swift test
bash -n restart.sh uninstall.sh
bash restart.sh
tail -f ~/Library/Logs/snap-it.log
```

In a sandbox, keep module caches inside the clone and turn off SwiftPM's own sandbox:

```bash
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test --disable-sandbox
```

Some sandboxes block the atomic file writes SwiftPM relies on. If `swift build` fails writing `manifest.json` or `output-file-map.json`, compile with `swiftc` directly instead and say so.

Use `SNAP_IT_APP_PATH`, `SNAP_IT_CODESIGN_IDENTITY` (`-` for ad-hoc), `SNAP_IT_BUILD_SYSTEM` and `SNAP_IT_OPEN=0` for isolated installer checks.

After a change to capture or the editor, check by hand: ⌘⇧4 on each display (including ones with negative coordinates and different scales), Escape and right-click cancel, Shift for squares, the saved PNG and its name, pasting into Claude, Slack and Finder, each tool and its shortcut, undo/redo, crop, Done, Copy, Save, drag-out, and closing with and without changes. Check the timing lines in the log.

## Opening files and URLs

- `open -a "Snap It" file` (or the app icon, or Open With) opens an editor for PNG, JPEG, HEIC, WebP or TIFF. Scale comes from `@2x`/`@3x` in the name, else DPI. PNGs save in place; other formats save to a sibling PNG. The document types use `LSHandlerRank` Alternate so Snap It never becomes the default viewer.
- `open snapit://capture-area` and `open snapit://capture-fullscreen` act like ⌘⇧4 and ⌘⇧3 (trigger `url` in the log). Handy for testing while another app holds the hotkeys.

## Settings

UserDefaults for `com.mikerosoft.snap-it`: `saveFolder` (default `~/Screenshots`), `lastTool`, `color`, `thickness`, `textSize`. No settings window. For example `defaults write com.mikerosoft.snap-it saveFolder ~/Desktop/Shots`.
