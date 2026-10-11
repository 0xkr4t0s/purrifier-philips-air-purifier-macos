# Purrifier — instant local control for Philips Air+ purifiers on macOS

[![CI](https://github.com/0xKr4t0s/purrifier-philips-air-purifier-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/0xKr4t0s/purrifier-philips-air-purifier-macos/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**Purrifier** is a native macOS menu bar app and command-line tool (`purrctl`) for **Philips
Air+ air purifiers** such as the **AC0850 "800i"**. It talks to the purifier directly over its
**local encrypted CoAP** protocol: no cloud, no account, no Python at runtime.

<!-- Screenshot placeholder: menu bar panel (milestone M3) -->
> 📸 _Screenshot coming with the menu bar app (milestone M3)._

## Why

The official Air+ app can take **10–15 minutes to become usable after every launch** while it
goes through the cloud. The purifier is a few metres away on your own network and answers
local requests in milliseconds. Purrifier asks it directly.

The open-source integrations that already speak this protocol (Home Assistant, Homebridge)
are known to hang for hours when the purifier's firmware misbehaves. Purrifier treats
reliability as its main feature: every request has a deadline, failures trigger one clean
resync, and errors tell you what to do.

## Features

**Available now (milestone M1, command line):**

- `purrctl status`: power, mode, PM2.5, allergen index, filter life, firmware, in about a second
- `purrctl set-mode auto|sleep|turbo`, `purrctl power on|off`, raw `purrctl set KEY=VALUE`
- `purrctl observe`: live status updates
- `--json` output that diffs cleanly against the Python reference (`aioairctrl status -J`)
- `--debug`: every CoAP datagram in hex plus the decrypted JSON
- Generation detection: reads the device's key scheme before it ever writes
- Timeouts on every request; one resync-and-retry on failure; actionable error messages
- A device simulator (`fake-purifier`) for testing without hardware

**Planned:** menu bar app with an air-quality-tinted status item (M3); self-healing
long-lived sessions, push-only firmware support and wake/network-change handling (M2);
notifications and multiple devices (M4). See [plan.md](plan.md).

## Supported devices

| Device | Firmware (`WifiVersion`) | Status |
|---|---|---|
| **AC0850/70** (800i, Australia) | _to be recorded_ | 🎯 Target device. **Verification on hardware pending** |
| AC0850/11, /20, /31, /41, /81 | `AWS_Philips_AIR_Combo@…` (gen3 keys) | Expected to work: key map from public AC0850/11 dumps |
| AC0850 on `AWS_Philips_AIR@…` | gen2 keys (`D03-02`) | Status works; writes need `--allow-unverified` |
| Older Air+ models | gen1 keys (`pwr`, `om`) | Status only |

The key scheme follows the Wi-Fi firmware rather than the model suffix, so Purrifier
**detects it from the status keys** instead of trusting the model name. If your device isn't
listed, `purrctl --host <ip> status --raw` output in an issue helps a lot (consider replacing
`DeviceId`/`ProductId` first).

## Install

- **Homebrew (personal tap):** `brew install --cask 0xkr4t0s/tap/purrifier` _(after the first release)_
- **DMG:** download from [Releases](https://github.com/0xKr4t0s/purrifier-philips-air-purifier-macos/releases) _(signed and notarized; after the first release)_
- **From source** (now):

  ```sh
  git clone https://github.com/0xKr4t0s/purrifier-philips-air-purifier-macos.git
  cd purrifier-philips-air-purifier-macos
  swift build -c release --product purrctl
  cp .build/release/purrctl /usr/local/bin/   # or anywhere on your PATH
  ```

Requires macOS 14 Sonoma or later and Xcode 16 (Swift 6) to build.

## Usage

### Menu bar app

Coming in milestone M3; see [App/README.md](App/README.md).

### `purrctl`

```sh
purrctl --host 192.168.1.50 status            # human-readable summary
purrctl --host 192.168.1.50 status --json     # state.reported as JSON
purrctl --host 192.168.1.50 status --raw      # decrypted document, exactly as sent
purrctl --host 192.168.1.50 set-mode sleep    # auto | sleep | turbo (switches on too)
purrctl --host 192.168.1.50 power off
purrctl --host 192.168.1.50 set -I D0310C=18  # raw keys; -I sends integers (like aioairctrl)
purrctl --host 192.168.1.50 observe           # stream updates; Ctrl-C to stop
purrctl --host 192.168.1.50 --debug status    # hex of every datagram + decrypted JSON
```

```
$ purrctl --host 192.168.1.50 status
Bedroom (AC0850/11)
gen3 (D03102), firmware AWS_Philips_AIR_Combo@1.2, software 0.1.3
Power     on
Mode      auto (fan speed 1)
PM2.5     3 µg/m³
Allergen  1 (IAI)
Display   PM2.5
Filter    4788 / 4800 h (99%)
Error     none
Wi-Fi     -70 dBm
```

The address is never hard-coded. Set it once with environment variables:

```sh
export PURRIFIER_HOST=192.168.1.50   # IP or hostname
export PURRIFIER_PORT=5683           # optional; 5683 is the default
purrctl status
```

| Option | Meaning |
|---|---|
| `-H, --host` / `PURRIFIER_HOST` | Purifier address |
| `-P, --port` / `PURRIFIER_PORT` | CoAP port (default 5683) |
| `-D, --debug` | Datagrams in hex and decrypted JSON, on stderr |
| `--non` | Send NON requests like aioairctrl, instead of CON with retransmission |
| `--sync-timeout`, `--status-timeout`, `--control-timeout` | Seconds (defaults 4, 8, 6) |
| `--allow-unverified` | Allow writes whose values aren't verified on hardware (gen1/gen2) |

Exit status is 0 on success and 1 on any device or network error (the message on stderr says
what to try).

## Verify against Python

[aioairctrl](https://pypi.org/project/aioairctrl/) is the reference implementation used by the
Home Assistant integration. Purrifier should agree with it on your device:

```sh
python3 -m venv .venv && .venv/bin/pip install aioairctrl

# 1. Status: compare key sets and values (run these one after the other, not in parallel).
.venv/bin/aioairctrl -H <ip> status -J | jq -S . > /tmp/aioairctrl.json
purrctl --host <ip> status --json        | jq -S . > /tmp/purrctl.json
diff <(jq 'keys' /tmp/aioairctrl.json) <(jq 'keys' /tmp/purrctl.json) && echo "same keys"
# Values: ignore fields that change by themselves between two reads.
diff <(jq 'del(.Runtime, .rssi, .free_memory)' /tmp/aioairctrl.json) \
     <(jq 'del(.Runtime, .rssi, .free_memory)' /tmp/purrctl.json) && echo "same values"

# 2. Framing: compare the datagrams and decrypted JSON.
.venv/bin/aioairctrl -H <ip> --debug status
purrctl --host <ip> --debug --non status   # --non matches aioairctrl's message type
```

Expected differences in the `--debug` traces: message IDs, tokens (aiocoap uses 1–2-byte
incrementing tokens, Purrifier random 4–8 bytes), counters and nonces. With the same counter
and plaintext, the encrypted frames are **byte-identical**; the test suite checks this
against vectors generated by aioairctrl itself (see [Development](#development)).

## How it works

`POST /sys/dev/sync` returns a counter; status and control payloads are AES-128-CBC with a key
and IV derived from `MD5("JiangPan" + counter)`, framed as `counter ‖ ciphertext ‖ SHA-256`.
The full byte-level description, including where the reference implementations disagree,
is in **[docs/PROTOCOL.md](docs/PROTOCOL.md)**.

```
Sources/
  CoAPCore/       RFC 7252 message codec (pure value types)
  PhilipsCrypto/  LegacyPhilipsCipher, counter policies (CryptoKit + CommonCrypto)
  PurifierModel/  key-generation detection, typed state, commands
  AirLink/        CoAPTransport + PurifierSession actors (Network.framework)
  purrctl/        the CLI (swift-argument-parser, the only dependency)
Tools/
  FakePurifier/   UDP device simulator with scriptable faults
  gen_vectors.py  Python oracle for the crypto and CoAP test vectors
App/              SwiftUI MenuBarExtra app (XcodeGen), milestone M3
```

## Security notes

The purifier's "encryption" uses a public static secret and an unkeyed digest. **Anyone on
your network can read its status and control it, with or without Purrifier.** See
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md). In short:

- Put the purifier on an **IoT VLAN or isolated SSID**, reachable only from your Mac.
- Give it a **DHCP reservation** so its address stays put.
- Block its internet access if you don't use the cloud features; never port-forward 5683.

Purrifier itself runs sandboxed with only the outgoing-network entitlement, sends nothing
to the cloud, and never logs decrypted data unless you pass `--debug`.

## Troubleshooting

| Symptom | Try |
|---|---|
| `No reply from the purifier … (sync)` | Check the IP (your router's DHCP list). If it's right, **power-cycle the purifier** (unplug 10 s). Its firmware is known to wedge. |
| Works once, then times out | Same firmware bug: power-cycle. Then report your `WifiVersion` in an issue. |
| `Can't reach …` on macOS 15+ | **Local Network permission**: System Settings → Privacy & Security → Local Network. `purrctl` is attributed to your terminal app. |
| Status works, commands are refused | Run `purrctl --debug …` and check the generation line in `status`. Gen2 devices need `--allow-unverified`. |
| CON requests time out but aioairctrl works | Try `--non`, and please open an issue (see `TODO(verify-con-non)`). |
| Stopped working after a firmware update | Some newer firmware may disable local control. Avoid updates once things work. |

## Development

```sh
swift build && swift test                 # all tests; hardware tests skip themselves
make lint                                 # swiftformat --lint + swiftlint --strict
swift run fake-purifier --port 5683       # simulator; then: purrctl --host 127.0.0.1 status
make hil IP=192.168.1.50                  # hardware-in-the-loop tests on YOUR unit (changes its mode)
```

**Regenerating the test vectors.** The crypto and CoAP fixtures in `Tests/Fixtures/` are
produced by the Python reference implementations and must never be edited by hand:

```sh
make vectors          # creates .venv, installs Tools/requirements.txt (pinned aioairctrl/aiocoap),
                      # runs Tools/gen_vectors.py
make check-vectors    # what CI runs: fails if the committed fixtures are stale
```

To record your own device's status for the test suite, see
[Tests/Fixtures/ac0850-70/README.md](Tests/Fixtures/ac0850-70/README.md).

## Credits

Purrifier is a clean-room Swift implementation built on protocol knowledge from
rgerganov/py-air-control, betaboon & kongo09/aioairctrl, Denaun & kongo09/philips-airpurifier-coap,
ruaan-deysel/ha-philips-airpurifier and biemond/com.athom.philipsair. Details in
[CREDITS.md](CREDITS.md).

## Disclaimer

Not affiliated with or endorsed by Philips or Versuni. Philips is a trademark of Koninklijke
Philips N.V. "Philips" is used here only to say which devices this software works with.
Use at your own risk; controlling your device with unofficial software may affect your
warranty.

## License

[MIT](LICENSE)
