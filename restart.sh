#!/usr/bin/env bash
# Build, bundle, sign, install and relaunch Snap It. Also retires the old Python daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${SNAP_IT_APP_PATH:-$HOME/Applications/Snap It.app}"
BUNDLE_ID='com.mikerosoft.snap-it'
OLD_AGENT="$HOME/Library/LaunchAgents/com.mikerosoft.snap-it.plist"
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
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
cd "$ROOT"
BUILD_ARGS=(--disable-sandbox)
if [[ -n "${SNAP_IT_BUILD_SYSTEM:-}" ]]; then BUILD_ARGS+=(--build-system "$SNAP_IT_BUILD_SYSTEM"); fi
swift build -c release "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build -c release --show-bin-path "${BUILD_ARGS[@]}")"
STAGE_ROOT="$(mktemp -d "$ROOT/.build/stage.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/Snap It.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE_ROOT/icon.iconset"
cp "$BIN_DIR/SnapIt" "$STAGE/Contents/MacOS/SnapIt"
# The source is 256 px; sips upscales it for the 512 and 1024 px slots.
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/icons/snap-it.png" --out "$STAGE_ROOT/icon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/icons/snap-it.png" --out "$STAGE_ROOT/icon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
if ! iconutil -c icns "$STAGE_ROOT/icon.iconset" -o "$STAGE/Contents/Resources/SnapIt.icns"; then
  echo 'iconutil is unavailable; packing the resized PNG representations directly.' >&2
  swift "$ROOT/scripts/pack-icon.swift" "$STAGE_ROOT/icon.iconset" "$STAGE/Contents/Resources/SnapIt.icns"
fi
cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.mikerosoft.snap-it</string>
<key>CFBundleName</key><string>Snap It</string>
<key>CFBundleDisplayName</key><string>Snap It</string>
<key>CFBundleExecutable</key><string>SnapIt</string>
<key>CFBundleIconFile</key><string>SnapIt.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSScreenCaptureUsageDescription</key><string>Snap It captures the screen when you press its hotkeys.</string>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>com.mikerosoft.snap-it</string>
  <key>CFBundleURLSchemes</key><array><string>snapit</string></array>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Image</string>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>LSHandlerRank</key><string>Alternate</string>
  <key>LSItemContentTypes</key><array>
    <string>public.png</string><string>public.jpeg</string><string>public.heic</string><string>org.webmproject.webp</string><string>public.tiff</string>
  </array>
</dict></array>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mike Cann. MIT licensed.</string>
</dict></plist>
PLIST
IDENTITY="${SNAP_IT_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)}"
# Keep the designated requirement stable so the Screen Recording grant can survive a rebuild.
codesign --force --timestamp=none --sign "${IDENTITY:--}" --requirements '=designated => identifier "com.mikerosoft.snap-it"' "$STAGE"
codesign --verify --strict "$STAGE"
# Validate the destination before stopping or replacing anything.
if [[ -e "$APP" || -L "$APP" ]]; then
  if [[ -L "$APP" || "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ]]; then
    echo "An unrelated item exists at $APP. Move it before installing." >&2
    exit 1
  fi
fi
# Retire the old Python daemon: its LaunchAgent and any leftover manual instance. Other LaunchAgents are left alone.
if [[ -f "$OLD_AGENT" ]]; then
  launchctl bootout "gui/$(id -u)/com.mikerosoft.snap-it" 2>/dev/null || true
  rm -f "$OLD_AGENT"
  echo "Removed the old Python LaunchAgent ($OLD_AGENT)."
fi
pkill -f 'snap-it\.py' 2>/dev/null || true
stop_app
mkdir -p "$(dirname "$APP")"
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
mv "$STAGE" "$APP"
if [[ "${SNAP_IT_OPEN:-1}" != 0 ]]; then open "$APP"; fi
echo "Installed $APP"
echo "Log: tail -f ~/Library/Logs/snap-it.log"
