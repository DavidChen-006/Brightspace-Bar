# BrightspaceBar — one SPM package, five modules under Modules/<Name>/.
#
#   make test              hermetic suite (no network, no cookie) — the default
#   make live              adds the live-tenant contract tests (needs a session)
#   make run               build, bundle, sign, launch into the menu bar
#   make smoke             launch + verify the process survives 3s, then kill
#   make refresh-session   fill ~/Library/Application Support/BrightspaceBar/session.json
#   make build / clean
#
# Each module also has its own Makefile: `make -C Modules/CoursePipeline test`
# runs just that module's suite.

.PHONY: build test live run smoke refresh-session clean

test:
	swift test

build:
	swift build

# BS_LIVE gates the network-touching cases; SESSION_JSON (optional) points the
# session seam at a specific capture instead of the Application Support default.
live:
	BS_LIVE=1 swift test

run:
	./Scripts/run.sh

smoke:
	./Scripts/run.sh --smoke

refresh-session:
	./Scripts/refresh-session.sh

clean:
	swift package clean
