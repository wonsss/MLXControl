# MLX Control

[English](README.md) | **한국어**

로컬 [mlx-lm](https://github.com/ml-explore/mlx-lm) 추론 서버를 터미널 없이 관리하는 macOS 메뉴바 앱 — 시작·정지·리소스 모니터링·모델 다운로드까지 메뉴바에서.

[![build](https://github.com/wonsss/MLXControl/actions/workflows/build.yml/badge.svg)](https://github.com/wonsss/MLXControl/actions/workflows/build.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange)
![Swift 6](https://img.shields.io/badge/Swift-6-red)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

<!-- 메뉴바 팝오버 스크린샷을 여기에 추가: -->
<!-- ![MLX Control](docs/screenshot.png) -->

## 목차

- [기능](#기능)
- [요구 사항](#요구-사항)
- [설치](#설치)
- [사용법](#사용법)
- [로그](#로그)
- [노타라이즈](#노타라이즈)
- [보안](#보안)
- [라이선스](#라이선스)

## 기능

- **서버 제어** — 메뉴바에서 `mlx_lm.server` 시작 / 정지 / 재시작
- **실시간 모니터링** — MLX 프로세스 RAM·CPU(정확) + 시스템 GPU %·GPU 메모리(ioreg, sudo 불필요)
- **미니 그래프** — GPU 사용률 추이 스파크라인
- **워밍업** — 모델을 메모리에 미리 로딩 + tokens/sec 측정
- **모델 관리** — HuggingFace 캐시에서 설치된 MLX 모델 자동 탐지
- **모델 검색** — HuggingFace mlx-community 검색 (용량·설명·README 미리보기)
- **모델 다운로드** — 앱에서 바로 mlx-community 모델 다운로드
- **모델 삭제** — 확보될 디스크 용량 미리보기와 함께 캐시 모델 제거
- **리소스 알림** — RAM 또는 여유 메모리가 임계치를 넘으면 macOS 알림
- **엔드포인트 복사** — `http://127.0.0.1:8080/v1` 원클릭 복사
- **로그인 시 자동 실행** 토글
- **/Applications로 이동** — 다른 위치에서 실행 시 첫 실행에 설치 안내

## 요구 사항

| 항목 | 내용 |
|---|---|
| macOS | 14.0 (Sonoma) 이상 |
| 하드웨어 | Apple Silicon (M 시리즈) — GPU 모니터링은 Metal/ioreg 기반 |
| mlx-lm | `pip install mlx-lm` 또는 `uv tool install mlx-lm` |
| 모델 | `~/.cache/huggingface/hub/` 에 MLX 모델 1개 이상 |

## 설치

### 방법 A — 소스에서 빌드 (권장, Gatekeeper 경고 없음)

```bash
git clone https://github.com/wonsss/MLXControl.git
cd MLXControl
./build.sh          # 빌드 + /Applications 설치
open /Applications/MLXControl.app
```

> Xcode Command Line Tools 필요: `xcode-select --install`

### 방법 B — 빌드본 다운로드 (GitHub Releases)

1. [Releases](https://github.com/wonsss/MLXControl/releases) 에서 `MLXControl-x.x.x.dmg` 다운로드
2. DMG 열기 → `MLXControl.app` 을 `/Applications` 폴더로 드래그
3. 노타라이즈된 빌드라 Gatekeeper 경고 없이 바로 실행됨.

### 방법 C — Homebrew

```bash
brew tap wonsss/tools
brew install --cask mlxcontrol
```

## 사용법

1. `mlx-lm` 설치 + 모델 1개 이상 받기:
   ```bash
   pip install mlx-lm
   python -m mlx_lm.manage --scan   # 캐시된 모델 확인
   ```
2. 메뉴바의 `⚡` 클릭
3. 모델 선택 → **Start**
4. 상태가 **Up** 이 되면 **🔥 Warm** 클릭해 모델 미리 로딩
5. AI 에이전트(Hermes, Claude Code, Cursor 등)가 `http://127.0.0.1:8080/v1` 을 바라보게 설정

## 로그

서버 로그 위치: `~/Library/Logs/MLXControl/mlx_server.log`
앱의 **📄** 버튼으로 Console.app 에서 열 수 있음.

## 노타라이즈

Apple Developer Program 멤버십과 "Developer ID Application" 인증서가 있는 배포자용:

```bash
# 최초 1회: Apple ID + 앱 암호를 로컬 Keychain 에 저장
./notarize.sh --store-credentials

# 빌드 + 서명 + Apple 제출 + 스테이플
./notarize.sh
```

`MLXControl-notarized.zip` 이 생성되어 GitHub Releases 에 첨부 가능. 자격증명은 로컬
Keychain 에 저장됨(커맨드라인·git 에 절대 노출 안 됨). 앱 암호는
[appleid.apple.com](https://appleid.apple.com) → 로그인 및 보안 → 앱 암호 에서 생성.
Team ID 는 서명 인증서에서 자동 감지됨.

## 보안

- **셸 문자열 인터폴레이션 없음** — 모든 subprocess 호출은 `Process` 인자 배열 사용
- **경로 검증** — 모델 삭제 시 repo ID 형식 검증 + HuggingFace 캐시 디렉토리 안으로만 제한
- **도구 자동 탐지** — `mlx_lm.server`·`hf` 를 PATH 탐색으로 찾음(경로 하드코딩 없음)
- **네트워크 접근 최소** — HuggingFace API(검색/메타데이터)와 로컬 추론 서버 외엔 없음

## 라이선스

MIT — [LICENSE](LICENSE) 참고
