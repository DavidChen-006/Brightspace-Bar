#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KINGFISHER_INFO_PLIST="${ROOT_DIR}/.build/checkouts/Kingfisher/Sources/Info.plist"
if [ -f "${KINGFISHER_INFO_PLIST}" ]; then
  if command -v trash >/dev/null 2>&1; then
    trash "${KINGFISHER_INFO_PLIST}"
  else
    rm -f "${KINGFISHER_INFO_PLIST}"
  fi
fi
