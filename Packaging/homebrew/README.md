# Homebrew packaging

`purrifier.rb` is a cask for a **personal tap**. Homebrew's official cask repository now
requires Gatekeeper-passing (signed and notarized) apps; a personal tap doesn't, but
Gatekeeper still applies on the user's Mac, so releases are notarized from day one (see
`.github/workflows/release.yml`).

1. Create a GitHub repo `0xKr4t0s/homebrew-tap`.
2. Copy `purrifier.rb` to `Casks/purrifier.rb` there, filling in `version` and `sha256`.
3. Users install with `brew install --cask 0xkr4t0s/tap/purrifier`.

Without a paid Apple Developer account (no notarization), the second-best route is to tell
users to run `xattr -dr com.apple.quarantine /Applications/Purrifier.app` after installing,
and to explain why. Homebrew deprecated `--no-quarantine`.

A formula for the `purrctl` CLI on its own can follow the same pattern once releases ship a
universal `purrctl` zip.
