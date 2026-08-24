## What changed

<!-- A short, concrete description of the change. -->

## Why

<!-- The problem or motivation. Link issues if any. -->

## How was it tested

<!-- e.g. `make test` output, new/updated tests, a manual run of the app or daemon. -->

## Screenshots (if applicable)

<!-- Menu-bar/UI changes: a screenshot or short recording. -->

## Checklist

- [ ] `make test` passes from the repo root (Swift + node suites)
- [ ] Respects the D7/D8 invariants: no credential material enters the Swift
      process, logs, or `cache/`; no app-side spawn gains `--allow-full-login`
- [ ] No secrets, tokens, or real credentials committed (code, tests, or fixtures)
