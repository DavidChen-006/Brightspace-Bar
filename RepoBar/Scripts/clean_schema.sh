#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_JSON="$ROOT/GraphQL/schema.json"
OUT_SDL="$ROOT/GraphQL/schema.graphqls"
TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN required}"

mkdir -p "$ROOT/GraphQL"

curl -s -H "Authorization: Bearer $TOKEN" \
     -H "User-Agent: RepoBar-Codegen" \
     -X POST -d '{"query":"query IntrospectionQuery { __schema { queryType { name } mutationType { name } subscriptionType { name } types { ...FullType } directives { name description locations args { ...InputValue } } } } fragment FullType on __Type { kind name description fields(includeDeprecated: true) { name description args { ...InputValue } type { ...TypeRef } isDeprecated deprecationReason } inputFields { ...InputValue } interfaces { ...TypeRef } enumValues(includeDeprecated: true) { name description isDeprecated deprecationReason } possibleTypes { ...TypeRef } } fragment InputValue on __InputValue { name description type { ...TypeRef } defaultValue } fragment TypeRef on __Type { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } } }"}' \
     https://api.github.com/graphql > "$OUT_JSON"

# Convert to SDL with apollo-ios-cli, which is more tolerant on JSON -> SDL.
./apollo-ios-cli convert-schema --input "$OUT_JSON" --output "$OUT_SDL" --header "Authorization: Bearer $TOKEN" --header "User-Agent: RepoBar-Codegen"

echo "Schema written to $OUT_SDL"
