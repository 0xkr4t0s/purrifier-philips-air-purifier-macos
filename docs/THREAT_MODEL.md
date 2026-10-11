# Threat model

Purrifier controls a Philips Air+ purifier over a protocol with **no real security** (see
[PROTOCOL.md §4](PROTOCOL.md#4-payload-encryption-obfuscation-not-security)). Purrifier can't
fix the device; this document covers what an attacker on the network can do anyway, what
Purrifier does to avoid making things worse, and what users can do.

## Assets

| Asset | Why it matters |
|---|---|
| Control of the purifier | Power, mode. Low physical impact, but it's someone's home |
| Status data | PM2.5/allergen readings over time, room name (`D01S03`), `DeviceId`, RSSI: enough to infer presence, routines and room layout |
| The user's Mac | Purrifier must not become a way into it |
| The device's availability | Fragile firmware: a wedged unit needs a power cycle |

## Trust boundaries and attacker

- **In scope:** an attacker on the same LAN/Wi-Fi (guest network without isolation, a
  compromised IoT device, a malicious app on another computer), and a passive sniffer of the
  2.4 GHz network who has the Wi-Fi key.
- **Out of scope:** the Philips/Versuni cloud and Air+ app, firmware update paths, physical
  access, and the user's Mac already being compromised.

## STRIDE-lite

| Threat | Against | How | Severity | Mitigation |
|---|---|---|---|---|
| **Spoofing** | Device | Any LAN host can sync and send commands. No pairing, no user binding, no MAC | Medium (local) | None possible client-side. Isolate the device (VLAN) |
| **Spoofing** | Purrifier | A rogue host answers as the purifier (ARP spoofing, DHCP change) and feeds fake status | Low | Bounded parsing; status is display-only. M2+: pin `DeviceId` after first contact and warn on change |
| **Tampering** | Device commands | Unkeyed SHA-256 means forged or modified frames verify | Medium | None in protocol. Isolation |
| **Repudiation** | — | Device keeps no command log | Info | — |
| **Information disclosure** | Status | Static secret + cleartext counter: passive sniffing decrypts everything | Medium (privacy) | Isolation. Purrifier never logs decrypted frames unless `--debug` is passed |
| **Denial of service** | Device | UDP + fragile firmware: floods of syncs or malformed frames may wedge it until power-cycled | Medium | Purrifier: bounded retries, backoff (M2), one resync per failure. Users: isolation |
| **Denial of service** | Purrifier | Hostile replies: oversized JSON, endless notifications, malformed CoAP | Low | 64 KiB JSON cap, strict decoders that throw rather than trap, deadlines on every request, bounded buffers |
| **Amplification** | Third parties | CoAP is a known reflection vector | Low (LAN-only) | Block the device's WAN access; don't port-forward 5683 |
| **Elevation of privilege** | User's Mac | A bug in parsing hostile input | Low | Memory-safe Swift; sandbox; no shelling out; no dynamic code |

## What Purrifier does

- **App Sandbox** with one entitlement, `com.apple.security.network.client`. No incoming
  connections, no file access outside the container. **Hardened Runtime** on.
- **No cloud, no telemetry.** All traffic is between the Mac and the configured host:port.
- **Every network request has a deadline** (sync 4 s, status 8 s, control 6 s, all
  configurable). Nothing waits forever, so a hostile or wedged peer can't hang the app.
- **Bounded, strict parsing.** CoAP decoding validates every length and throws on malformed
  input (fuzzed in tests). JSON from the device is rejected above 64 KiB. Crypto input must be
  ASCII and well-formed before any decryption happens.
- **Honest naming.** The cipher wrapper is `LegacyPhilipsCipher`; docs and code comments say
  it's obfuscation.
- **Writes only after reading.** The key generation must be known before any control frame is
  sent; unverified write mappings need an explicit opt-in.
- **Logging.** Decrypted frames (room name, air quality, `DeviceId`) are printed only with
  `--debug`. The app's planned debug-log export redacts frames unless the user opts in.
- **Address is configuration.** No hard-coded hosts; no scanning by default. (A subnet probe is
  planned for M4 as an explicit user action.)

## What users should do

1. **Put IoT devices on their own VLAN or SSID** with client isolation, and allow only the
   Mac (or Home Assistant) to reach UDP 5683 on the purifier.
2. **Block the purifier's internet access** if you don't need the Air+ app or cloud features.
   (Initial Wi-Fi onboarding still needs the Air+ app.)
3. **Give the purifier a DHCP reservation** so its address doesn't change.
4. **Don't port-forward** 5683 or expose the device to the internet.
5. **Be cautious with firmware updates** once local control works: newer firmware may disable
   it.

## Testing ethics

The weaknesses above are already public in several open-source projects, so documenting them
needs no embargo. Robustness and DoS behaviour should be tested **only on your own unit**.
This project does not publish flooding or DoS tooling. The `FakePurifier` simulator exists so
fault handling can be tested without touching real devices.

## Reporting

Found a security issue in Purrifier itself (not the device protocol)? Please open a private
security advisory on the GitHub repository rather than a public issue.
