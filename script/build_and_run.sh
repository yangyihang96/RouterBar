#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
VERSION="2.0.0"
BUILD_NUMBER="44"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keychain "Always Allow" is bound to the code signature's designated requirement. An ad hoc
# signature pins it to the cdhash, so every rebuild asked for keychain access again. A real
# certificate keeps the requirement stable across builds. CODESIGN_IDENTITY overrides the choice.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  echo 'No Apple Development certificate found; using ad hoc signing. Keychain access will be requested again after each update.' >&2
fi
APP_BUNDLE="$HOME/Library/Caches/com.yihang.RouterBar/Products/RouterBar.app"
INSTALL_BUNDLE="$HOME/Applications/RouterBar.app"
BUILD_DIR="$HOME/Library/Caches/com.yihang.RouterBar/Build"
cd "$ROOT_DIR"
if [[ "${ROUTERBAR_AUDIT:-0}" == "1" && "$MODE" != "--build-only" ]]; then
  echo 'Audit builds must stay in the development cache; use --build-only.' >&2
  exit 2
fi
if [[ "$MODE" != "--build-only" ]]; then
  pkill -x RouterBar >/dev/null 2>&1 || true
fi
if [[ "${ROUTERBAR_AUDIT:-0}" == "1" ]]; then
  swift build --scratch-path "$BUILD_DIR" -c release -Xswiftc -DROUTERBAR_AUDIT
else
  swift build --scratch-path "$BUILD_DIR" -c release
fi
BIN_DIR="$(swift build --scratch-path "$BUILD_DIR" -c release --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp -X "$BIN_DIR/RouterBar" "$APP_BUNDLE/Contents/MacOS/RouterBar"
ditto --norsrc "$BIN_DIR/ASUSRouterBar_RouterCore.bundle" "$APP_BUNDLE/Contents/Resources/ASUSRouterBar_RouterCore.bundle"
cp -X "$ROOT_DIR/Assets/RouterBar-Icon.png" "$APP_BUNDLE/Contents/Resources/RouterBar-Icon.png"
cp -X "$ROOT_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>RouterBar</string>
  <key>CFBundleIdentifier</key><string>com.yihang.RouterBar</string>
  <key>CFBundleName</key><string>RouterBar</string>
  <key>CFBundleDisplayName</key><string>路由器面板</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>连接你指定的华硕路由器，查看网络状态、管理设备与设置并更新固件。</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --timestamp=none --sign "$SIGN_IDENTITY" --identifier com.yihang.RouterBar "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
if [[ "${ROUTERBAR_AUDIT:-0}" != "1" ]]; then
  mkdir -p "$ROOT_DIR/dist"
  ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$ROOT_DIR/dist/RouterBar.zip"
fi
if [[ "$MODE" != "--build-only" ]]; then
  if [[ -e "$INSTALL_BUNDLE" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_ID" != "com.yihang.RouterBar" ]]; then
      echo 'Installation destination belongs to another app; leaving it unchanged.' >&2
      exit 1
    fi
  fi
  mkdir -p "$HOME/Applications"
  ditto --norsrc "$APP_BUNDLE" "$INSTALL_BUNDLE"
  codesign --verify --deep --strict "$INSTALL_BUNDLE"
fi
case "$MODE" in
  --build-only) echo "Built: $APP_BUNDLE" ;;
  run) open -n "$INSTALL_BUNDLE" ;;
  # ROUTERBAR_SCREEN opens the window on that display without taking the foreground (testing on a virtual display).
  --verify)
    if [[ -n "${ROUTERBAR_SCREEN:-}" ]]; then open -g -n "$INSTALL_BUNDLE" --args --background --screen "$ROUTERBAR_SCREEN"
    else open -n "$INSTALL_BUNDLE"; fi
    sleep 1; pgrep -x RouterBar >/dev/null; echo 'Installed RouterBar process running' ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/RouterBar" ;;
  --logs|--telemetry) open -n "$INSTALL_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "RouterBar"' ;;
  *) echo 'usage: build_and_run.sh [run|--build-only|--verify|--debug|--logs|--telemetry]' >&2; exit 2 ;;
esac
