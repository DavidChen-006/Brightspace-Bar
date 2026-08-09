#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not installed. Install via 'brew install swiftlint'" >&2
  exit 1
fi
CONFIG="$ROOT_DIR/.swiftlint.yml"
# Older SwiftLint builds lack --path; pass the path positionally for compatibility.
swiftlint lint --strict --quiet --config "$CONFIG" "$ROOT_DIR/Sources" "$ROOT_DIR/Tests"
