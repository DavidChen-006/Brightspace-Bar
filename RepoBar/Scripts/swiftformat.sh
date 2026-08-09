#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v swiftformat >/dev/null 2>&1; then
  echo "swiftformat not installed. Install via 'brew install swiftformat'" >&2
  exit 1
fi
swiftformat "$ROOT_DIR/Sources" "$ROOT_DIR/Tests"
