#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm not found; please install pnpm to use this wrapper" >&2
  exit 1
fi
pnpm "$@"
