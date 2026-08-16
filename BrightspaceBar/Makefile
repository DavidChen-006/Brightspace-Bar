# BrightspaceBar — one SPM package, six modules under Modules/<Name>/.
#
#   make test              hermetic suite (no network, no daemon) — the default
#   make live              adds the live-tenant tests, which spawn the real daemon
#   make run               build, bundle, sign, launch into the menu bar
#   make smoke             launch + verify the process survives 3s, then kill
#   make build / clean
#
# Credentials are no longer this package's business: the Node daemon in
# ../session-capture owns the login ladder and writes the cache this app reads.
#
# Each module also has its own Makefile: `make -C Modules/CoursePipeline test`
# runs just that module's suite.

.PHONY: build test live run smoke clean

test:
	swift test

build:
	swift build

# BS_LIVE gates the cases that reach the tenant. They spawn the real daemon
# (cron-safe: never --allow-full-login), so they need a BSB_ROOT a login has
# already seeded — `BSB_ROOT` (optional) points them at a specific one.
live:
	BS_LIVE=1 swift test

run:
	./Scripts/run.sh

smoke:
	./Scripts/run.sh --smoke

clean:
	swift package clean
