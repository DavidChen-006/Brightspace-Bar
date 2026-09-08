# BrightspaceBar — top-level entry points.
#
#   make setup   check prerequisites, install session-capture's npm deps
#   make start   THE one command: build the app, ensure credentials (prompting
#                once if needed), launch the menu bar, run the headless login
#   make login   one-time interactive Chromium login (captures the session)
#   make run     build & run the menu-bar app (delegates to BrightspaceBar/)
#   make test    run the Swift test suite   (delegates to BrightspaceBar/)
#   make skill   install the agent skill (skills/brightspace-bar) into the
#                skills directories agents read: ~/.claude/skills,
#                ~/.agents/skills, ~/.codex/skills — as symlinks, so the
#                skill tracks this checkout. SKILL_DIRS overrides the list.
#   ./bsb        the agent CLI itself (`./bsb --help`)

.PHONY: setup start login run test skill

SKILL_DIRS ?= $(HOME)/.claude/skills $(HOME)/.agents/skills $(HOME)/.codex/skills

# A symlink per directory, never a copy: the skill's scripts/bsb resolves the
# checkout through the link, and a copy would go stale the next time the CLI
# learned a command. An existing path that is NOT our link is left alone and
# named, because replacing someone's skill folder is not this target's call.
skill:
	@for dir in $(SKILL_DIRS); do \
	  mkdir -p "$$dir"; \
	  target="$$dir/brightspace-bar"; \
	  if [ -L "$$target" ] && [ "$$(readlink "$$target")" = "$(CURDIR)/skills/brightspace-bar" ]; then \
	    echo "skill: already installed at $$target"; \
	  elif [ -e "$$target" ] || [ -L "$$target" ]; then \
	    echo "skill: $$target exists and is not this checkout's link — left alone"; \
	  else \
	    ln -s "$(CURDIR)/skills/brightspace-bar" "$$target"; \
	    echo "skill: installed at $$target"; \
	  fi; \
	done
	@echo "Agents that read those directories now see the 'brightspace-bar' skill (restart a running session to load it)."

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
