# BrightspaceBar — top-level entry points.
#
#   make setup   check prerequisites, install session-capture's npm deps
#   make login   one-time interactive Chromium login (captures the session)
#   make run     build & run the menu-bar app (delegates to BrightspaceBar/)
#   make test    run the Swift test suite   (delegates to BrightspaceBar/)

.PHONY: setup login run test

setup:
	@test "$$(uname)" = Darwin || { echo "error: BrightspaceBar is a macOS menu-bar app — macOS required"; exit 1; }
	@xcode-select -p >/dev/null 2>&1 || { echo "error: Xcode Command Line Tools missing — run: xcode-select --install"; exit 1; }
	@swift --version 2>/dev/null | awk '/Swift version/ { split($$4, v, "."); if (v[1] < 6 || (v[1] == 6 && v[2] < 2)) { print "error: swift >= 6.2 required, found " $$4; exit 1 } }' || { echo "error: swift not found or too old (need >= 6.2)"; exit 1; }
	@node --version >/dev/null 2>&1 || { echo "error: node not found — need node >= 20 (try: brew install node)"; exit 1; }
	@node -e 'process.exit(parseInt(process.versions.node) >= 20 ? 0 : 1)' || { echo "error: node >= 20 required, found $$(node --version)"; exit 1; }
	cd session-capture && npm install
	@echo
	@echo "Setup complete. Next: run \`make login\` once (interactive Brightspace login), then \`make run\`."

login:
	cd session-capture && npm run capture

run:
	$(MAKE) -C BrightspaceBar run

test:
	$(MAKE) -C BrightspaceBar test
