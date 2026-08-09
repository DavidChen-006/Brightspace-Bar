---
summary: "ghql developer CLI for running GitHub GraphQL queries used by RepoBar."
read_when:
  - Debugging GraphQL data for RepoBar
  - Regenerating fixtures or investigating rate limits
---

# ghql (GraphQL helper)

Developer-only CLI to hit GitHub GraphQL quickly without touching the app.

## Setup
- Put a token in `.env` as `GITHUB_TOKEN=<token>` (same scopes as the app: metadata, contents, issues, pulls, actions, checks, admin:read for traffic if needed).
- Optional overrides: `GITHUB_GRAPHQL` for custom endpoints (e.g. GHE).

## Commands
- `pnpm ghql repo <owner/repo>` – runs `GraphQL/RepoSnapshot.graphql`, prints issues/PRs/latest stable release.
- `pnpm ghql contrib <login>` – flattens contribution calendar to day counts (heatmap helper).
- `pnpm ghql run <file.graphql> --vars '{...}'` – run any query file with JSON vars.

## Flags
- `--token` override token, `--host` override endpoint, `--json` for raw JSON, `--raw` dumps server body, `--vars` JSON for `run`.

## Notes
- Prints rate-limit reset when headers are present.
- Uses `pnpx dotenv-cli -e .env -- tsx Scripts/ghql.ts` via the `ghql` wrapper.
