#!/bin/bash
# MiniBar 构建脚本：swiftc 直接产出 .app，无 xcodeproj（98KB 极客质感，PRD §6）
set -euo pipefail
cd "$(dirname "$0")"

APP="/tmp/mbuild/MiniBar.app"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"

xcrun swiftc -disable-sandbox -swift-version 5 -O -sdk "$SDK" \
    Sources/*.swift \
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
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>ja</string>
        <string>ko</string>
        <string>fr</string>
        <string>de</string>
        <string>es</string>
        <string>it</string>
        <string>pt-BR</string>
        <string>ru</string>
    </array>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>MiniBar.icns</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>MiniBar 需要切换系统深浅色外观（一次性授权，此后无感）。</string>
</dict>
</plist>
PLIST

# i18n：全部语言资源进 bundle（11 个 lproj，之前只拷了 zh-Hans/en）
mkdir -p "$APP/Contents/Resources"
for d in Resources/*.lproj; do
    [ -d "$d" ] && cp -R "$d" "$APP/Contents/Resources/"
done

# App 图标 + 状态栏图标
if [ -f Resources/MiniBar.icns ]; then cp Resources/MiniBar.icns "$APP/Contents/Resources/"; fi
if [ -f Resources/MiniBar-menubar.png ]; then cp Resources/MiniBar-menubar.png "$APP/Contents/Resources/"; fi

codesign --force --sign - "$APP" 2>/dev/null || true

echo "✔ 构建完成: $APP"
du -sk "$APP" | awk '{print "总体积: " $1 " KB"}'
ls -l "$APP/Contents/MacOS/MiniBar" | awk '{print "二进制: " $5 " bytes"}'
