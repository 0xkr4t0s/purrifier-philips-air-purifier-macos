# The Philips Air+ local CoAP protocol

This is how Purrifier talks to a Philips Air+ purifier on the local network, written from
the open-source implementations credited in [CREDITS.md](../CREDITS.md) and checked against
them in code. Anything not yet observed on real hardware is marked **unverified** and has a
matching `TODO(verify-…)` in the source.

> **Status.** The byte-level crypto and framing match aioairctrl 0.3.1 exactly (see
> `Tests/Fixtures/crypto_vectors.json`, regenerated in CI). The AC0850/70 key map is still
> **inferred from an AC0850/11**. Purrifier has not yet been run against an AC0850/70; that is
> milestone M0/M1 acceptance work.

## 1. History

Older Philips connected purifiers (around 2016–2019) used **DiComm over HTTP**:
`PUT /di/v1/products/0/security` with a Diffie–Hellman exchange whose small exponent made the
shared key recoverable (see the xakcop.com write-up, January 2019). Newer
units, including the AC0850 "800i", switched to **CoAP over UDP** with the payload
"encryption" described below. The xakcop.com post covers the HTTP protocol only; the CoAP
scheme is documented by code (py-air-control's `coap_client.py`, aioairctrl's
`encryption.py`).

## 2. Transport

| | |
|---|---|
| Protocol | CoAP, RFC 7252, plus Observe (RFC 7641) |
| Transport | UDP, port **5683** by default. Purrifier always lets the user choose host and port |
| Security | **None at the transport layer.** No DTLS |
| Discovery | None advertised (no mDNS seen). Manual IP; DHCP reservation recommended |

Three resources:

| Resource | Method | Request payload | Response payload |
|---|---|---|---|
| `/sys/dev/sync` | POST | 8 random uppercase hex chars | counter, ASCII hex (plain) |
| `/sys/dev/status` | GET + `Observe: 0` | — | encrypted frame (§4), then notifications |
| `/sys/dev/control` | POST | encrypted frame | plain JSON, `{"status":"success"}` on success |

### Message type: CON or NON?

- **aioairctrl 0.3.1 sends every request as NON** (`mtype=NON`) and implements its own
  retries on top.
- py-air-control (CoAPthon) and older aiocoap defaults use CON.
- Purrifier defaults to **CON**, so lost datagrams are retransmitted by the CoAP layer
  (`ACK_TIMEOUT` 2 s × 2ⁿ, `MAX_RETRANSMIT` 4). `purrctl --non` switches to NON.
- **Unverified:** whether the device ACKs CON requests and piggybacks responses.
  `TODO(verify-con-non)`.

### Tokens and message IDs

aiocoap uses an incrementing token with leading zero bytes stripped (1–8 bytes). Purrifier
uses a random 4–8-byte token per exchange, so a late reply can never match the wrong request,
and matches ACK/RST by message ID and responses/notifications by token. Unknown tokens are
answered with RST, which is also how a cancelled observation is ended (RFC 7641 §3.6).

Example datagrams (from `Tests/Fixtures/coap_vectors.json`, encoded by aiocoap):

```
NON POST /sys/dev/sync, payload "0A1B2C3D"
52 02 12 34  5A 01  B3 73 79 73  03 64 65 76  04 73 79 6E 63  FF 30 41 31 42 32 43 33 44
│  │  └ mid  └ tok  └ Uri-Path "sys" (Δ11)  "dev"  "sync"      └ payload marker

CON GET /sys/dev/status, Observe: 0
44 01 BE EF  DE AD BE EF  60  53 73 79 73  03 64 65 76  06 73 74 61 74 75 73
                          └ Observe (Δ6, length 0: the value 0 is zero bytes)
```

## 3. Sync

```
→ POST /sys/dev/sync   "E859B7F3"          (4 random bytes, uppercase hex)
← 2.05 Content         "08ABBEC7"          (the counter, stored as text)
```

None of the references document what the device does with the client's random payload.
The reply is the **client key / counter**: the client increments it
before **every** encrypted send. Purrifier rejects a sync reply that isn't exactly 8 hex
digits and treats it as a sync failure.

### Counter increment: the references disagree

| Reference | Increment | `0000000A` → | `FFFFFFFF` → |
|---|---|---|---|
| py-air-control | `"{:x}".format(n + 1).upper()` | `B` (!) | `100000000` (9 digits) |
| aioairctrl 0.3.1 | `((n + 1) % 2**32).to_bytes(4).hex().upper()` | `0000000B` | `00000000` (wraps) |

The decrypt side always takes the **first 8 characters** as the counter, so py-air-control's
unpadded form produces frames the receiver can't parse whenever the counter has a leading
zero (common: `08ABBEC7` → `8ABBEC8`). aioairctrl fixed this. Purrifier makes the policy
explicit (`CounterWidthPolicy`):

- `fixedWidthWrapping` (default): aioairctrl's behaviour.
- `fixedWidthStrict`: same, but throws at `FFFFFFFF` so the session resyncs instead of wrapping.
- `unpadded`: py-air-control's, for comparison tests only.

**Unverified:** what a device does when the counter wraps. `TODO(verify)` in `PhilipsCounter`.

## 4. Payload "encryption" (obfuscation, not security)

```
SECRET = "JiangPan"

derive(counter):                            counter is ASCII hex text, e.g. "08ABBEC7"
  h   = uppercase hex(MD5(ASCII(SECRET + counter)))         32 ASCII characters
  key = ASCII bytes of h[0..<16]                            16 bytes: the *characters*
  iv  = ASCII bytes of h[16..<32]

encrypt(json):
  counter = increment(counter)                              before every send
  ct      = AES-128-CBC(key, iv, PKCS#7(UTF-8(json)))
  ctHex   = uppercase hex(ct)
  digest  = uppercase hex(SHA-256(ASCII(counter + ctHex)))
  frame   = counter + ctHex + digest                        ASCII, the CoAP payload

decrypt(frame):
  c      = frame[0..<8]                                     the *sender's* counter
  digest = frame[-64...]
  ctHex  = frame[8..<-64].uppercased()
  require digest == uppercase hex(SHA-256(ASCII(c + ctHex)))      else digest mismatch
  json   = unpad(AES-128-CBC-decrypt(derive(c), hexdecode(ctHex)))
```

Worked example (vector `08ABBEC7` / `{"status":"success"}`):

```
MD5("JiangPan08ABBEC7") = 6F75EFBB1AAD25C3 24C6D3B492593A11
key = "6F75EFBB1AAD25C3" (ASCII)   iv = "24C6D3B492593A11" (ASCII)

frame = 08ABBEC7
        DAFBFF4FA2741EFC445C40452ADBFFAB2B06B6709B10CF421B7FA7A1409E4054
        FD8362CD8361E1D2513746B0DAE64069ADDDD7B92EB2A2709C3B0FC7CDF36647
```

### Why this is obfuscation

- **Static, public secret.** `JiangPan` is the same on every device and in every open-source
  client. The counter, the only other key input, travels in cleartext at the start of the
  frame. **Anyone who sees a frame can decrypt it.**
- **ASCII-hex key material.** The 16-byte AES key is 16 hex *characters*: 64 bits of
  effective entropy even if the derivation were secret, which it isn't.
- **Unkeyed digest.** SHA-256 over public data detects corruption but provides **no
  authenticity**. Anyone on the LAN can forge a valid control frame.
- **Deterministic CBC.** The IV is derived from the counter, so equal counter and plaintext give
  equal ciphertext.
- **Plain responses.** Control replies (`{"status":"success"}`) are not encrypted at all.

Purrifier names its implementation `LegacyPhilipsCipher` to make this obvious in code. See
[THREAT_MODEL.md](THREAT_MODEL.md) for the consequences.

### Small differences between the references

| Detail | py-air-control | aioairctrl 0.3.1 | Purrifier |
|---|---|---|---|
| Uppercase the ciphertext before hashing on decrypt | yes | no | yes (accepts lowercase ciphertext) |
| Digest comparison | exact, case-sensitive | exact, case-sensitive | exact, case-sensitive |
| Unpadding | pycryptodome strict | pycryptodome strict | strict, same rules (all pad bytes equal, 1–16) |
| Short frame (< 104 chars) | digest mismatch | digest mismatch | `frameTooShort` (more precise) |

## 5. Status and Observe

```
→ GET /sys/dev/status   Observe: 0
← 2.05 Content          Observe: n   Max-Age: 60   <encrypted frame>
← 2.05 Content          Observe: n+1 …            (notifications on change)
```

The decrypted document is `{"state": {"reported": { … }}}`; only `reported` matters. aioairctrl
treats a missing Max-Age as 60 s. A one-shot status read (`purrctl status`) registers, takes the
first response and cancels; the next notification for that token is answered with RST.

**Push-only firmware (reported, unverified here).** One user reported that on
`AWS_Philips_AIR_Combo@86` (AMF870, and reportedly an AC0850) a plain GET is never answered and
`Observe: 0` is answered only at the next device push, while sync keeps working. M2 adds a
`pushOnly` mode for this. `TODO(M2)`.

## 6. Control

The plaintext is exactly what aioairctrl's `json.dumps` produces (`", "` and `": "`
separators, ASCII escapes), so frames are byte-identical for the same counter:

```json
{"state": {"desired": {"CommandType": "app", "DeviceId": "", "EnduserId": "", "D03102": 1, "D0310C": 17}}}
```

The response is **plain text**. py-air-control requires the exact string
`{"status":"success"}`; aioairctrl parses JSON and checks `status == "success"`. Purrifier accepts
either and treats anything else, or a timeout, as failure: **resync once, resend once, then
report the error**. (aioairctrl retries up to 5 times, resyncing only before the first retry.)

Like the Home Assistant integration, `set-mode` writes power *and* mode together.

## 7. JSON key generations

The key scheme follows the Wi-Fi firmware (`WifiVersion`), **not** the model suffix: two
AC0850/20 units in kongo09/philips-airpurifier-coap#139 used different schemes.

| Generation | Detection | Example keys | Firmware |
|---|---|---|---|
| gen1 | `pwr` or `om` present | `pwr`, `om`, `mode`, `pm25`, `iaql`, `cl`, `uil` | older AC2xxx/AC3xxx |
| gen2 | `D03-02` or `D01-05` present | `D03-02` power, `D03-12` mode, `D03-32` IAI, `D03-33` PM2.5 | `AWS_Philips_AIR@…` |
| gen3 | `D03102` present, or any key matching `^D0[0-9A-F]{4}$` | `D03102` power, `D0310C` mode | `AWS_Philips_AIR_Combo@…` |

Purrifier never writes before it has read a status and detected the generation: writing gen1
keys to a gen3 unit is ignored or refused.

### AC0850 gen3 map (from an AC0850/11, firmware `AWS_Philips_AIR_Combo@1.2`)

| Function | Key | Values | Source / confidence |
|---|---|---|---|
| Power | `D03102` | 1 on, 0 off | #139 dumps; HA integration writes it |
| Mode (write) | `D0310C` | 0 Auto, 17 Sleep, 18 Turbo | #139 dumps; HA `PhilipsAC085011C` |
| Fan speed (read-only) | `D0310D` | Sleep 1, Turbo 18, Auto varies | #139 dumps (medium) |
| Function | `D0310A` | 2 on purifier-only units | medium |
| PM2.5 µg/m³ | `D03221` | integer | high |
| Allergen index (IAI) | `D03120` | integer | high |
| Preferred display index | `D0312A` | 0 IAI, 1 PM2.5 | high |
| Error | `D03240` | bitfield, 0 OK | high |
| Filter remaining / total h | `D0540E` / `D05408` | 4788 / 4800 | high |
| Standby sensors | `D03134` | 1/0 | medium |
| Model / name / software | `D01S05` / `D01S03` / `D01S12` | `AC0850/11`, `Bedroom`, `0.1.3` | high |
| Child lock | `D03103` | **absent on the /11** | exposed only if present |
| Display light | `D0312D` / `D03105` | **absent on the /11** | exposed only if present |

### Gen2 literals (from kongo09's integration, unverified here)

`D03-02`: `"ON"`/`"OFF"`; `D03-12`: `"Auto General"`, `"Sleep"`, `"Turbo"` (AC0850/11 on
`AWS_Philips_AIR`, class `PhilipsAC085011`). The AC0850/20 status in #139 reports
`"D03-02": "ON"` and `"D03-12": "Auto General"`, consistent with this. Purrifier gates gen2 writes
behind `--allow-unverified`. `TODO(verify-gen2)`.

## 8. AC0850/70 findings

> **To be filled in from the owner's unit (milestone M0).** Capture instructions:
> `Tests/Fixtures/ac0850-70/README.md`.

| Field | Value |
|---|---|
| Model (`D01S05` / `D01-05`) | _pending_ |
| `WifiVersion` | _pending_ |
| Software (`D01S12` / `D01-21`) | _pending_ |
| Key generation | _pending_ |
| Mode values match the /11? | _pending_ |
| Child lock / light keys present? | _pending_ |
| CON accepted? | _pending_ |

kongo09's integration already has model entries for both `AC0850/70 AWS_Philips_AIR` (gen2)
and `AC0850/70 AWS_Philips_AIR_Combo` (gen3), but they are copies of the /11 classes, not
evidence from a /70 dump.

## 9. Firmware instability

- kongo09's README: the devices have a bug that makes the connection unstable; a power cycle
  sometimes helps, sometimes only together with a restart of Home Assistant.
- HA issue #363: a control call without a timeout hung for ~1 h 46 min. Purrifier puts a
  deadline on every request and reports "power-cycle the purifier" after a resync fails.
- HA PR #388 rebuilds the client after 3 × max-age (180 s) of silence; Purrifier's M2 watchdog
  uses `max(3 × Max-Age, 180 s)`.
- Newer firmware may disable local CoAP entirely (ruaan-deysel's README). Don't apply firmware
  updates blindly once local control works.

## 10. Reproducing this

```sh
make vectors          # regenerate the fixtures from aioairctrl / aiocoap
swift test            # Swift checks itself against them
purrctl --host <ip> --debug status           # every datagram in hex + decrypted JSON
aioairctrl -H <ip> --debug status            # the Python reference, for comparison
```
