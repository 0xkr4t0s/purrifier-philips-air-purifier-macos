# Purrifier.app (menu bar app): milestone M3

This folder holds the SwiftUI `MenuBarExtra` app **Purrifier**, a native macOS menu bar
controller for Philips Air+ purifiers. It is a placeholder until milestone M3; the
networking and protocol work lives in the Swift package one level up (`AirLink`,
`PurifierModel`), which this target depends on.

## Build

```sh
brew install xcodegen
cd App
xcodegen generate          # writes Purrifier.xcodeproj (not committed)
open Purrifier.xcodeproj   # or:
xcodebuild -project Purrifier.xcodeproj -scheme Purrifier -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The bundle ID is `dev.0xkr4t0s.purrifier`. Forks should change `bundleIdPrefix` and
`PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to their own reverse-DNS name before signing, and
choose a development team.

## Security posture

- **App Sandbox** on, with a single entitlement: `com.apple.security.network.client`
  (outgoing connections). See `Purrifier/Purrifier.entitlements`.
- **Hardened Runtime** on.
- `NSLocalNetworkUsageDescription`: "Purrifier talks to your air purifier on your local
  network." macOS 15+ asks for Local Network permission on first contact; a denial shows
  up as an unreachable device, and the app must explain how to re-enable it.
- `LSUIElement`: menu bar only, no Dock icon.

## Planned (M3, see plan.md "Menu bar UX")

- Status item: a minimal cat-ear/fan glyph tinted by air quality, dimmed when off, slashed
  when unreachable. No Philips artwork.
- Panel: power toggle, Auto/Sleep/Turbo segmented control, PM2.5 / allergen index readouts,
  filter gauge, "last update" time, reconnect button. Child lock and light rows only if the
  device reports those keys.
- Settings: device host/port (always configurable), timeouts, launch at login
  (`SMAppService.mainApp`), debug log export with frames redacted unless opted in.
- About window: "Purrifier for Philips Air+ purifiers", plus the trademark disclaimer.
