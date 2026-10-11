# Homebrew cask skeleton for a personal tap (not the official homebrew/cask).
#
# Publish it in a repo named <owner>/homebrew-tap as Casks/purrifier.rb, then:
#   brew install --cask <owner>/tap/purrifier
#
# After each release, update `version` and `sha256` (from SHA256SUMS.txt on the release).
# TODO(owner): replace OWNER with your GitHub user name and dev.owner with your bundle ID prefix.
cask "purrifier" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/OWNER/purrifier-philips-air-purifier-macos/releases/download/v#{version}/Purrifier-v#{version}.dmg"
  name "Purrifier"
  desc "Menu bar app for Philips Air+ purifiers using local encrypted CoAP"
  homepage "https://github.com/OWNER/purrifier-philips-air-purifier-macos"

  depends_on macos: ">= :sonoma"

  app "Purrifier.app"

  zap trash: [
    "~/Library/Containers/dev.owner.purrifier",
    "~/Library/Preferences/dev.owner.purrifier.plist",
  ]

  caveats <<~EOS
    Purrifier is not affiliated with or endorsed by Philips or Versuni.
    On macOS 15 and later, allow Local Network access when prompted.
  EOS
end
