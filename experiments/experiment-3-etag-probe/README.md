# Experiment 3 — Does Brightspace support HTTP conditional requests?

Can RepoBar poll cheaply by sending `If-None-Match: <etag>` and getting back a
`304 Not Modified` with an empty body? This probes the D2L Valence API to find
out — read-only GETs against three endpoints, plus a bogus-validator control so
any observed `304` can actually be trusted.

## Run it

```bash
npm install
npm test
```

Artifacts land in `artifacts/`: `run.log` (a timestamped line per request) and
`findings.json` (the full machine-readable result).

### Prerequisite: Experiment 1

Reads `../experiment-1-fresh-cookie/artifacts/session.json` (override with
`SESSION_JSON`). That file holds a captured session cookie with a short life. If
the mint fails, the cookie has expired — **re-run Experiment 1** to refresh it,
then run this again. A dead cookie is reported as `SESSION_EXPIRED` (with the
cookie's age in hours) and the ETag assertions skip rather than fail.

## Findings

**Verdict: `NO_VALIDATOR`.** (Run 2026-08-08, cookie age ~1.6h — alive.)

None of the three probed endpoints return a validator header. Every baseline
response carried `cache-control: no-cache, no-store`, `expires: -1`, and no
`etag` or `last-modified` at all:

| Endpoint | Baseline | Validator headers | Bogus control | Classification |
|---|---|---|---|---|
| `lp/1.62/users/whoami` | 200, 132 B | none | 200 | `NO_VALIDATOR` |
| `lp/1.62/enrollments/myenrollments` | 200, 14938 B | none | 200 | `NO_VALIDATOR` |
| `versions/` | 200, 2307 B | none | 200 | `NO_VALIDATOR` |

No conditional requests were possible (there was no `etag`/`last-modified` to
echo back), so no `304` was ever observed. The bogus-validator control returned
`200` everywhere, confirming the server isn't silently 304-ing — it simply has
no conditional-request machinery on these endpoints. `cache-control:
no-cache, no-store` says as much directly: the tenant is telling clients not to
cache these responses.

### What this means for refresh strategy

**Cheap conditional polling is not available. Cache by timestamp instead.**

A menu-bar app listing the user's courses should:

- Poll `myenrollments` on a plain interval and keep the last good response in a
  local timestamp cache; every poll pays the full ~15 KB body (there is no
  `304` shortcut to earn).
- Poll infrequently — a course list changes on the order of days, so a long
  interval (e.g. hourly, or on app focus) plus a manual refresh is plenty.
- Refresh from the cache on launch and only hit the network in the background,
  since the mint + fetch is the real cost, not bandwidth.
