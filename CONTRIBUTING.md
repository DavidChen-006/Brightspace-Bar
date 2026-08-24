# Contributing

## Build and test

```sh
make setup                      # check prerequisites, install the daemon's npm deps
make -C BrightspaceBar test     # hermetic Swift suite (no network, no daemon)
cd session-capture && npm test  # daemon unit tests (node:test, no browser launched)
```

Run the Swift tests before pushing — they include the architecture checks below.

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

`experiments/` contains historical one-off probes kept for reference. They are
not subject to the review standards above.
