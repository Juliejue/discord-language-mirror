#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
app="dist/Discord Language Mirror.app"
mkdir -p "$app/Contents/MacOS" work/module-cache

xcrun swiftc -parse-as-library -O \
  -target arm64-apple-macos15.0 \
  -module-cache-path work/module-cache \
  src/DiscordLanguageMirror.swift \
  -o "$app/Contents/MacOS/DiscordLanguageMirror"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>Discord 多语言镜像 0.5</string>
  <key>CFBundleExecutable</key><string>DiscordLanguageMirror</string>
  <key>CFBundleIdentifier</key><string>io.heyjue.discord-language-mirror</string>
  <key>CFBundleName</key><string>Discord Language Mirror</string>
  <key>CFBundleShortVersionString</key><string>0.5.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSAccessibilityUsageDescription</key><string>读取 Discord 窗口中可见消息的发言者、正文和位置，在原消息处显示所选语言的译文。</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/Discord-Language-Mirror-0.5-macOS-arm64.zip"
echo "Built $app"
