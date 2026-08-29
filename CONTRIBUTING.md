# Contributing

## Getting set up

Fork the repo, clone your fork, then:

```sh
make setup                      # check prerequisites, install the daemon's npm deps
make test                       # the Swift suite — should be green before you start
```

## Build and test

```sh
make -C Brightspace Bar test     # hermetic Swift suite (no network, no daemon)
cd session-capture && npm test  # daemon unit tests (node:test, no browser launched)
```

Run the Swift tests before pushing — they include the architecture checks below.

## Workflow

The usual open-source loop: find or open an issue → branch → implement →
tests → PR → CI → review → merge. Branch names like `feat/…` or `fix/…` are
appreciated but not enforced.

Open an issue **before** writing code for: large features, architectural
changes (anything the architecture rules below would notice), or anything
touching the D7/D8 security invariants. Small fixes can go straight to a PR.

## Testing expectations

- A bug fix comes with a regression test that fails without the fix.
- New behavior comes with tests.
- The `ArchitectureTests` suite enforces the module boundaries below — if your
  change fights them, that's a design conversation, not a test to loosen.

## Commits and PRs

Keep commits and PRs small and focused — no unrelated cleanup mixed into a
change. The repo uses `Co-Authored-By:` trailers where they apply.

## Formatting

No enforced linter yet. Match the surrounding style; the codebase favors prose
comments that explain *why*, not what.

## Architecture rules

- The Swift app is one SPM package; modules live under
  `BrightspaceBar/Modules/<Name>/` (each with its own Sources, Tests, and
  Makefile).
- `CourseMenu` is the contract module: values only, importing nothing beyond
  Foundation. The GUI module (`Modules/BrightspaceBar`) imports **only**
  `CourseMenu` — view code must never name a backend module
  (`MenuAdapter`, `CoursePipeline`, `AssignmentPipeline`, `QuizPipeline`,
  `ManualItems`).
- `main.swift` is the composition root and the single exemption: it is the one
  file allowed to see both sides and wire them together. It must stay
  **synchronous at top level** — no top-level `await` (an async main starves
  every other MainActor job and permanently empties the menu; this was a real
  bug).
- These rules are enforced by `ArchitectureTests`
  (`BrightspaceBar/Modules/MenuAdapter/Tests/ArchitectureTests.swift`), which
  scan import lines in the source tree. They run as part of `make test`.

## Security invariants (PRs must never break these)

- **D7 — credentials never cross into Swift.** Email, password, and session
  cookies live only in the Node daemon's world (`session-capture/`). Secrets
  never enter `cache/` and never appear in logs (lengths only).
- **D8 — the app only ever spawns the daemon in cron-safe mode.** No app spawn
  ever passes `--allow-full-login`; full login is terminal-initiated by a
  present human (`npm run refresh -- --allow-full-login`).

## Experiments

The historical one-off probes referenced throughout the code (`experiment-*`)
live on the `experiments` branch, kept for reference. They are not subject to
the review standards above.
