#!/bin/zsh
# 노타라이즈 스크립트 — Developer ID Application 인증서 + Apple Developer 계정 필요
#
# 최초 1회: 자격증명을 로컬 키체인에 저장
#   ./scripts/notarize.sh --store-credentials
#
# 이후 배포 시:
#   ./scripts/notarize.sh
set -e

KEYCHAIN_PROFILE="mlxcontrol-notarize"
APP="MLXControl.app"
# Team ID는 Developer ID 인증서에서 자동 감지. 필요시 override: TEAM_ID=XXXXXXXXXX ./scripts/notarize.sh
TEAM_ID="${TEAM_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | head -1 | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()')}"

store_credentials() {
    echo "──────────────────────────────────────────────────────"
    echo " Apple ID 자격증명을 로컬 키체인에 저장합니다."
    echo " 저장 위치: 로컬 시스템 키체인 (iCloud 동기 안 됨)"
    echo "──────────────────────────────────────────────────────"
    echo
    echo "필요한 것:"
    echo "  Apple ID 이메일 (예: you@example.com)"
    echo "  앱 암호: appleid.apple.com → 보안 → 앱 암호 생성"
    echo "  (형식: xxxx-xxxx-xxxx-xxxx)"
    echo
    if [[ -z "$TEAM_ID" ]]; then
        echo "✗ Team ID 자동 감지 실패 — TEAM_ID=XXXXXXXXXX ./scripts/notarize.sh --store-credentials 로 지정"
        exit 1
    fi
    echo "  Team ID: $TEAM_ID (자동 감지)"
    echo
    xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" \
        --team-id "$TEAM_ID"
    echo
    echo "✓ 키체인 프로파일 '$KEYCHAIN_PROFILE' 저장 완료"
    echo "  이후 ./scripts/notarize.sh 만 실행하면 됩니다."
}

notarize() {
    echo "→ 릴리스 빌드 (--no-install)…"
    ./build.sh --no-install

    # Developer ID 서명 확인 (해시로 추출)
    DEV_ID_HASH=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
    if [[ -z "$DEV_ID_HASH" ]]; then
        echo "✗ Developer ID Application 인증서 없음"
        echo "  developer.apple.com → Certificates → Developer ID Application 발급 필요"
        exit 1
    fi
    DEV_ID_NAME=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 | grep -oE '"[^"]+"' | tr -d '"' || true)
    echo "✓ 서명 인증서: $DEV_ID_NAME"

    echo "→ zip 패키징…"
    rm -f MLXControl.zip
    ditto -c -k --keepParent "$APP" MLXControl.zip

    echo "→ 노타라이즈 제출 (완료까지 1~5분 소요)…"
    xcrun notarytool submit MLXControl.zip \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "→ 스테이플(staple) — Gatekeeper 오프라인 확인용 티켓 부착…"
    xcrun stapler staple "$APP"

    echo "→ 최종 배포 zip 생성…"
    rm -f MLXControl.zip MLXControl-notarized.zip
    ditto -c -k --keepParent "$APP" MLXControl-notarized.zip

    echo
    echo "✓ 완료: MLXControl-notarized.zip"
    echo "  → GitHub Releases에 첨부하면 사용자가 경고 없이 설치 가능"
}

case "${1}" in
    --store-credentials) store_credentials ;;
    "") notarize ;;
    *) echo "Usage: $0 [--store-credentials]"; exit 1 ;;
esac
