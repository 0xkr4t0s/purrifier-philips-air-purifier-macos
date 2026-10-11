# Homebrew cask skeleton for a personal tap (not the official homebrew/cask).
#
# Publish it in a repo named 0xKr4t0s/homebrew-tap as Casks/purrifier.rb, then:
#   brew install --cask 0xkr4t0s/tap/purrifier
#
# After each release, update `version` and `sha256` (from SHA256SUMS.txt on the release).
cask "purrifier" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/0xKr4t0s/purrifier-philips-air-purifier-macos/releases/download/v#{version}/Purrifier-v#{version}.dmg"
  name "Purrifier"
  desc "Menu bar app for Philips Air+ purifiers using local encrypted CoAP"
  homepage "https://github.com/0xKr4t0s/purrifier-philips-air-purifier-macos"

  depends_on macos: ">= :sonoma"

  app "Purrifier.app"

  zap trash: [
    "~/Library/Containers/dev.0xkr4t0s.purrifier",
    "~/Library/Preferences/dev.0xkr4t0s.purrifier.plist",
  ]

  caveats <<~EOS
    Purrifier is not affiliated with or endorsed by Philips or Versuni.
    On macOS 15 and later, allow Local Network access when prompted.
  EOS
end
