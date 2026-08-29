# Brightspace Bar

A macOS menu-bar app showing your Brightspace (D2L) courses — any school on
Brightspace works; point `BS_BASE_URL` at your tenant (e.g.
`https://yourschool.brightspace.com`, defaults to Purdue's). Click the icon,
see your classes, click one, Brightspace opens. Modeled on
[RepoBar](https://github.com/steipete/RepoBar)'s pattern; zero external
dependencies. Local-only: no server, no telemetry — your credentials go only
to your school's own sign-in page.

## Run it

```sh
make run          # build, bundle, ad-hoc sign, launch into the menu bar
```

No session yet? The app still runs and serves whatever is cached, with a
staleness line. Logging in belongs to the Node daemon next door, and a headed
login only ever happens with you present:

```sh
cd ../session-capture && npm run refresh -- --allow-full-login
```

Stub mode (no network, seeded fake courses — the GUI demo):

```sh
BRIGHTSPACEBAR_STUB=1 ./Scripts/run.sh
```

## Test it

```sh
make test         # 518 hermetic tests — no network, no daemon, ~2s
make live         # + live-tenant tests, which spawn the real daemon
make smoke        # launch and verify the process survives
make -C Modules/CoursePipeline test   # one module's slice
```

## Privacy: everything stays on your Mac

There is no server behind this app. No account with us, no telemetry, no
analytics, no third-party API — the Swift app has zero external dependencies
and only ever reads local files.

- **Your password never leaves your machine except to your school's own
  sign-in page.** The login daemon drives a local Chromium against the same
  Microsoft Entra / Brightspace pages you'd use in Safari — nothing in
  between, nowhere else.
- **Login state is stored locally, readable only by you.** The browser
  profile and `session.json` live under
  `~/Library/Application Support/BrightspaceBar`, gitignored and never
  uploaded.
- **Session cookies are treated as credentials too** — cached locally, sent
  only to your Brightspace tenant.
- **The menu-bar app itself never touches secrets.** It renders cached JSON;
  the daemon owns the login (see ARCHITECTURE.md).

## Understand it

Read [ARCHITECTURE.md](ARCHITECTURE.md). Short version: six modules under
`Modules/`, GUI sees only the `CourseMenu` contract, credentials never cross into
Swift at all (the daemon owns them), and a failed fetch can never blank the menu.
