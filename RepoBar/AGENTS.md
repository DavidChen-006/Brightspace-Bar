# Repository Guidelines

## Project Overview
- RepoBar is a macOS menubar app (SwiftUI + AppKit NSMenu) for GitHub repo status, activity, and local project state.
- Build system: SwiftPM wrapped by `pnpm` scripts; app bundling/signing via `Scripts/*.sh`.
- Testing: Swift Testing (`swift test`) via `pnpm test`/`pnpm check`.

## Project Structure & Module Organization
- `Sources/RepoBar/` holds app code: `App` (entry), `StatusBar` (menus/windows), `Auth` (PKCE + TokenStore), `API` (GitHub GraphQL/REST clients), `Models`, `Views`, `Settings`, `Support`; generated GraphQL types, if produced, live under `API/Generated` (do not hand edit).
- `Tests/RepoBarTests/` contains Swift Testing suites; keep new coverage close to the code under test.
- `Resources/` includes app assets/entitlements; `Scripts/` wraps all build/lint/run steps; `GraphQL/` stores schemas/operations; `docs/` has spec and release notes.

## Build, Test, and Development Commands
- Use pnpm scripts from repo root (pnpm v10+, Swift 6.2, Xcode 26): `pnpm install` once for script deps.
- `pnpm check` → swiftformat + swiftlint + swift test (use before PRs).
- `pnpm check:coverage` → coverage run (isolated build dir under `.build/coverage`).
- `pnpm test` → `Scripts/test.sh` (SwiftPM `--cache-path ~/Library/Caches/RepoBar/swiftpm`); add `--filter` for focused runs.
- `pnpm build` → `swift build` (debug).
- `pnpm start` / `pnpm restart` → `Scripts/compile_and_run.sh` rebuilds + packages/codesigns + relaunches the menubar app (no tests); quit via `pnpm stop` or the menu.
- Guardrail: always launch via `pnpm start`/`pnpm restart` from `~/Projects/RepoBar` (other checkouts under `/private/tmp/...` can look identical in the menubar). If behavior/UI doesn’t match code, verify the running binary path: `pgrep -af "RepoBar.app/Contents/MacOS/RepoBar"`.
- `pnpm codegen` only after GraphQL schema access is configured; leaves outputs in `Sources/RepoBar/API/Generated`.
- Preferred workflow: after any code change run `pnpm restart` to rebuild/relaunch, and run `pnpm test` when you actually need tests.

## Coding Style & Naming Conventions
- Enforce formatting with `swiftformat` (4-space indent, inline commas, wrap args/collections before first element, no semicolons) and lint with `swiftlint` (see `.swiftlint.yml`; unused imports/declarations flagged, many length limits disabled).
- Swift 6.2, prefer strict typing and small files (<500 LOC as a guardrail); keep MenuBarExtra/UI code in SwiftUI with extracted helpers.
- SwiftUI: use modern `@Observable` (not `ObservableObject`).
- Naming: types UpperCamelCase; methods/properties lowerCamelCase; tests mirror subject names; avoid abbreviations except common GitHub/API terms.

## Testing Guidelines
- Framework: Swift Testing via `swift test`. Name suites `<Thing>Tests` and functions `test_<behavior>()`.
- Cover new logic (PKCE helpers, loopback parsing, heatmap bucketing, GitHub client mappers, refresh/backoff logic). Use deterministic fixtures/mocks for GitHub data.
- Run `pnpm check` before pushing; prefer adding tests alongside bug fixes.

## Commit & Pull Request Guidelines
- Commit messages follow the existing short, imperative style; optional scoped prefixes (`menu:`, `settings:`, `tests:`, `fix:`). Keep them concise; present tense; no trailing period.
- PRs: include a brief summary, linked issue/Asana ticket if any, screenshots or clips for UI changes (menubar window, settings), and note the exact commands run (`pnpm check`/`pnpm test`).

## Security & Configuration Tips
- Keep GitHub App secrets/private key out of the repo; tokens live in Keychain. Default OAuth loopback is `http://127.0.0.1:53682/callback`; TLS required for GHE.
- Do not log tokens or traffic stats responses; prefer redacted diagnostics. Avoid editing `Info.plist` flags that enforce LSUIElement/single-instance unless coordinated.

## Agent-Specific Notes
- Always use the provided scripts instead of raw `swift build/test` when possible; do not edit generated GraphQL files directly.
- If you change shared scripts, mirror updates in `agent-scripts` per guardrails. Clean up any tmux sessions you start for long-running tasks.
- Prefer models directly in views; view models only when they add real derived value.
- Reminder: when modifying menus, update the Display Settings menu builder too.
- Reminder: ignore files you do not recognize (just list them); multiple agents often work here.
