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

# A CommandLineTools-only toolchain (no Xcode) ships Testing.framework but
# doesn't tell swiftpm where it lives, so plain `swift test` dies with
# "no such module 'Testing'". These flags point compiler and linker at it;
# harmless when Xcode is installed, since they resolve before falling through.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TEST_FLAGS := $(if $(wildcard $(CLT_FRAMEWORKS)),-Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib,)

test:
	swift test $(TEST_FLAGS)

build:
	swift build

# BS_LIVE gates the cases that reach the tenant. They spawn the real daemon
# (cron-safe: never --allow-full-login), so they need a BSB_ROOT a login has
# already seeded — `BSB_ROOT` (optional) points them at a specific one.
live:
	BS_LIVE=1 swift test $(TEST_FLAGS)

run:
	./Scripts/run.sh

smoke:
	./Scripts/run.sh --smoke

clean:
	swift package clean
