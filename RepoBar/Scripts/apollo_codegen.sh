#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APOLLO_BIN="${APOLLO_BIN:-$ROOT/apollo-ios-cli}"
if ! command -v "$APOLLO_BIN" >/dev/null 2>&1; then
  if [ -x "$APOLLO_BIN" ]; then
    :
  else
    echo "apollo-ios-cli not found. Build with: swift package --allow-writing-to-package-directory apollo-cli-install" >&2
    exit 1
  fi
fi

cd "$ROOT"
"$APOLLO_BIN" fetch-schema --path apollo-codegen.json --header "Authorization: Bearer ${GITHUB_TOKEN:?GITHUB_TOKEN required}" --header "User-Agent: RepoBar-Codegen" ${GITHUB_GRAPHQL:+--endpoint-url "$GITHUB_GRAPHQL"}
"$APOLLO_BIN" generate --path apollo-codegen.json
