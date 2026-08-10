# Experiment 6 — Does the API gate ended courses the way the UI does?

## Question

Brightspace's **web UI** locks a course once its semester ends: the tile greys out,
you can't click in, content is gone. But the enrollments route
(`/d2l/api/lp/1.62/enrollments/myenrollments/`) still *lists* those ended courses.

Open question: is the **REST API** gated the same way? Once a course's `Access`
window has closed, can the API still read its content, announcements, grades, and
assignments — or does it 403 the way the UI locks you out?

## Why it matters

Real end-to-end tests want real course data. Right now only **two** org units are
inside a live `Access` window — `412690` (Purdue Civics Knowledge Test) and
`440703` (Scholarly Project Milestones) — and both are administrative shells, not
real semester courses with content/grades/assignments. If the API still serves
**ended** courses, then a whole history of real courses (CS 25100, CS 25200, …)
becomes usable as fixture data. If it doesn't, we need another plan.

## Hypothesis

**API_LOCKED** — the user is highly confident the API enforces the same `Access`
window as the UI. Ended courses will 403 (or return empty/forbidden) on the
content-bearing routes, while the live controls return real data.

## Method (GET-only; the sole non-GET anywhere is the token mint POST)

1. Read the live session from `~/Library/Application Support/BrightspaceBar/session.json`
   (`baseUrl`, `cookieHeader`, `csrfToken`). Secrets are never printed, logged, or
   copied — only JWT **length** may be logged.
2. Mint a JWT: `POST {baseUrl}/d2l/lp/auth/oauth2/token`, body `scope=*:*:*`,
   headers `cookie` + `x-csrf-token`. A dead session returns HTTP 200 with an HTML
   stub containing `sessionExpired=1` — detected by that marker, not by status.
3. Probe a spread of org units with `Authorization: Bearer <jwt>`:

   | Bucket | Org unit | Name |
   |---|---|---|
   | ENDED, recent | 1488325 | Spring 2026 CS 25200 |
   | ENDED, recent | 1495427 | Spring 2026 CS 47100 |
   | ENDED, older | 1360027 | Fall 2025 CS 25100 |
   | ENDED, older | 1095299 | Fall 2024 CS 17600 |
   | LIVE control | 412690 | Civics Knowledge Test |
   | LIVE control | 440703 | Scholarly Project Milestones |

4. For each org unit, GET (LP 1.62, LE 1.96 — both proven against this tenant):
   - `/d2l/api/lp/1.62/courses/{id}` — course offering info
   - `/d2l/api/le/1.96/{id}/content/root/` — content TOC
   - `/d2l/api/le/1.96/{id}/news/` — announcements
   - `/d2l/api/le/1.96/{id}/grades/values/myGradeValues/` — my grades
   - `/d2l/api/le/1.96/{id}/dropbox/folders/` — assignment folders
5. Record per (orgUnit, route): HTTP status; on 2xx a small non-secret summary
   (counts, first title) proving real data; on non-2xx the status plus any
   `problem+json` `title`/`detail`. Never dump full bodies.
6. 30s timeout per request, sequential, gentle.

## Verdict criteria

- **API_OPEN** — ended courses return 2xx with real data on most/all routes.
  Hypothesis refuted; ended courses usable as test data.
- **API_LOCKED** — ended courses return 403 (or equivalent) where live controls
  return 2xx. Hypothesis confirmed.
- **MIXED** — some routes open, some locked. Describe the split precisely; a
  partially-open API may still be enough for test data.

Controls discipline: a 404 on a shell course (e.g. shells have no dropbox) is
route-shape noise, not access gating. Compare ended-vs-live **per route** to tell
the two apart.
