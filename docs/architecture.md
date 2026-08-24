# Architecture

A short orientation. The deep dives live elsewhere and this page links rather
than repeats them:

- [`BrightspaceBar/ARCHITECTURE.md`](../BrightspaceBar/ARCHITECTURE.md) — the
  Swift package: modules, dependency rules, the fetch path in detail.
- [`docs/LADDER-PLAN.md`](LADDER-PLAN.md) — the login ladder, file contracts,
  and the D-numbered invariants (ground truth for the daemon design).

## Two components, one wall

**The Swift menu-bar app** (`BrightspaceBar/`) renders cached JSON. It has no
network code, no credential types, and no way to log in — by construction, not
by policy. **The Node daemon** (`session-capture/`) owns the session: a
persistent Chromium profile, a `session.json`, and a login ladder that
escalates only as far as it must (existing credentials → silent Entra SSO →
full headless login with an MFA number shown on the menu-bar icon).

## Data flow

```
trigger (launch / timer / Refresh click)
  → app spawns `node refresh.mjs` (cron-safe args only)
    → daemon climbs the ladder, fetches courses + assignments + quizzes
      → atomic write: $BSB_ROOT/cache/data.json + status.json
        → the app reads the cache fresh on every fetch (DaemonCache)
          → CourseCache.fold → MenuAdapter/MenuTranslation → NSMenu
```

`BSB_ROOT` defaults to `~/Library/Application Support/BrightspaceBar`; every
daemon path hangs off it (`src/paths.mjs`), which is the entire test-isolation
story — tests point it at a temp dir. Cache changes are picked up on the next
fetch (fresh reads, plus a kqueue directory watcher for the ephemeral
`mfa.json` that puts the MFA number on the icon).

## Key invariants

- **D7** — credentials never leave the daemon's world: never in `cache/`,
  never in logs (lengths only), never in the Swift process. Stored 0600 under
  `BSB_ROOT`, never in git.
- **D8** — the app never passes `--allow-full-login`. Every app-side spawn is
  cron-safe; an interactive login is terminal-initiated by a present human.
- **The GUI imports only `CourseMenu`** — enforced by `ArchitectureTests`
  reading import lines. Adapters translate between pipelines and the menu
  model; all wiring lives in `main.swift`.
- **`main.swift` stays a synchronous composition root** — a top-level `await`
  starves the MainActor and blanks the menu (a real bug, documented in the
  file).
- **Failure never blanks the menu** — any failed refresh folds to
  `.preservedStale`; a failed daemon run never truncates an existing
  `data.json`.

## Extension points

- **A new pipeline module**: add `Modules/<Name>/` with its own
  `Sources`/`Tests`, expose it through an adapter into `MenuModel`, wire it in
  `main.swift` only. New `CourseSource`/`AssignmentSource` conformers must pass
  the existing contract suites.
- **A new ladder rung**: a rung is a value implementing one seam —
  `{ kind: "silent" | "full", attempt({paths, log}) }` (see `src/rungs/`).
  Register it in the ladder order; `full` rungs are gated behind
  `--allow-full-login` automatically.
- **A new browser target**: add a case to `BrowserTarget`
  (`Modules/BrightspaceBar/Sources/BrowserTarget.swift`) — the exhaustive
  switch makes the new opener a compile-time obligation. `BSB_BROWSER_TARGET`
  selects at runtime.
- **New endpoints**: behind the daemon's fetcher seam (`fetch-engine.mjs`);
  the whole app-facing API is the `data.json` shape in LADDER-PLAN.

## Intentionally strange decisions

- **The day popup is an in-row bubble, not a floating panel.** NSMenu's modal
  tracking session owns every mouse event while a menu is open; a click on a
  separate window reads as "outside the menu" and closes it before the panel
  hears anything. The one place clicks are delivered is a menu item's own
  view, so the bubble lives inside the row's view tree and accepts the
  clipping cost (`GraphDayPopup.swift`, proven by experiments 9/14/16).
- **Deep links add tabs over a fixed CDP port.** `browser-open.mjs` launches
  the signed-in Chromium with CDP on localhost:9223 (`BSB_OPEN_CDP_PORT`); the
  next click connects to that port and adds a tab instead of spawning a second
  browser. A fixed port *is* the rendezvous protocol — no discovery.
- **`RepoPaths` derives the repo root from `#filePath`.** The CLI paths the
  app spawns default to the checkout the binary was *built* from — exactly
  right for the run-from-source workflow, wrong for a relocated binary, which
  is what the `BSB_OPEN_CLI`/`BSB_REFRESH_CLI` env overrides are for.
- **The MFA number travels as a file (`cache/mfa.json`), not stdout.** The app
  is not always the spawner (a full login can be terminal-initiated), so the
  transport must not assume a parent pipe. The icon is a pure function of the
  file's existence and a 60s TTL — a crashed rung can never wedge a stale
  number.
