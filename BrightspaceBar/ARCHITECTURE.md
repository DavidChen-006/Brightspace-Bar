# BrightspaceBar — how the app actually works

One Swift package, five modules, zero external dependencies. Each module lives in
`Modules/<Name>/` with its own `Sources/`, `Tests/`, and `Makefile`.

## The map

```
┌─────────────────────────────────────────────────────────────────────┐
│                        main.swift  (composition root)               │
│      the ONE file allowed to see everything; wires the stack        │
└─────────────────────────────────────────────────────────────────────┘

BrightspaceSession        CoursePipeline           CourseMenu    BrightspaceBar
(how we get a cookie)     (the backend)            (the contract)  (the GUI)
                                                        ↑              │
  SessionProviding ◄──── BrightspaceCourseSource        │   depends on │
  FileSessionProvider          │ fetch                  └──────────────┘
  StaticSessionProvider        ▼
                          Poller ⇄ CourseCache ── MenuAdapter ──► MenuModel
                          (PollPolicy decides)    (the wiring)
```

Arrows are the only dependencies that exist. **`BrightspaceBar` (the GUI) depends
on `CourseMenu` only** — it cannot name a cookie, a JWT, a `Course`, or
`URLSession`, because `Package.swift` does not grant it access and
`ArchitectureTests` fails if any view file tries. The GUI was built and tested
against `StubMenuDataSource` before the backend was ever attached, and that
remains possible today (`BRIGHTSPACEBAR_STUB=1`).

## The five modules

| Module | Owns | Key fact |
|---|---|---|
| `BrightspaceSession` | *How credentials are obtained.* `SessionProviding` protocol, `FileSessionProvider` | The seam. Today a file; later a `WKWebView` login window — a one-line swap in `main.swift` |
| `CoursePipeline` | Parse, cache, poll, fetch (experiment 4, verbatim) | Pure decision functions (`PollPolicy`, `CourseCache.fold`, `decodeMint`) with effects at the edges |
| `CourseMenu` | The backend↔GUI contract: `MenuModel`, `MenuRow`, `MenuDataSource` | Plain `Equatable` values. This *is* the API — in types, not JSON (no Flask/FastAPI; nothing serializes) |
| `MenuAdapter` | The wiring: `[Course] → MenuModel`, URL derivation, staleness line | The only module that sees both sides |
| `BrightspaceBar` | `NSStatusItem`, `NSMenu` rendering, `main.swift` | `main.swift` must stay **synchronous at top level** — a top-level `await` starves the MainActor and blanks the menu (real bug, documented in the file) |

## One fetch, end to end

1. `Poller.tick(trigger)` asks `PollPolicy` — manual clicks always fetch; launch/timer only when stale.
2. `BrightspaceCourseSource` asks the **session seam** for credentials (fresh read every fetch — a refreshed file wins without a relaunch).
3. Cookie → `POST /d2l/lp/auth/oauth2/token` → 60-min JWT. A dead session comes back HTTP 200 + `sessionExpired=1` stub (measured), classified as `.sessionExpired`.
4. JWT → `GET myenrollments` → `EnrollmentParser` → `[Course]`.
5. `CourseCache.fold` decides what survives: success → `.updated`/`.unchanged` (+ atomic write to `~/Library/Caches/BrightspaceBar/courses.json`); **any failure → `.preservedStale`** — the menu keeps its courses and shows an honest staleness line. Failure can never blank the menu.
6. `MenuAdapter` snapshots cache + clock through `MenuTranslation` into a `MenuModel`; `MenuAssembler` renders it; unchanged models skip the rebuild (`Equatable`).

`currentMenu()` (menu open) serves memory/disk only — there is deliberately no code
path from it to a socket.

## Sessions: the part that is not solved yet

The D2L cookie dies in hours (measured alive at 4.4h, dead at 15.6h; idle-vs-absolute
still unknown). The design treats that as normal, not exceptional:

- **Today**: `Scripts/refresh-session.sh` fills
  `~/Library/Application Support/BrightspaceBar/session.json` from experiment 1's
  interactive capture (headed browser + MFA). `SESSION_JSON` overrides the path.
- **Later**: a `WKWebViewSessionProvider` — login window in-app, cookies read from
  `WKHTTPCookieStore`, persistent `WKWebsiteDataStore` keeping the Entra SSO
  session warm for silent re-mints (the strategy `brightspace-mcp-server`'s
  `silent-refresh-cli.ts` proves with Playwright, minus the bundled browser).
- Credentials never live inside the repository, never appear in logs or errors.

## Tests (131, hermetic by default)

`swift test` needs no network, no cookie, no session file. Time is injected
(`Clock` protocol; `TestClock` advances by hand — nothing may call `Date()` except
`SystemClock`). `BS_LIVE=1` (`make live`) adds the live-tenant contract runs, which
exist to catch fake-vs-reality drift.

Two suites enforce structure, not behavior: `ArchitectureTests` reads import lines
so view code can never see backend modules, and the contract suite runs fake and
real `CourseSource` through the same assertions.

## Provenance

Built from the experiment chain in the repo root — exp 1 (cookie capture), exp 2
(cookie→JWT mint), exp 3 (no ETags exist; polling must be interval-based), exp 4
(pipeline), exp 5 (GUI + contract). Those folders remain as runnable references;
this app is a consolidation, not a link against them.
