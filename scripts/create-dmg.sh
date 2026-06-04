#!/bin/zsh
# DMG 생성 스크립트 — notarized .app → 설치 UX가 있는 .dmg
# 의존: brew install create-dmg
# 사용: ./scripts/create-dmg.sh [--skip-notarize]
set -e
cd "$(dirname "$0")/.."

APP_NAME="MLXControl"
VERSION=$(cat Package.swift | grep -oE 'version.*"[0-9.]+"' | grep -oE '[0-9.]+' | head -1 || echo "1.3")
APP="${APP_NAME}.app"
DMG="${APP_NAME}-${VERSION}.dmg"

if [[ "${1}" != "--skip-notarize" ]]; then
  echo "→ 빌드 + 노타라이즈…"
  ./scripts/notarize.sh
fi

if ! command -v create-dmg &>/dev/null; then
  echo "✗ create-dmg 없음. 설치: brew install create-dmg"; exit 1
fi

echo "→ DMG 생성…"
rm -f "$DMG"
create-dmg \
  --volname "${APP_NAME}" \
  --volicon "${APP_NAME}.icns" \
  --window-pos 200 120 \
  --window-size 600 380 \
  --icon-size 100 \
  --icon "${APP}.app" 160 185 \
  --hide-extension "${APP}.app" \
  --app-drop-link 430 185 \
  --no-internet-enable \
  "$DMG" \
  "$APP"

# DMG 자체에도 서명 (노타라이즈에 필요)
DEV_ID_HASH=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
if [[ -n "$DEV_ID_HASH" ]]; then
  codesign --force --sign "$DEV_ID_HASH" "$DMG"
  echo "→ DMG 서명 완료"

  # DMG 노타라이즈
  KEYCHAIN_PROFILE="${APP_NAME}-notarize"
  if xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
    echo "→ DMG 노타라이즈 제출…"
    xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "✓ DMG 노타라이즈 완료: $DMG"
  else
    echo "⚠ Keychain 프로파일 없음. DMG만 생성(노타라이즈 X). 수동: ./scripts/notarize.sh --store-credentials"
  fi
fi

echo "✓ $DMG 생성 완료 ($(du -sh "$DMG" | awk '{print $1}'))"
