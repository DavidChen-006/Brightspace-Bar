---
summary: "ghrest developer CLI for GitHub REST endpoints used by RepoBar."
read_when:
  - Inspecting REST responses (traffic, commit stats, Actions)
  - Capturing fixtures for tests or debugging rate limits
---

# ghrest (REST helper)

Lightweight CLI to hit the GitHub REST endpoints RepoBar relies on.

## Setup
- `.env` with `GITHUB_TOKEN=<token>`.
- Optional: `GITHUB_API` to override the REST base (for GHE).

## Commands
- `pnpm ghrest repo <owner/repo>` – repo JSON (stars, issues, default branch).
- `pnpm ghrest ci <owner/repo> [--branch main]` – latest Actions run.
- `pnpm ghrest traffic <owner/repo>` – traffic views/clones (needs admin perms).
- `pnpm ghrest heatmap <owner/repo>` – commit_activity (weekly buckets).
- `pnpm ghrest activity <owner/repo>` – most recent issue/pr comment.
- `pnpm ghrest release <owner/repo>` – newest non-draft release.

## Flags
- `--token` override token, `--host` override REST base, `--json` for raw payloads.

## Notes
- Shows rate-limit reset when available.
- Wrapper script `ghrest` runs `pnpx dotenv-cli -e .env -- tsx Scripts/ghrest.ts`.
