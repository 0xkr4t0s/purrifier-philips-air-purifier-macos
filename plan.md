# Purrifier: Building a Native Swift Menu Bar Controller for the Philips AC0850/70 (800i)

### Protocol Dossier, Implementation Plan, and Agent Kickoff Prompt

**Revision 2 (11 October 2026).** Changes from revision 1: the app name is **Purrifier** (revision 1 used the placeholder "Airtap"), the CLI is **`purrctl`**, the target unit is an **AC0850/70** (Australian market), and the agent prompt in Deliverable 2 has been replaced with the final version.

You can build a fully native Swift client for the AC0850. Several independent implementations already document the protocol: CoAP over UDP 5683, a `/sys/dev/sync` handshake that returns a hex counter, and AES-128-CBC with a key and IV taken from MD5("JiangPan" + counter), plus a SHA-256 integrity digest. The hard parts are not the crypto. They are (a) the three generations of JSON keys (your AC0850 is probably on the third, `D03102`-style, but some AC0850/20 units use an older `D03-02` scheme), and (b) firmware that is flaky and on some builds only pushes status. Plan for those first.

## TL;DR

- **The protocol is small and well documented, and a native port is realistic in a weekend.** It has three CoAP resources (`/sys/dev/sync`, `/sys/dev/status` observed, `/sys/dev/control`). The payload is framed as `counter(8 hex) ‖ AES-128-CBC ciphertext (uppercase hex) ‖ SHA-256(counter‖cipherhex) (64 uppercase hex)`. The key and IV are the two halves of the uppercase MD5 hex of `"JiangPan" + counter`, used as ASCII bytes. Hand-roll a minimal RFC 7252 codec on `NWConnection` and use CryptoKit/CommonCrypto. Do not use SwiftCoAP, which depends on Objective-C CocoaAsyncSocket and was last updated for Swift 4.2.
- **The AC0850 third-generation key map (from an AC0850/11) is:** power `D03102` (1/0); mode `D0310C` (0 = Auto, 17 = Sleep, 18 = Turbo); actual fan speed `D0310D`; PM2.5 `D03221`; allergen index (IAI) `D03120`; preferred index `D0312A`; error `D03240`; filter remaining/total hours `D0540E`/`D05408`; model `D01S05`. The /11 dump contains no child-lock or display-light keys, so detect capabilities from key presence rather than hard-coding them.
- **Your AC0850/70 is undocumented.** No public status dump exists for the /70. The key scheme follows the Wi-Fi firmware string rather than the suffix, so your first status dump decides which scheme you implement first.
- **Make reliability your differentiator.** Use per-request timeouts, resync on any digest or timeout failure, a watchdog for observe streams that go silent, and handling for push-only firmware. The Home Assistant integrations still hang for hours here. Start with milestone M1: a CLI (`purrctl`) that syncs, reads status, and sets `D0310C`, verified byte-for-byte against `aioairctrl` on your own unit.

## Key Findings

### 1. Prior work: lineage and what to port from

| Project | Role | What to take |
|---|---|---|
| rgerganov/py-air-control + xakcop.com post (Jan 2019) | Original reverse engineering. The post covers the older HTTP/DiComm Diffie-Hellman scheme; the repo's `coap_client.py` has the encrypted-CoAP client | The clearest single-file reference for sync, counter, key/IV, digest and framing |
| betaboon/aioairctrl → kongo09/aioairctrl (PyPI `aioairctrl` 0.3.1, Mar 1 2026, MIT, Python ≥3.12) | Async library used by the HA integration; built on aiocoap + pycryptodomex | Your **test-vector oracle** and live-comparison tool (`aioairctrl -H <ip> --debug status`) |
| kongo09/philips-airpurifier-coap (HA custom component; fork of Denaun's, which reworked betaboon's) | Model and key mapping | The `PhilipsApi` constants in `const.py` and the per-model classes |
| ruaan-deysel/ha-philips-airpurifier + philips-airctrl | Newer HA integration and library (Apache-2.0 integration, MIT library) | Discovery patterns, push-only firmware handling |
| biemond/com.athom.philipsair (Homey) | JS implementation, verified on AC0850/11 | A second independent implementation to cross-check against |
| FJRG2007/polaris PR #299 (Oct 2026) | TypeScript port with its own RFC 7252 codec | Evidence that a hand-rolled codec matching aiocoap's bytes works; good reconnect and backoff design notes |
| atdr/homebridge-philipsair-platform | Homebridge plugin (shells out to aioairctrl), lists AC0850 | Model-detection UX ideas |

**Correction to the original brief:** the xakcop.com post describes the older HTTP protocol (`PUT /di/v1/products/0/security`, Diffie-Hellman with a 31-bit exponent that is crackable with baby-step giant-step). It does not describe the CoAP scheme your AC0850 uses. The CoAP scheme lives in the py-air-control code and in aioairctrl. In your write-up, cite the blog for history and the code for the protocol.

I found no existing Swift, Go or Rust port. The non-Python ports are JS (Homey, `node-red-contrib-philips-airjs`, the `philips-air` npm package) and TypeScript (polaris). Purrifier would be the first Swift port, which is a good portfolio angle.

### 2. Transport and endpoints

- **Transport:** CoAP (RFC 7252) over UDP, port **5683**, with no DTLS. aioairctrl's PyPI page states that Philips AC-series purifiers expose a CoAP endpoint on port 5683 of the local network.
- **`POST /sys/dev/sync`:** the request payload is 8 random uppercase hex characters (4 random bytes, hexlified). The response payload is the device's **client key/counter** as hex text. Store it as-is.
- **`GET /sys/dev/status` with Observe = 0:** this registers an observation. Each notification is an encrypted frame. After decrypting, unwrap `json["state"]["reported"]`.
- **`POST /sys/dev/control`:** the body is an encrypted frame wrapping `{"state":{"desired":{"CommandType":"app","DeviceId":"","EnduserId":"", <key>: <value>, ...}}}`. The response is **plain** JSON, and success is exactly `{"status":"success"}`.
- **Message type and token:** py-air-control sets no explicit token or type (it uses library defaults), and aiocoap's default is Confirmable. **Uncertain:** whether the device needs CON specifically. Default to CON with a random 4–8-byte token, match responses by token and message ID, and ACK any CON notifications.
- **Push-only firmware:** one user reported that on firmware `AWS_Philips_AIR_Combo@86` (AMF870, and the same was claimed for an AC0850), a plain GET is never answered. Observe = 0 is answered only at the next device push, and in standby pushes can stop for 12 minutes to about 2 hours while `/sys/dev/sync` still answers. ruaan-deysel's README says the CX7550's push-only firmware is handled by briefly toggling the display backlight to elicit an update. This comes from one user's issue report (ruaan-deysel #132) plus the maintainer's README, so treat it as credible but not universal.

### 3. Encryption and framing, byte by byte

Taken from `py-air-control/pyairctrl/coap_client.py`. aioairctrl implements the same scheme; confirm against your own captures.

```
SECRET = "JiangPan"

deriveCipher(counterHex):            # counterHex is ASCII uppercase hex, e.g. "08ABBEC7"
  h  = MD5(ASCII(SECRET + counterHex)).hexdigest().upper()   # 32 ASCII chars
  key = ASCII(h[0..<16])             # 16 bytes: the ASCII *characters*, not decoded hex
  iv  = ASCII(h[16..<32])
  return AES-128-CBC(key, iv), PKCS#7, block 16

encrypt(jsonString):
  counter = uppercase(hex(int(counter,16) + 1))   # increment BEFORE every send; no zero-pad in reference
  ct      = AES-CBC-PKCS7(UTF8(jsonString)) with deriveCipher(counter)
  ctHex   = uppercase(hex(ct))
  digest  = uppercase(hex(SHA256(ASCII(counter + ctHex))))
  return ASCII(counter + ctHex + digest)          # CoAP payload

decrypt(payload):
  c      = payload[0..<8]            # device's own counter
  ctHex  = payload[8..<len-64].upper()
  dig    = payload[len-64..<len]
  require dig == uppercase(hex(SHA256(ASCII(c + ctHex))))  else WrongDigest
  return unpadPKCS7(AES-CBC-decrypt(hexDecode(ctHex)) with deriveCipher(c))
```

Points to flag in your code and write-up:

- **The key and IV are ASCII hex characters.** The effective key entropy is 64 bits (16 hex characters), and the "secret" is a hard-coded constant. Anyone who sees a frame can decrypt it, because the counter travels in cleartext.
- **The digest is an unkeyed SHA-256, not an HMAC.** It detects corruption but gives no authenticity. An attacker can forge valid frames.
- **The counter is incremented only on send. Decrypt uses the counter embedded in the device's frame.** The reference formats with `"{:x}"`, which has no zero padding. If the device's counter is near `FFFFFFFF`, a 9-character counter could appear, and the decrypt side assumes exactly 8. Treat this as an edge case: write a test for it, and resync on any length anomaly.
- The client-to-device counter must stay in step with what the device expects. Any mismatch shows up as a non-success control response or a timeout, and the fix is a resync.

### 4. JSON key generations and the AC0850 map

kongo09's `const.py` documents three schemes: gen1 short keys (`pwr`, `om`, `mode`, `cl`, `uil`, `pm25`, `iaql`, `fltsts*`), gen2 `D0x-yy` keys (the "AC1715 scheme": `D03-02` power, `D03-05` backlight, `D03-12` mode, `D03-32` IAI, `D03-33` PM2.5, `D03-42` preferred index), and gen3 `D0xxxx` keys (a third generation of devices with yet another scheme).

The integration splits the AC0850 into separate entries by Wi-Fi firmware, for example `AC0850/11 AWS_Philips_AIR` and `AC0850/11 AWS_Philips_AIR_Combo`. In issue #139, the protocol split tracked the **firmware string** (`AWS_Philips_AIR_Combo@1.2`, `@1.3`), not the regional suffix. One contributor fixed an AC0850/31 just by applying the /11 fix, and an AC0850/20 user reported the older `D01-xx`/`D03-xx` keys in issue #73. "Combo" here is firmware naming, not a humidifier: a contributor who photographed the unit said it looked like a regular purifier and that Philips appears to reuse firmware across models.

**Your AC0850/70.** I found no public reports, status dumps or integration entries for the /70 variant. Because the key scheme follows the firmware string, the /70 will most likely match one of the documented AC0850 builds, but you can't know which until you run `aioairctrl -H <ip> status -J`. Record `D01S05` (model), `WifiVersion` and `D01S12` (software version) from that dump in your README and fixtures. Your project would be the first public documentation of the /70.

**AC0850/11, firmware `AWS_Philips_AIR_Combo@1.2` (gen3), observed in issue #139:**

| Function | Key | Values observed / meaning | Confidence |
|---|---|---|---|
| Power | `D03102` | 1 on, 0 off | High (many models) |
| Mode (write target) | `D0310C` | 0 = Auto, 17 = Sleep, 18 = Turbo | High. Note the reporter labelled the Auto dump "Turbo"; the values make it clear |
| Actual fan speed (read-only) | `D0310D` | Sleep → 1, Turbo → 18, Auto → varies (1 seen) | Medium |
| Function/mode A | `D0310A` | 2 (constant on purifier-only units) | Medium |
| PM2.5 (µg/m³) | `D03221` | integer | High |
| Allergen index (IAI) | `D03120` | integer (1 seen) | High |
| Preferred display index | `D0312A` | 0 = IAI, 1 = PM2.5 | High |
| Error code | `D03240` | bitfield; 0 = OK | High |
| Filter remaining / total (hours) | `D0540E` / `D05408` | 4788 / 4800 | High |
| Standby sensors | `D03134` | 1/0 | Medium |
| Model, name, SW version | `D01S05`, `D01S03`, `D01S12` | "AC0850/11", "Bedroom", "0.1.3" | High |
| Diagnostics | `rssi`, `WifiVersion`, `DeviceId`, `ProductId`, `Runtime`, `free_memory` | — | High |
| Child lock | `D03103` | **absent from the /11 dump** | Likely unsupported on AC0850 |
| Display light | `D0312D` / `D03105` | **absent from the /11 dump** | Likely unsupported on AC0850 |

**What this means for your UX:** the AC0850 offers Off/Auto/Sleep/Turbo plus PM2.5, IAI and filter life. That matches the AC0850/20 owner's description in issue #73 of three modes (Sleep, Auto and Turbo) and no other buttons on the device. There are no discrete fan speeds 1–3. Build child lock and light controls generically, but show them only when the key appears in status. Your first `status --raw` dump settles this for your unit. For comparison, the AC0950 (gen3, firmware `@3.0`) does expose child lock `D03103` and brightness `D03104`/`D03105`, with brightness values 0/115/123.

**Gen2 (some AC0850/20 on `AWS_Philips_AIR`):** power `D03-02`, mode `D03-12`, IAI `D03-32`, PM2.5 `D03-33`. **Uncertain:** the exact value literals for gen2 power and mode, which may be strings. Verify on hardware before implementing.

**Control payload for a gen3 unit (to verify in M1):** `{"D03102":1,"D0310C":17}` as integers. With aioairctrl that is `set -I D03102=1 D0310C=17`. The polaris review notes that writing gen1 `pwr` to a gen3 unit is ignored or refused, so key-generation detection must happen **before** the first write.

### 5. Discovery

- ruaan-deysel's integration auto-discovers by **DHCP MAC prefix** (`B0F893*`, `047863*`, `849DC2*`, `80A036*`) and **hostname** `mxchip*`. That implies an MXCHIP Wi-Fi module. kongo09's README says discovery is based on the MAC address and original hostname.
- No source documents mDNS/Bonjour advertisement by the purifier, so don't rely on it.
- A practical macOS approach: (1) manual IP/hostname entry as the primary path; (2) an optional /24 unicast probe that sends a sync to every host on 5683 (philips-airctrl and polaris both do this); (3) an ARP-table lookup (`arp -an`) filtered by the OUI prefixes as a hint. After first contact, identify the device by `DeviceId` so that DHCP changes can be followed automatically. Tell users to set a DHCP reservation.

### 6. Instability: what the existing implementations fight

- kongo09's README warns that the integration is unstable because of a bug in the Philips devices; sometimes a power cycle of the purifier helps, and sometimes only a power cycle plus a Home Assistant restart does.
- **HA issue #363 (aioairctrl 0.3.1, v0.36.2):** `set_control_values` has no timeout, and the reconnect timer is reset by observe packets. A `set_preset_mode` hung for about 1 h 46 min and then failed with `aiocoap.error.LibraryShutdown`. The lesson: put a timeout on every request, and keep command health separate from observe health.
- **HA PR #388 (Oct 2026):** the integration rebuilds the client, which means a resync, every 3 × max-age (180 s) when a device pushes nothing. Logs show `syncing → synced: 08ABBEC7 → observing status`.
- **polaris design (not hardware-validated):** wake a wedged unit with a fresh sync on a new socket, with backoff doubling up to 60 s; follow a moved unit by its ID; for push-only firmware, keep one long-lived link and send commands on it.

### 7. Philips → Versuni

According to Versuni's press release of 17 February 2023, Philips Domestic Appliances changed its company name to Versuni and continues to use the Philips consumer brand as a licensee of Royal Philips. The rename followed the split from Royal Philips in September 2021 and the sale to Hillhouse Capital. The Air+ app is published by Versuni Netherlands B.V (App Store id1487415423; Android `com.philips.ph.homecare`), with frequent 2025 releases (3.13.0 in March 2025 through 3.16.2 in November 2025) whose notes mostly say only that the range of devices was expanded. Support email is `airpurifier.service@versuni.com`. The privacy notice says the app collects device data (ID, mode, power, fan speed, commands) and air-quality data, which supports a privacy-oriented "local only, no cloud" pitch in your README. The cloud API is not public, according to both HA integrations.

Risk: ruaan-deysel warns that some newer firmware versions may disable local CoAP communication. **Recommendation: do not apply Air+ firmware updates blindly once Purrifier works.** Record your `WifiVersion` and `D01S12` in the README.

## Details: Implementation Plan

### Architecture

```
Package.swift (SwiftPM, swift-tools 6.0, strict concurrency)
├─ Sources/
│  ├─ CoAPCore/            # pure value types: Message encode/decode (RFC 7252 header, token, options delta/len, 0xFF marker), Observe option
│  ├─ PhilipsCrypto/       # LegacyPhilipsCipher: deriveKeyIV, encrypt/decrypt, digest; Counter type (hex, +1, width policy)
│  ├─ AirLink/             # actor CoAPTransport (NWConnection UDP), actor PurifierSession (sync, request/response, observe → AsyncThrowingStream)
│  ├─ PurifierModel/       # KeyGeneration detection, DeviceCapabilities, PurifierState (typed), Command → JSON mapping, model table
│  └─ purrctl/             # CLI (swift-argument-parser): sync | status [--raw|--json] | observe | set k=v | set-mode | power | probe <cidr>
├─ Tests/ (CoAPCoreTests, PhilipsCryptoTests w/ vectors, PurifierModelTests w/ fixture JSON, SessionTests vs FakePurifier)
├─ Tools/FakePurifier/     # in-process + standalone UDP simulator (NWListener) implementing the device side
└─ App/ (XcodeGen project.yml) → SwiftUI MenuBarExtra target "Purrifier" depending on the package
```

**Hand-roll CoAP rather than using SwiftCoAP.** SwiftCoAP is MIT and supports Observe, but it requires copying files and bridging `GCDAsyncUdpSocket.h` from Objective-C CocoaAsyncSocket, and its README says it was updated for Swift 4.2. You need only about 300 lines: a 4-byte header, a token, options (Uri-Path 11, Observe 6, Content-Format 12, Max-Age 14), the payload marker, CON retransmission with exponential backoff (ACK_TIMEOUT 2 s, MAX_RETRANSMIT 4), ACK and RST handling, and message-ID deduplication. That is also a better portfolio artifact. Unicast UDP over `NWConnection` is fine; Apple's forum guidance is that `NWConnection` does not support multicast, which you don't need.

**Crypto:** CryptoKit has `Insecure.MD5` and `SHA256` but **no AES-CBC**, so use CommonCrypto's `CCCrypt(kCCAlgorithmAES, kCCOptionPKCS7Padding)` for CBC, wrapped in a tiny type-safe API. Name the wrapper honestly (`LegacyPhilipsCipher`) and document why CBC with a static secret is insecure.

**Concurrency model:**
- `actor PurifierSession` owns the counter. All encrypts are serialized, so there are no counter races.
- `func status() async throws -> PurifierState`, `func send(_ cmd: Command) async throws`, `var updates: AsyncThrowingStream<PurifierState, Error>`.
- Wrap every request in `withThrowingTaskGroup` with a timeout race. Use defaults of 4 s for sync and 6 s for control, and make them configurable.
- `@MainActor @Observable final class DeviceStore` in the app consumes the streams. This needs macOS 14.

### Reliability strategy (the differentiator)

1. **State machine:** `idle → syncing → observing ⇄ degraded → resyncing → (backoff) → syncing`.
2. **Triggers for resync:** a timeout on any request, a digest mismatch, a control response other than `{"status":"success"}`, a malformed counter, or observe silence longer than max(3 × Max-Age, 180 s) while the device is powered.
3. **Control path:** `send` → on failure, resync once and resend once (polaris does this) → otherwise surface the error in the UI ("Purifier not responding — a power-cycle may be required").
4. **Fresh socket on resync.** Tear down the `NWConnection` and create a new one, since some firmware appears to wedge per source port. This is plausible but unproven; make it a toggle.
5. **Push-only mode:** if an initial Observe gets no reply within N seconds but sync works, mark the device `pushOnly`, keep one long-lived link, and optimistically update the UI after a successful control. Only consider the "nudge a harmless setting" trick behind an explicit opt-in.
6. **Backoff:** exponential with jitter, from 1 s up to a 60 s cap. Reset after 5 minutes of health.
7. **Wake and network changes:** use `NWPathMonitor` and `NSWorkspace.didWakeNotification` to trigger an immediate resync.

### Menu bar UX

- **Status item:** a minimal cat-ear/fan glyph or an SF Symbol (`aqi.low` / `aqi.medium` / `aqi.high`), tinted by IAI or PM2.5 band, with optional text "12 µg". Dimmed when off; a slash glyph when unreachable. Keep the cat theming light and never let it cost clarity.
- **`MenuBarExtra(.window)` panel:** a device picker if there are several devices; a large power toggle; a segmented mode control (Auto / Sleep / Turbo, extended per capabilities); PM2.5, IAI and preferred-index readouts; a filter gauge (`D0540E / D05408`, shown as %, with "replace soon" at 10% or less as in the HA thresholds); child lock and light rows only if supported; "last update Xs ago"; and a reconnect button.
- **Settings window:** devices (IP/host, name, test connection, probe subnet), polling and timeout tuning, notification thresholds, launch at login (`SMAppService.mainApp`), and a debug log export with frames redacted unless opted in.
- **Notifications** (`UNUserNotificationCenter`): filter below threshold, PM2.5 above threshold for N minutes, device unreachable for more than 10 minutes, and error code bits set.
- **Extras for later:** App Intents / Shortcuts ("Set purifier to Sleep"), global hotkeys, a WidgetKit widget.
- **Local Network permission:** macOS Sequoia requires a Local Network privacy prompt before an app can reach the LAN; Apple documents this in technote TN3179, "Understanding local network privacy". Howard Oakley (Eclectic Light) advises not relying on the behaviour before macOS 15.3, and notes TN3179's advice to sign the app with an Apple-issued code-signing identity so the permission tracks it reliably. These come from search excerpts I did not open, so check them before citing. Add `NSLocalNetworkUsageDescription` ("Purrifier talks to your air purifier on your local network.") and handle a denied state gracefully. When run from Terminal, `purrctl` is attributed to Terminal.

### Testing

- **Crypto vectors:** write `Tools/gen_vectors.py`, which imports py-air-control's or aioairctrl's cipher functions, fixes the counter (e.g. `"0000000A"`, `"08ABBEC7"`, `"7FFFFFFF"`, `"FFFFFFFF"`) and the plaintext, and emits JSON `{counter, plaintext, keyAscii, ivAscii, ctHex, digest, frame}`. Commit the JSON and test Swift against it. Include negative cases: tampered digest, bad padding, short frame, and a 9-character counter.
- **CoAP codec:** golden-byte tests (capture aioairctrl's packets with `--debug` or Wireshark's CoAP dissector), round-trip property tests, and option delta extension cases (13/14).
- **Model mapping:** fixture JSON from issue #139 (AC0850/11 Auto/Sleep/Turbo/Off) and your own AC0850/70 dumps in `Tests/Fixtures/ac0850-70/` → `PurifierState` assertions; generation detection for all three schemes.
- **FakePurifier simulator:** an `NWListener` that implements sync, Observe and control with scripted faults (drop the Nth packet, stop pushing, return failure, wedge until resync). Use it for session state-machine tests.
- **Hardware-in-the-loop:** a `make hil IP=…` target, excluded from CI.

### Security considerations and portfolio angle

**Threat model (STRIDE-lite) for local, unauthenticated control:**
- **Spoofing and tampering:** any LAN host can sync and send commands. There is no pairing, user binding or MAC.
- **Information disclosure:** the static secret means passive sniffing reveals air-quality data, room name, `DeviceId` and RSSI (occupancy inference).
- **Denial of service:** UDP plus a fragile firmware means a flood of syncs may wedge the device. Test this **only on your own unit** and frame it as a finding.
- **Amplification:** CoAP is a known reflection vector, though LAN-only exposure limits it.
- **Elevation:** firmware update paths are out of scope.

**Write-up deliverable (`docs/PROTOCOL.md` + a blog post):** history (DiComm HTTP with weak DH → encrypted CoAP), the byte-level framing, why "encryption" here is obfuscation, a Wireshark Lua dissector that decrypts frames live (an excellent red-team/AppSec artifact), the first public documentation of the AC0850/70, and mitigations for users (IoT VLAN, block the device's WAN access if you don't need the cloud, DHCP reservation). These weaknesses are already public, so no embargo is needed, but don't publish DoS tooling.

**App hardening:** keep the App Sandbox on with only `com.apple.security.network.client`; enable Hardened Runtime; never log decrypted frames by default; validate and bound all JSON (sizes, types).

### Project setup

- **Build system:** SwiftPM for all libraries and `purrctl`, plus XcodeGen (commit `project.yml`) for the Purrifier `.app` (asset catalog, Info.plist, entitlements, signing).
- **Minimum OS: macOS 14 (Sonoma).** `MenuBarExtra` and `SMAppService` need macOS 13 and `@Observable` needs 14. Build universal (arm64 + x86_64).
- **Signing and distribution:** Developer ID + notarization (`xcrun notarytool`) via GitHub Actions on tags, with secrets in the repo environment. Ship a DMG or zip. Provide a Homebrew cask in your own tap (`brew install --cask <owner>/tap/purrifier`). Homebrew's 5.0.0 release post (12 November 2025) deprecated casks without codesigning, set September 2026 as the date to disable official-tap casks that fail Gatekeeper, and deprecated `--no-quarantine`. That applies to the official homebrew-cask tap, not a personal tap, but Gatekeeper still applies, so notarize from day one. Without a paid account, document the `xattr -dr com.apple.quarantine` workaround as second-best.
- **CI:** `macos-15` runners: `swift build`, `swift test`, SwiftLint/SwiftFormat, `xcodebuild` for the app, a CodeQL Swift scan (a portfolio signal), and the Python vector-generation job to check that vectors are reproducible.
- **License:** MIT, which matches aioairctrl and py-air-control and allows simple attribution. Add `CREDITS.md` naming rgerganov, betaboon, Denaun, kongo09, ruaan-deysel and biemond. You are reimplementing from protocol knowledge, not copying code. If you ever copy code, preserve the original notices (the ruaan-deysel integration is Apache-2.0).
- **Name and SEO:**
  - App name **Purrifier**; CLI `purrctl`; environment variables prefixed `PURRIFIER_`; bundle ID `dev.<owner>.purrifier`.
  - Search engines tend to autocorrect "Purrifier" to "purifier", and a litter-box odour filter sold as the "Purr-ifier" shares the pun. So the descriptive repo slug and README carry the SEO: repo **`purrifier-philips-air-purifier-macos`**, description "Purrifier — native macOS menu bar app for Philips Air+ purifiers (AC0850/800i). Local encrypted CoAP, no cloud."
  - Topics: `philips`, `air-purifier`, `macos`, `menubar`, `menu-bar-app`, `swiftui`, `coap`, `swift`, `iot`, `reverse-engineering`, `home-automation`, `local-control`.
  - Always pair the name with "for Philips Air+ purifiers" in the README title, release notes and the About window.
- **Trademark:** Philips is a trademark of Royal Philips, and Versuni uses it as a licensee. Keep it out of the app name, icon and bundle ID. Use nominative fair-use phrasing ("works with Philips Air+ purifiers") and a disclaimer ("Not affiliated with or endorsed by Philips or Versuni. Philips is a trademark of Koninklijke Philips N.V."). Don't reuse Philips icons; kongo09's integration bundles the original Philips icons, which you should not copy.

### Milestones and acceptance criteria

| Milestone | Scope | Acceptance criteria |
|---|---|---|
| **M0: Recon (half a day)** | Install `aioairctrl`; run `status -J`, `status-observe`, `set -I D0310C=17` against your AC0850/70; capture with Wireshark | Raw dumps for Off/Auto/Sleep/Turbo saved to `Tests/Fixtures/ac0850-70/`; `D01S05`, `WifiVersion`, `D01S12` and key generation recorded; vectors generated |
| **M1: CLI MVP** | CoAPCore, PhilipsCrypto, AirLink (sync, single observe-read, control); `purrctl status`/`set`/`set-mode` | `purrctl --host <ip> status --json` matches aioairctrl's output on the same unit; `purrctl set-mode sleep` changes the unit within 2 s; all vector tests pass; frames are byte-identical to aioairctrl for the same counter |
| **M2: Robust session** | Observe stream, timeouts, resync/backoff, FakePurifier, generation detection | 24 h `purrctl observe` soak with no manual intervention, and automatic recovery from Wi-Fi drop and device power-cycle; simulator fault tests green |
| **M3: Menu bar app** | Purrifier MenuBarExtra, DeviceStore, settings, launch at login | Cold start to controllable in under 2 s (vs 10–15 min for Air+); all AC0850 modes and power work; capability-gated controls |
| **M4: Notifications + multi-device** | Thresholds, filter alerts, device list, subnet probe | Two devices (or one real + simulator) controllable; notifications fire under simulated conditions |
| **M5: Release** | Signing, notarization, cask, docs, protocol write-up, Wireshark dissector | Tagged v0.1.0 notarized; `brew install --cask <owner>/tap/purrifier` works on a clean Mac; PROTOCOL.md (including the AC0850/70 findings) and threat model published |

## Recommendations

1. **Do M0 before writing any Swift.** Your suffix is /70, but what decides the implementation is your **`WifiVersion` and key set**. One `aioairctrl -H <ip> status -J` dump answers this.
2. **Build the vector generator first**, so that Python is the oracle and every Swift crypto change is checked against it.
3. **Treat child lock and display light as unsupported on the AC0850 until a dump from your /70 shows the keys.** Don't spend UX effort on them yet.
4. **Freeze purifier firmware updates** once local control works. Keep the Air+ app only for initial Wi-Fi onboarding.
5. **Lead the README with the reliability story** (timeouts, resync, push-only handling). Measurably beating the HA integration's hang behaviour is a strong portfolio claim.

## Caveats

- No public data exists for the **AC0850/70**. Everything about the AC0850 key map comes from other variants until your M0 dump confirms it.
- The mode values (0/17/18) and the absence of child lock and light come from **one community dump** (AC0850/11, `@1.2`). Other firmware builds (`@1.3`, `@86`) may differ.
- I could not read aioairctrl's `client.py`/`encryption.py` or kongo09's per-model classes verbatim. The crypto details come from py-air-control's code, which aioairctrl derives from, and are corroborated by the polaris port description. The exact AC0850 write payload the HA integration sends (for example, whether it writes `D03102` and `D0310C` together) is **unverified**. Confirm it in M0.
- Gen2 value literals, CON vs NON requirements, and counter width at wrap-around are **uncertain**.
- The push-only and standby-silence behaviour comes from individual user reports, not systematic testing.
- Polaris's driver is explicitly untested on real hardware. Use it for design ideas, not as ground truth.

## Deliverable 2: Initial Prompt for an AI Coding Agent

```text
You are scaffolding "Purrifier", an open-source, fully native macOS menu bar app (Swift 6, SwiftUI) that controls a Philips Air+ air purifier (model AC0850/70 "800i", Australian-market unit) over its LOCAL encrypted CoAP protocol — no cloud, no Python at runtime. Owner is an AppSec/red-team student; code must be portfolio quality: clean architecture, strict concurrency, tests, CI, docs. Do NOT use "Philips" in the app name, bundle ID, or icon. License: MIT. Credit prior work in CREDITS.md: rgerganov/py-air-control, betaboon & kongo09/aioairctrl, Denaun & kongo09/philips-airpurifier-coap, ruaan-deysel/ha-philips-airpurifier, biemond/com.athom.philipsair.

## Read plan.md first
`plan.md` in the repo root is the full design document for this project: the protocol dossier (transport, byte-level crypto and framing, JSON key generations, the AC0850 key map), discovery, the known firmware instability, the architecture, the reliability strategy, menu bar UX, testing, the threat model, project setup, and milestones M0–M5 with acceptance criteria. This prompt is a condensed brief for Milestone 1.
- Read all of plan.md before writing any code, and consult it whenever you need detail or rationale this prompt doesn't give.
- If this prompt and plan.md disagree, follow this prompt and point out the conflict in your summary.
- Respect the uncertainties plan.md flags (its "Caveats" section and anything marked unverified or uncertain): don't present them as fact in code comments or docs, and add a TODO wherever an implementation depends on one.
- Don't edit plan.md. Record new findings (e.g. the AC0850/70 status dump) in docs/PROTOCOL.md and the test fixtures, and list anything that would change plan.md in your summary so the owner can update it.

## Naming and SEO
- App name: Purrifier. Bundle ID: `dev.<owner>.purrifier` (placeholder; ask owner). CLI binary: `purrctl`. Env var prefix: `PURRIFIER_`.
- Repo slug: `purrifier-philips-air-purifier-macos`. Search engines tend to autocorrect "Purrifier" to "purifier", so the descriptive slug and README headings carry the SEO.
- GitHub description: "Purrifier — native macOS menu bar app for Philips Air+ purifiers (AC0850/800i). Local encrypted CoAP, no cloud."
- Topics: philips, air-purifier, macos, menubar, menu-bar-app, swiftui, coap, swift, iot, reverse-engineering, home-automation, local-control.
- Always pair the name with "for Philips Air+ purifiers" (nominative use) in the README title, release notes and app's About window.
- Cat theming is welcome but light: e.g. a minimal cat-ear/fan glyph for the status item, playful copy in empty states. Never at the expense of clarity in controls or errors.

## Hard requirements
- Device IP/host and port (default 5683) are ALWAYS configurable (CLI flag --host/--port, env PURRIFIER_HOST/PURRIFIER_PORT, app settings). Never hard-code an address.
- Swift Package (swift-tools-version 6.0, strict concurrency), macOS 14+ deployment target, universal binary.
- No third-party CoAP library. Hand-roll a minimal RFC 7252 client on Network.framework (NWConnection, UDP). Allowed deps: swift-argument-parser (CLI only). Crypto via CryptoKit (Insecure.MD5, SHA256) + CommonCrypto (AES-128-CBC, PKCS7) behind a small wrapper.
- Every network request has a timeout; never await indefinitely.

## Repo layout to create
purrifier-philips-air-purifier-macos/
  Package.swift
  Sources/CoAPCore/        Message (ver=1, type CON/NON/ACK/RST, TKL, code, messageID, token, options w/ delta+length encoding incl. 13/14 extended, 0xFF payload marker). Option numbers: Observe=6, UriPath=11, ContentFormat=12, MaxAge=14. Encode/decode as pure functions.
  Sources/PhilipsCrypto/   LegacyPhilipsCipher + Counter (see spec below)
  Sources/AirLink/         actor CoAPTransport (NWConnection, CON retransmit ACK_TIMEOUT=2s×2^n, MAX_RETRANSMIT=4, token/msgID matching, dedupe, ACK incoming CON notifications); actor PurifierSession (sync, status, observe -> AsyncThrowingStream<[String: JSONValue], Error>, send(control), resync)
  Sources/PurifierModel/   KeyGeneration {gen1, gen2, gen3} detection; PurifierState (typed); Capabilities from key presence; Command -> desired JSON
  Sources/purrctl/         CLI: sync | status [--raw|--json] | observe | set <key>=<value>... [-I ints] | set-mode auto|sleep|turbo | power on|off
  Tests/...                Swift Testing (or XCTest)
  Tools/gen_vectors.py     produces Tests/Fixtures/crypto_vectors.json using the Python reference (pip install aioairctrl; or vendor py-air-control's coap_client.py functions)
  Tools/FakePurifier/      NWListener-based simulator of the device side (sync/observe/control, scriptable faults)
  App/                     placeholder README describing the upcoming SwiftUI MenuBarExtra target "Purrifier" (create via XcodeGen project.yml; target depends on the package). Entitlements: App Sandbox + com.apple.security.network.client; Info.plist NSLocalNetworkUsageDescription ("Purrifier talks to your air purifier on your local network.").
  plan.md                  (already present; owner-maintained design doc — do not modify)
  docs/PROTOCOL.md, docs/THREAT_MODEL.md, README.md, CREDITS.md, LICENSE, .github/workflows/ci.yml, .swiftformat, .swiftlint.yml

## Protocol spec (implement exactly; verify against Python reference)
Transport: CoAP over UDP 5683, no DTLS.
1) Sync: POST /sys/dev/sync, payload = 8 random UPPERCASE hex chars (4 random bytes). Response payload (ASCII hex) = counter. Store as String.
2) Status: GET /sys/dev/status with Observe=0 (CON, random 4–8 byte token). Each response/notification payload is an encrypted frame; decrypt, parse JSON, return json["state"]["reported"].
3) Control: POST /sys/dev/control with encrypted frame of JSON {"state":{"desired":{"CommandType":"app","DeviceId":"","EnduserId":"", <k>:<v>...}}}. Response is PLAIN text; success iff exactly {"status":"success"}. On anything else or timeout: resync once and resend once, then throw.

Crypto (SECRET = "JiangPan"):
- deriveKeyIV(counterHex): h = uppercase hex of MD5(ASCII(SECRET + counterHex)) (32 chars); key = ASCII bytes of h[0..<16]; iv = ASCII bytes of h[16..<32]. AES-128-CBC, PKCS7.
- encrypt(json): counter = uppercase hex(Int(counter,16)+1) [increment BEFORE each send; reference does not zero-pad — make width policy explicit and tested]; ctHex = uppercase hex(AES(json UTF8)); digest = uppercase hex(SHA256(ASCII(counter + ctHex))); frame = counter + ctHex + digest.
- decrypt(frame): c = first 8 chars; digest = last 64; ctHex = middle uppercased; verify SHA256(ASCII(c+ctHex)) == digest else throw .digestMismatch; decrypt with deriveKeyIV(c); unpad.
- Counter is owned by the PurifierSession actor; all encrypts serialized.
Note in code comments + PROTOCOL.md: static secret, ASCII-hex key (64-bit effective), unkeyed SHA-256 (no authenticity) — this is obfuscation, not security.

## AC0850 key map (gen3 firmware "AWS_Philips_AIR_Combo@x"; VERIFY on device)
The owner's unit is an AC0850/70. No public status dump exists for the /70 variant; the map below comes from an AC0850/11. The key scheme follows the WifiVersion firmware string, not the suffix, so treat the owner's first `aioairctrl -H <ip> status -J` dump (saved to Tests/Fixtures/ac0850-70/) as the source of truth and update this map from it. Add the /70 to the README's tested-devices list once verified.
Power D03102 (1/0). Mode D0310C: 0=Auto, 17=Sleep, 18=Turbo. Actual fan speed D0310D (read-only). PM2.5 D03221. Allergen index D03120. Preferred index D0312A (0=IAI, 1=PM2.5). Error D03240 (bitfield). Filter remaining/total hours D0540E/D05408. Model D01S05, name D01S03, sw D01S12, WifiVersion, DeviceId, rssi.
Child lock D03103 and display light D0312D/D03105 were ABSENT on an AC0850/11 dump — expose only if present in status.
Generation detection: gen3 if "D03102" present / keys match ^D0[0-9A-F]{4}$; gen2 if "D03-02"/"D01-05" present (power D03-02, mode D03-12, IAI D03-32, PM2.5 D03-33 — value literals UNVERIFIED, mark TODO); gen1 if "pwr"/"om" present. Never send a write before the generation is known.

## Milestone 1 (do this now, end to end)
1. CoAPCore with exhaustive encode/decode tests (golden bytes, option delta edge cases, round-trip).
2. PhilipsCrypto + Tools/gen_vectors.py. Vectors for counters "0000000A", "08ABBEC7", "7FFFFFFF", "FFFFFFFF" and 3 JSON plaintexts; include tampered-digest, bad-padding, short-frame negative cases. Swift tests load Tests/Fixtures/crypto_vectors.json. Document in README how to regenerate.
3. AirLink: sync, one-shot status (register observe, take first notification, then cancel), control with resync-once-and-retry. Timeouts: sync 4s, status 8s, control 6s (configurable).
4. purrctl: `purrctl --host 192.168.x.y status --json`, `purrctl --host … set-mode sleep`, `purrctl --host … set -I D0310C=18`, `--debug` prints hex of each CoAP datagram and the decrypted JSON.
5. PurifierModel: parse fixtures from kongo09/philips-airpurifier-coap issue #139 (AC0850/11 Auto/Sleep/Turbo/Off dumps) into PurifierState; tests for generation detection.
6. FakePurifier: implements the device side with the same crypto; SessionTests run against it (happy path, dropped packet, non-success control → resync, digest mismatch).
Acceptance: `swift test` green; FakePurifier end-to-end passes; README contains a "Verify against Python" section: `pip install aioairctrl`, then `aioairctrl -H <ip> status -J` vs `purrctl --host <ip> status --json` (diff key sets/values), and `aioairctrl -H <ip> --debug status` vs `purrctl --debug` to compare framing.

## Reliability scaffolding (stub now, implement in M2; see plan.md "Reliability strategy")
Session state machine idle→syncing→observing⇄degraded→resyncing with exponential backoff + jitter (1s→60s cap), observe-silence watchdog (max(3×MaxAge, 180s)), fresh NWConnection on resync, NWPathMonitor + wake notifications trigger resync, "pushOnly" flag when observe never answers but sync does. Known firmware bug: devices wedge and may need power-cycling — surface clear UI/CLI errors.

## CI (.github/workflows/ci.yml)
macos-15 runner: swift build, swift test (exclude hardware tests), swiftformat --lint, swiftlint, a Python job that regenerates vectors and fails on diff. Separate tag-triggered release workflow skeleton for Developer ID signing + notarytool (secrets referenced, not required for CI). Homebrew cask skeleton for a personal tap: `brew install --cask <owner>/tap/purrifier`.

## README skeleton
Title "Purrifier — instant local control for Philips Air+ purifiers on macOS" (nominative use), badges, screenshot placeholder, Why (the Air+ app takes 10–15 min to become usable after every launch), Features, Supported devices (AC0850/70 tested; other AC0850 variants and models via generation detection), Install (Homebrew tap, DMG), Usage (menu bar + purrctl CLI), Verify against Python, How it works (link docs/PROTOCOL.md), Security notes (link THREAT_MODEL.md; recommend IoT VLAN, DHCP reservation), Troubleshooting (power-cycle, Local Network permission, firmware updates may disable local control), Credits, Disclaimer ("Not affiliated with or endorsed by Philips or Versuni. Philips is a trademark of Koninklijke Philips N.V."), License.

Work in small commits with conventional-commit messages. Before finishing, list any protocol details you could not verify, where the Python reference disagreed with this spec or plan.md, and any changes you'd suggest making to plan.md.
```

## Sources

- [rgerganov/py-air-control — coap_client.py](https://github.com/rgerganov/py-air-control/blob/master/pyairctrl/coap_client.py)
- [xakcop.com — Controlling a Philips air purifier](https://xakcop.com/post/ctrl-air-purifier/)
- [aioairctrl on PyPI](https://pypi.org/project/aioairctrl/)
- [betaboon/aioairctrl](https://github.com/betaboon/aioairctrl/blob/master/setup.py)
- [kongo09/philips-airpurifier-coap](https://github.com/kongo09/philips-airpurifier-coap) · [const.py](https://github.com/kongo09/philips-airpurifier-coap/blob/master/custom_components/philips_airpurifier_coap/const.py) · issues [#73](https://github.com/kongo09/philips-airpurifier-coap/issues/73), [#139](https://github.com/kongo09/philips-airpurifier-coap/issues/139), [#158](https://github.com/kongo09/philips-airpurifier-coap/issues/158), [#163](https://github.com/kongo09/philips-airpurifier-coap/issues/163), [#363](https://github.com/kongo09/philips-airpurifier-coap/issues/363) · [PR #388](https://github.com/kongo09/philips-airpurifier-coap/pull/388)
- [ruaan-deysel/ha-philips-airpurifier](https://github.com/ruaan-deysel/ha-philips-airpurifier) · [issue #132](https://github.com/ruaan-deysel/ha-philips-airpurifier/issues/132) · [ruaan-deysel/philips-airctrl](https://github.com/ruaan-deysel/philips-airctrl)
- [biemond/com.athom.philipsair](https://github.com/biemond/com.athom.philipsair)
- [FJRG2007/polaris PR #299](https://github.com/FJRG2007/polaris/pull/299)
- [atdr/homebridge-philipsair-platform](https://github.com/atdr/homebridge-philipsair-platform)
- [node-red-contrib-philips-airjs](https://flows.nodered.org/node/node-red-contrib-philips-airjs)
- [tinkerologie/philips-airctrl](https://github.com/tinkerologie/philips-airctrl)
- [Philips Air+ on the App Store](https://apps.apple.com/us/app/philips-air/id1487415423) · [AppBrain listing](https://www.appbrain.com/app/philips-air/com.philips.ph.homecare) · [Air+ privacy notice](https://www.philips.ca/a-w/mobile-privacy-notice/air-purifier.html)
- [stuffrabbit/SwiftCoAP](https://github.com/stuffrabbit/SwiftCoAP) · [FabienFranck/SwiftCoAP](https://github.com/FabienFranck/SwiftCoAP)
- [Apple Developer Forums — NWConnection multicast](https://developer.apple.com/forums/thread/659968)
- [ELVIS wiki — Constrained Application Protocol](https://wiki.elvis.science/index.php?title=Constrained_Application_Protocol)
