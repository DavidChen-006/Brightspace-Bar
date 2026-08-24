# BrightspaceBar — top-level entry points.
#
#   make setup   check prerequisites, install session-capture's npm deps
#   make start   THE one command: build the app, ensure credentials (prompting
#                once if needed), launch the menu bar, run the headless login
#   make login   one-time interactive Chromium login (captures the session)
#   make run     build & run the menu-bar app (delegates to BrightspaceBar/)
#   make test    run the Swift test suite   (delegates to BrightspaceBar/)

.PHONY: setup start login run test

start:
	$(MAKE) -C BrightspaceBar build
	cd session-capture && npm run start

setup:
	@test "$$(uname)" = Darwin || { echo "error: BrightspaceBar is a macOS menu-bar app — macOS required"; exit 1; }
	@xcode-select -p >/dev/null 2>&1 || { echo "error: Xcode Command Line Tools missing — run: xcode-select --install"; exit 1; }
	@swift --version 2>/dev/null | awk '/Swift version/ { split($$4, v, "."); if (v[1] < 6 || (v[1] == 6 && v[2] < 2)) { print "error: swift >= 6.2 required, found " $$4; exit 1 } }' || { echo "error: swift not found or too old (need >= 6.2)"; exit 1; }
	@node --version >/dev/null 2>&1 || { echo "error: node not found — need node >= 20 (try: brew install node)"; exit 1; }
	@node -e 'process.exit(parseInt(process.versions.node) >= 20 ? 0 : 1)' || { echo "error: node >= 20 required, found $$(node --version)"; exit 1; }
	cd session-capture && npm install
	@echo
	@echo "Setup complete. Next: \`make start\` — the one command (builds, prompts for credentials once, launches the menu bar, logs in)."

login:
	cd session-capture && npm run capture

run:
	$(MAKE) -C BrightspaceBar run

test:
	$(MAKE) -C BrightspaceBar test
