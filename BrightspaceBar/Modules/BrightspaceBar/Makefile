# BrightspaceBar — this module's slice of the package suite.
# SPM builds one package, so everything delegates to the root with a filter.

.PHONY: test build

test:
	swift test --package-path ../.. --filter BrightspaceBarTests

build:
	swift build --package-path ../..
