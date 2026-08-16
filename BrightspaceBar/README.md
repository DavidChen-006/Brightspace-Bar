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

## Understand it

Read [ARCHITECTURE.md](ARCHITECTURE.md). Short version: six modules under
`Modules/`, GUI sees only the `CourseMenu` contract, credentials never cross into
Swift at all (the daemon owns them), and a failed fetch can never blank the menu.
