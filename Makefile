# BrightspaceBar — top-level entry points.
#
#   make setup   check prerequisites, install session-capture's npm deps,
#                install the agent skill, record where this checkout is
#   make start   THE one command: build the app, ensure credentials (prompting
#                once if needed), launch the menu bar, run the headless login
#   make login   the same as start, but the sign-in happens in a VISIBLE
#                Chromium window you finish yourself — for accounts the
#                headless flow cannot read (no number on the icon)
#   make run     build & run the menu-bar app (delegates to BrightspaceBar/)
#   make test    run the Swift test suite   (delegates to BrightspaceBar/)
#   make skill   install the agent skill (skills/brightspace) into the
#                skills directories agents read: ~/.claude/skills,
#                ~/.agents/skills, ~/.codex/skills — as symlinks, so the
#                skill tracks this checkout. SKILL_DIRS overrides the list.
#   ./bsb        the agent CLI itself (`./bsb --help`)

.PHONY: setup start login run test skill

SKILL_DIRS ?= $(HOME)/.claude/skills $(HOME)/.agents/skills $(HOME)/.codex/skills
BSB_ROOT ?= $(HOME)/Library/Application Support/BrightspaceBar

# A symlink per directory, never a copy: the skill's scripts/bsb resolves the
# checkout through the link, and a copy would go stale the next time the CLI
# learned a command. An existing path that is NOT our link is left alone and
# named, because replacing someone's skill folder is not this target's call.
#
# Also records this checkout's path in $BSB_ROOT/checkout, which is how a
# COPIED install of the skill (`npx skills add DavidChen-006/Brightspace-Bar`
# copies the directory into an agent's skills folder) finds the CLI.
skill:
	@mkdir -p "$(BSB_ROOT)" && printf '%s\n' "$(CURDIR)" > "$(BSB_ROOT)/checkout" \
	  && echo "skill: recorded this checkout in $(BSB_ROOT)/checkout"
	@for dir in $(SKILL_DIRS); do \
	  mkdir -p "$$dir"; \
	  stale="$$dir/brightspace-bar"; \
	  if [ -L "$$stale" ] && [ "$$(readlink "$$stale")" = "$(CURDIR)/skills/brightspace-bar" ]; then \
	    rm "$$stale" && echo "skill: removed the old brightspace-bar link at $$stale (the skill is now 'brightspace')"; \
	  fi; \
	  target="$$dir/brightspace"; \
	  if [ -L "$$target" ] && [ "$$(readlink "$$target")" = "$(CURDIR)/skills/brightspace" ]; then \
	    echo "skill: already installed at $$target"; \
	  elif [ -e "$$target" ] || [ -L "$$target" ]; then \
	    echo "skill: $$target exists and is not this checkout's link — left alone"; \
	  else \
	    ln -s "$(CURDIR)/skills/brightspace" "$$target"; \
	    echo "skill: installed at $$target"; \
	  fi; \
	done
	@echo "Agents that read those directories now see the 'brightspace' skill (restart a running session to load it)."

start:
	$(MAKE) -C BrightspaceBar bundle
	cd session-capture && npm run start

setup:
	@test "$$(uname)" = Darwin || { echo "error: BrightspaceBar is a macOS menu-bar app — macOS required"; exit 1; }
	@xcode-select -p >/dev/null 2>&1 || { echo "error: Xcode Command Line Tools missing — run: xcode-select --install"; exit 1; }
	@swift --version 2>/dev/null | awk '/Swift version/ { split($$4, v, "."); if (v[1] < 6 || (v[1] == 6 && v[2] < 2)) { print "error: swift >= 6.2 required, found " $$4; exit 1 } }' || { echo "error: swift not found or too old (need >= 6.2)"; exit 1; }
	@node --version >/dev/null 2>&1 || { echo "error: node not found — need node >= 22 (try: brew install node)"; exit 1; }
	@node -e 'process.exit(parseInt(process.versions.node) >= 22 ? 0 : 1)' || { echo "error: node >= 22 required, found $$(node --version)"; exit 1; }
	cd session-capture && npm install
	@echo
	@$(MAKE) --no-print-directory skill
	@echo
	@echo "Setup complete. Next: \`make start\` — the one command (builds, prompts for credentials once, launches the menu bar, logs in)."
	@echo "Then, in Claude Code / Codex / any agent that reads skills: \"read my <course> syllabus and put the due dates on my calendar\"."

login:
	$(MAKE) -C BrightspaceBar bundle
	cd session-capture && npm run login

run:
	$(MAKE) -C BrightspaceBar run

test:
	$(MAKE) -C BrightspaceBar test
