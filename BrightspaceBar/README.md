# BrightspaceBar

A macOS menu-bar app showing your Purdue Brightspace courses. Click the icon,
see your classes, click one, Brightspace opens. Modeled on
[RepoBar](https://github.com/steipete/RepoBar)'s pattern; zero external
dependencies.

## Run it

```sh
make run          # build, bundle, ad-hoc sign, launch into the menu bar
```

No session yet? The app still runs and serves whatever is cached, with a
staleness line. To give it a live session:

```sh
make refresh-session               # copy the latest experiment-1 capture
./Scripts/refresh-session.sh --capture   # or log in fresh (browser + MFA)
```

Stub mode (no network, seeded fake courses — the GUI demo):

```sh
BRIGHTSPACEBAR_STUB=1 ./Scripts/run.sh
```

## Test it

```sh
make test         # 131 hermetic tests — no network, no cookie, <1s
make live         # + live-tenant contract tests (needs a fresh session)
make smoke        # launch and verify the process survives
make -C Modules/CoursePipeline test   # one module's slice
```

## Understand it

Read [ARCHITECTURE.md](ARCHITECTURE.md). Short version: five modules under
`Modules/`, GUI sees only the `CourseMenu` contract, credentials come through the
`BrightspaceSession` seam, and a failed fetch can never blank the menu.
