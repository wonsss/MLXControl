# Homebrew Cask 공식 제출용 템플릿.
# 실제 제출 전: SHA256·버전·URL 업데이트 후
# homebrew/homebrew-cask 에 PR 생성.
#
# 자체 탭으로 먼저 배포하려면:
#   gh repo create wonsss/homebrew-tools --public
#   이 파일을 Casks/mlxcontrol.rb 로 복사 후 push
#   사용자: brew tap wonsss/tools && brew install --cask mlxcontrol
cask "mlxcontrol" do
  version "0.1.1"
  sha256 "95f2c19f9cb15bd4bef705c5e978684aadc477628cd65bfac967205521142023"

  url "https://github.com/wonsss/MLXControl/releases/download/v#{version}/MLXControl-#{version}.dmg"
  name "MLX Control"
  desc "Native macOS menu bar app to manage a local mlx-lm inference server"
  homepage "https://github.com/wonsss/MLXControl"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "MLXControl.app"

  zap trash: [
    "~/Library/Application Support/io.github.wonsss.mlxcontrol",
    "~/Library/Preferences/io.github.wonsss.mlxcontrol.plist",
    "~/Library/Logs/MLXControl",
  ]
end
