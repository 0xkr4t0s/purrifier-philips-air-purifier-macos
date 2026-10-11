#!/usr/bin/env python3
"""Generate the test vectors the Swift test suite checks itself against.

The Python implementations are the oracle: if Swift and Python disagree, Swift is wrong
(or the disagreement is documented in docs/PROTOCOL.md).

  * Tests/Fixtures/crypto_vectors.json  — aioairctrl's EncryptionContext (frames, key/IV
    derivation, counter increments, decrypt failures) plus py-air-control's unpadded
    counter increment for comparison.
  * Tests/Fixtures/coap_vectors.json    — CoAP datagrams encoded by aiocoap, the library
    aioairctrl sends with, for byte-for-byte codec tests.

Everything is deterministic: no randomness, no timestamps. CI regenerates both files and
fails if `git diff` shows a change.

Usage:
    python3 -m venv .venv && .venv/bin/pip install -r Tools/requirements.txt
    .venv/bin/python Tools/gen_vectors.py            # rewrite the fixtures
    .venv/bin/python Tools/gen_vectors.py --check    # exit 1 if they are out of date
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import warnings
from importlib.metadata import version
from pathlib import Path

from aioairctrl.coap.encryption import DigestMismatchException, EncryptionContext
from aiocoap import CON, NON, ACK, RST, Message
from aiocoap.numbers.codes import Code
from aiocoap.numbers.optionnumbers import OptionNumber
from aiocoap.optiontypes import OpaqueOption
from Cryptodome.Cipher import AES

FIXTURES = Path(__file__).resolve().parent.parent / "Tests" / "Fixtures"

COUNTERS = ["0000000A", "08ABBEC7", "7FFFFFFF", "FFFFFFFF"]

# Three plaintexts: a status document (multi-block), a control command exactly as
# aioairctrl serialises it (json.dumps default separators), and a control *response*.
PLAINTEXTS = [
    json.dumps({"state": {"reported": {"D03102": 1, "D0310C": 17, "D03221": 3, "D01S05": "AC0850/11",
                                       "D01S03": "Bedroom", "WifiVersion": "AWS_Philips_AIR_Combo@1.2"}}}),
    json.dumps({"state": {"desired": {"CommandType": "app", "DeviceId": "", "EnduserId": "", "D0310C": 18}}}),
    '{"status":"success"}',
]


# --- py-air-control reference (MIT, rgerganov/py-air-control, pyairctrl/coap_client.py) ---
# Reproduced for comparison only: the counter increment without zero padding.
def pyairctrl_increment(client_key: str) -> str:
    return "{:x}".format(int(client_key, 16) + 1).upper()


def aioairctrl_increment(client_key: str) -> str:
    ctx = EncryptionContext()
    ctx.set_client_key(client_key)
    return ctx._increment_client_key()


def predecessor(counter: str) -> str:
    """The counter that aioairctrl's encrypt() increments *to* `counter`."""
    return ((int(counter, 16) - 1) % 0x100000000).to_bytes(4, "big").hex().upper()


def frame_for(counter: str, plaintext: str) -> str:
    """Build a frame for `counter` through aioairctrl's public encrypt() path."""
    ctx = EncryptionContext()
    ctx.set_client_key(predecessor(counter))
    frame = ctx.encrypt(plaintext)
    assert frame.startswith(counter), (frame[:8], counter)
    assert ctx.decrypt(frame) == plaintext
    return frame


def raw_frame(counter: str, ciphertext: bytes) -> str:
    """A frame around arbitrary ciphertext, with a correct digest."""
    ct_hex = ciphertext.hex().upper()
    digest = hashlib.sha256((counter + ct_hex).encode()).hexdigest().upper()
    return counter + ct_hex + digest


def reference_decrypt_error(frame: str) -> str | None:
    try:
        EncryptionContext().decrypt(frame)
    except DigestMismatchException:
        return "DigestMismatchException"
    except ValueError as exc:  # unpad() and bytes.fromhex() both raise ValueError
        return f"ValueError: {exc}"
    return None


def key_derivation(counter: str) -> dict:
    md5_hex = hashlib.md5(("JiangPan" + counter).encode()).hexdigest().upper()
    # Cross-check against aioairctrl's own cipher construction.
    cipher = EncryptionContext()._create_cipher(counter)
    assert cipher.iv == md5_hex[16:].encode()
    return {"counter": counter, "md5Hex": md5_hex, "keyAscii": md5_hex[:16], "ivAscii": md5_hex[16:]}


def crypto_vectors() -> dict:
    frames = []
    for counter in COUNTERS:
        for plaintext in PLAINTEXTS:
            frame = frame_for(counter, plaintext)
            frames.append({
                "counter": counter,
                "plaintext": plaintext,
                "ciphertextHex": frame[8:-64],
                "digest": frame[-64:],
                "frame": frame,
            })

    encrypt = []
    for counter in COUNTERS:
        ctx = EncryptionContext()
        ctx.set_client_key(counter)
        frame = ctx.encrypt(PLAINTEXTS[1])
        encrypt.append({"counterBefore": counter, "counterUsed": frame[:8], "plaintext": PLAINTEXTS[1], "frame": frame})

    increments = [
        {"before": c, "fixedWidthWrapping": aioairctrl_increment(c), "unpadded": pyairctrl_increment(c)}
        for c in COUNTERS + ["00000000", "0000000F", "FFFFFFFE"]
    ]

    base = frame_for("08ABBEC7", PLAINTEXTS[0])
    flip = {"0": "1", "1": "0"}

    def flip_char(text: str, index: int) -> str:
        char = text[index]
        return text[:index] + flip.get(char, "0") + text[index + 1:]

    key = key_derivation("08ABBEC7")
    unpadded_block = AES.new(key["keyAscii"].encode(), AES.MODE_CBC, iv=key["ivAscii"].encode()).encrypt(
        b"0123456789ABCDE\x00"  # last byte 0x00 is never valid PKCS#7
    )
    nine_digit = pyairctrl_increment("FFFFFFFF")  # "100000000"
    nine_cipher = AES.new(
        key_derivation(nine_digit)["keyAscii"].encode(), AES.MODE_CBC, iv=key_derivation(nine_digit)["ivAscii"].encode()
    ).encrypt(b'{"status":"success"}\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c')
    wrong_counter = raw_frame("08ABBEC8", bytes.fromhex(base[8:-64]))

    negative = [
        {"name": "tamperedDigest", "frame": flip_char(base, len(base) - 1), "error": "digestMismatch"},
        {"name": "tamperedCiphertext", "frame": flip_char(base, 20), "error": "digestMismatch"},
        {"name": "tamperedCounter", "frame": flip_char(base, 3), "error": "digestMismatch"},
        {"name": "lowercaseDigest", "frame": base[:-64] + base[-64:].lower(), "error": "digestMismatch"},
        {"name": "badPadding", "frame": raw_frame("08ABBEC7", unpadded_block), "error": "badPadding"},
        # Valid digest for a different counter: decrypts with the wrong key, so padding fails.
        {"name": "wrongCounterValidDigest", "frame": wrong_counter, "error": "badPadding"},
        {"name": "shortFrame", "frame": base[:100], "error": "frameTooShort"},
        {"name": "emptyFrame", "frame": "", "error": "frameTooShort"},
        # A py-air-control style 9-digit counter. The digest still matches (same concatenation)
        # but the ciphertext gains a leading digit and becomes odd-length.
        {"name": "nineDigitCounter", "frame": raw_frame(nine_digit, nine_cipher), "error": "malformedFrame"},
        {"name": "partialBlock", "frame": raw_frame("08ABBEC7", unpadded_block + unpadded_block[:8]), "error": "malformedFrame"},
    ]
    for case in negative:
        case["referenceError"] = reference_decrypt_error(case["frame"])

    return {
        "generator": "Tools/gen_vectors.py",
        "reference": f"aioairctrl {version('aioairctrl')} (aioairctrl.coap.encryption.EncryptionContext)",
        "secret": "JiangPan",
        "keyDerivation": [key_derivation(c) for c in COUNTERS + [nine_digit]],
        "frames": frames,
        "encrypt": encrypt,
        "increments": increments,
        "negative": negative,
    }


# --- CoAP golden bytes from aiocoap ---

def coap_message(name: str, *, mtype, code, mid: int, token: bytes = b"", path: str | None = None,
                 payload: bytes = b"", observe: int | None = None, max_age: int | None = None,
                 content_format: int | None = None, extra: list[tuple[int, bytes]] | None = None) -> dict:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        msg = Message(_mtype=mtype, _mid=mid, code=code, _token=token, payload=payload)
    if path is not None:
        msg.opt.uri_path = tuple(segment for segment in path.split("/") if segment)
    if observe is not None:
        msg.opt.observe = observe
    if max_age is not None:
        msg.opt.max_age = max_age
    if content_format is not None:
        msg.opt.content_format = content_format
    for number, value in extra or []:
        msg.opt.add_option(OpaqueOption(OptionNumber(number), value))
    encoded = msg.encode()
    options = [{"number": int(opt.number), "valueHex": opt.encode().hex().upper()} for opt in msg.opt.option_list()]
    return {
        "name": name,
        "type": {CON: "CON", NON: "NON", ACK: "ACK", RST: "RST"}[mtype],
        "code": int(code),
        "messageID": mid,
        "tokenHex": token.hex().upper(),
        "options": options,
        "payloadHex": payload.hex().upper(),
        "bytesHex": encoded.hex().upper(),
    }


def coap_vectors() -> dict:
    sync_payload = b"0A1B2C3D"
    messages = [
        coap_message("syncRequestNON", mtype=NON, code=Code.POST, mid=0x1234, token=b"\x5a\x01",
                     path="/sys/dev/sync", payload=sync_payload),
        coap_message("statusObserveCON", mtype=CON, code=Code.GET, mid=0xBEEF, token=bytes.fromhex("DEADBEEF"),
                     path="/sys/dev/status", observe=0),
        coap_message("statusObserveNON", mtype=NON, code=Code.GET, mid=0x0001, token=bytes.fromhex("01020304050607"),
                     path="/sys/dev/status", observe=0),
        coap_message("controlCON", mtype=CON, code=Code.POST, mid=0xFFFF, token=bytes.fromhex("0011223344556677"),
                     path="/sys/dev/control", payload=b"08ABBEC8" + b"A" * 32 + b"B" * 64),
        coap_message("syncResponseACK", mtype=ACK, code=Code.CONTENT, mid=0x1234, token=b"\x5a\x01",
                     payload=b"08ABBEC7"),
        coap_message("notificationCON", mtype=CON, code=Code.CONTENT, mid=0x7001, token=bytes.fromhex("DEADBEEF"),
                     observe=0x00ABCD, max_age=60, content_format=50, payload=b"{}"),
        coap_message("notificationObserve3Bytes", mtype=NON, code=Code.CONTENT, mid=0x7002,
                     token=bytes.fromhex("DEADBEEF"), observe=0xFFFFFF, payload=b"x"),
        coap_message("controlResponseChanged", mtype=ACK, code=Code.CHANGED, mid=0xFFFF,
                     token=bytes.fromhex("0011223344556677"), payload=b'{"status":"success"}'),
        coap_message("emptyACK", mtype=ACK, code=Code.EMPTY, mid=0x7001),
        coap_message("emptyRST", mtype=RST, code=Code.EMPTY, mid=0x7002),
        coap_message("emptyPingCON", mtype=CON, code=Code.EMPTY, mid=0x0042),
        coap_message("notFound", mtype=ACK, code=Code.NOT_FOUND, mid=0x0101, token=b"\x01"),
        # Option delta / length extension edge cases (RFC 7252 §3.1).
        coap_message("deltaExactly12", mtype=CON, code=Code.GET, mid=1, extra=[(12, b"")]),
        coap_message("deltaExactly13", mtype=CON, code=Code.GET, mid=1, extra=[(13, b"\x01")]),
        coap_message("delta268", mtype=CON, code=Code.GET, mid=1, extra=[(268, b"")]),
        coap_message("delta269", mtype=CON, code=Code.GET, mid=1, extra=[(269, b"")]),
        coap_message("delta270", mtype=CON, code=Code.GET, mid=1, extra=[(270, b"")]),
        coap_message("delta65000", mtype=CON, code=Code.GET, mid=1, extra=[(65000, b"\xaa")]),
        coap_message("length12", mtype=CON, code=Code.GET, mid=1, extra=[(4, b"\x11" * 12)]),
        coap_message("length13", mtype=CON, code=Code.GET, mid=1, extra=[(4, b"\x22" * 13)]),
        coap_message("length268", mtype=NON, code=Code.POST, mid=1, extra=[(2048, b"\x33" * 268)]),
        coap_message("length269", mtype=NON, code=Code.POST, mid=1, extra=[(2048, b"\x44" * 269)]),
        coap_message("length300", mtype=NON, code=Code.POST, mid=1, extra=[(2048, b"\x55" * 300)]),
        coap_message("repeatedAndMixed", mtype=CON, code=Code.GET, mid=0x0A0B, token=b"\x07",
                     path="/a/bb/ccc", observe=1, max_age=0, extra=[(60, b"\x01\x00"), (300, b"z")]),
    ]
    return {
        "generator": "Tools/gen_vectors.py",
        "reference": f"aiocoap {version('aiocoap')} (Message.encode)",
        "messages": messages,
    }


def render(data: dict) -> str:
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if the committed fixtures are out of date")
    args = parser.parse_args()

    outputs = {
        FIXTURES / "crypto_vectors.json": render(crypto_vectors()),
        FIXTURES / "coap_vectors.json": render(coap_vectors()),
    }
    stale = []
    for path, text in outputs.items():
        current = path.read_text() if path.exists() else None
        if current != text:
            stale.append(path)
            if not args.check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
    if args.check and stale:
        for path in stale:
            print(f"out of date: {path.relative_to(FIXTURES.parent.parent)}", file=sys.stderr)
        return 1
    for path in outputs:
        state = "updated" if path in stale else "unchanged"
        print(f"{state}: {path.relative_to(FIXTURES.parent.parent)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
