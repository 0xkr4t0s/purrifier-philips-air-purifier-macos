# Convenience targets. Everything also works with plain `swift` commands.
SWIFT ?= swift
PYTHON ?= python3
VENV := .venv

.PHONY: build test lint format vectors check-vectors hil release clean

build:
	$(SWIFT) build

test:
	$(SWIFT) test

lint:
	swiftformat --lint .
	swiftlint --strict

format:
	swiftformat .

$(VENV)/bin/python: Tools/requirements.txt
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install -q -r Tools/requirements.txt
	touch $@

# Regenerate Tests/Fixtures/{crypto,coap}_vectors.json from aioairctrl/aiocoap.
vectors: $(VENV)/bin/python
	$(VENV)/bin/python Tools/gen_vectors.py

check-vectors: $(VENV)/bin/python
	$(VENV)/bin/python Tools/gen_vectors.py --check

# Hardware-in-the-loop tests against your own purifier: make hil IP=192.168.1.50 [PORT=5683]
hil:
	@test -n "$(IP)" || (echo "usage: make hil IP=<purifier ip> [PORT=5683]" && exit 2)
	PURRIFIER_HIL_HOST=$(IP) PURRIFIER_HIL_PORT=$(or $(PORT),5683) $(SWIFT) test --filter HardwareTests

# Universal (arm64 + x86_64) release build of the CLI.
release:
	$(SWIFT) build -c release --arch arm64 --arch x86_64 --product purrctl
	@echo "built: $$($(SWIFT) build -c release --arch arm64 --arch x86_64 --show-bin-path)/purrctl"

clean:
	$(SWIFT) package clean
