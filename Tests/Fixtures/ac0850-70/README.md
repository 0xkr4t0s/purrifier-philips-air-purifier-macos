# AC0850/70 status dumps (to be captured)

No public status dump exists for the AC0850/70. The key map in `KeyMap.gen3` comes from an
AC0850/11, and the key scheme follows the Wi-Fi firmware (`WifiVersion`), not the model
suffix. kongo09's integration lists both `AC0850/70 AWS_Philips_AIR` (gen2) and
`AC0850/70 AWS_Philips_AIR_Combo` (gen3) variants, so this unit could be either.
**These dumps decide which map is correct.**

Capture one file per state with the Python reference (milestone M0):

```sh
python3 -m venv .venv && .venv/bin/pip install -r Tools/requirements.txt
# Set the purifier to each state with its buttons, then:
.venv/bin/aioairctrl -H <ip> status -J | python3 -m json.tool > Tests/Fixtures/ac0850-70/auto.json
.venv/bin/aioairctrl -H <ip> status -J | python3 -m json.tool > Tests/Fixtures/ac0850-70/sleep.json
.venv/bin/aioairctrl -H <ip> status -J | python3 -m json.tool > Tests/Fixtures/ac0850-70/turbo.json
.venv/bin/aioairctrl -H <ip> status -J | python3 -m json.tool > Tests/Fixtures/ac0850-70/off.json
```

Then record `D01S05` (or `D01-05`), `WifiVersion` and `D01S12` in `docs/PROTOCOL.md` and the
README's supported-devices table. `PurifierModelTests` picks up every `*.json` file here
automatically and checks that it parses and has a known key generation.

Before committing, consider replacing `DeviceId` and `ProductId` with placeholder values if
you don't want your unit's identifiers public.
