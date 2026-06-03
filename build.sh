#!/bin/zsh
set -e
cd "$(dirname "$0")"

BUNDLE_ID="io.github.wonsss.mlxcontrol"
VERSION="1.3"
APP="MLXControl.app"

echo "→ 아이콘 생성…"
swift generate_icon.swift
iconutil -c icns MLXControl.iconset -o MLXControl.icns
rm -rf MLXControl.iconset

echo "→ swift build (release)…"
swift build -c release
BIN=$(swift build -c release --show-bin-path)/MLXControl

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MLXControl"
cp MLXControl.icns "$APP/Contents/Resources/MLXControl.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MLXControl</string>
  <key>CFBundleDisplayName</key><string>MLX Control</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>MLXControl</string>
  <key>CFBundleIconFile</key><string>MLXControl</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Wonseok Jang</string>
</dict>
</plist>
PLIST

# ── 코드 서명 ──
# 해시로 추출 (따옴표 파싱 오류 방지)
DEV_ID_HASH=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
if [[ -n "$DEV_ID_HASH" ]]; then
  DEV_ID_NAME=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | grep -oE '"[^"]+"' | tr -d '"' || true)
  echo "→ Developer ID 서명: $DEV_ID_NAME"
  codesign --force --deep --options runtime --sign "$DEV_ID_HASH" "$APP"
else
  echo "→ Developer ID 없음 — ad-hoc 서명 (로컬 전용)"
  codesign --force --deep --sign - "$APP"
fi

# ── /Applications 자동 설치 ──
if [[ "${1}" != "--no-install" ]]; then
  rm -rf /Applications/MLXControl.app
  cp -R "$APP" /Applications/
  if [[ -n "$DEV_ID_HASH" ]]; then
    codesign --force --deep --options runtime --sign "$DEV_ID_HASH" /Applications/MLXControl.app
  fi
  echo "✓ built + installed → /Applications/MLXControl.app"
else
  echo "✓ built → $(pwd)/$APP"
fi
