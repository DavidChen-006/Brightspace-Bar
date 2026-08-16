# Experiment 19 — the Option-1 click-through

**Question.** If the app's deep links open in the daemon's own already-signed-in
Chromium instead of the real browser, (a) does the page land with **no login**,
and (b) **how long** does it take, as a user would feel it?

This is the live probe for the "all Chromium" decision: the same persistent
profile the login ladder maintains does the *viewing* too, so one session
serves both the 15-minute fetch and the click.

## Run

```
node click.mjs                 # real recorded assignment link (Civics, db=648911)
node click.mjs <any-deep-link> # e.g. a course home: https://purdue.brightspace.com/d2l/home/412690
```

No install. Playwright is resolved out of `session-capture/node_modules`
(never `npx playwright` — the installer hangs on this machine).
`BSB_ROOT` overrides the root as everywhere else; unset means the
**production** profile, which is the point — this is a live test.

## What it prints

A stage timeline (`window up` → `first content` → `page fully loaded` →
`settled`) and a verdict. The settle step exists because a dead session
answers HTTP 200 and then script-redirects to `/d2l/login` (experiment 2), so
the verdict is judged on the **settled URL** three seconds after load, never
on a status code.

- `LANDED AUTHENTICATED` — the click worked; the `user-felt cost` line is the
  number to judge.
- `LOGIN WALL` — the profile's session didn't carry it. Refresh first
  (`cd ../session-capture && npm run refresh`), then retry.

The window stays open for live inspection; close it (or Ctrl+C) to finish.

## Scope

By decision: no sign-out edge cases, and no second-click-while-open handling —
the profile is single-instance, so a second launch while the window is open
fails with a clear message. Close the window first.

Nothing in `session-capture/` or `BrightspaceBar/` is imported or modified.
