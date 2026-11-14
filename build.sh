#!/bin/bash
# MiniBar 构建脚本：swiftc 直接产出 .app，无 xcodeproj（98KB 极客质感，PRD §6）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MiniBar.app"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

xcrun swiftc -swift-version 5 -O -sdk "$SDK" \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/Module.swift \
    Sources/MenuBarShell.swift \
    Sources/SettingsPanel.swift \
    Sources/Modules/*.swift \
    -o "$APP/Contents/MacOS/MiniBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MiniBar</string>
    <key>CFBundleIdentifier</key><string>com.samuelonly.MiniBar</string>
    <key>CFBundleName</key><string>MiniBar</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>MiniBar 需要切换系统深浅色外观（一次性授权，此后无感）。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true

echo "✔ 构建完成: $APP"
du -sk "$APP" | awk '{print "总体积: " $1 " KB"}'
ls -l "$APP/Contents/MacOS/MiniBar" | awk '{print "二进制: " $5 " bytes"}'
