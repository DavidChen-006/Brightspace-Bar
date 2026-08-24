# Experiment 6 — Does the API gate ended courses like the UI? → **API_LOCKED**

**Verdict: API_LOCKED. Hypothesis confirmed.** Every ended course returned `403`
on every content-bearing route, while the two live controls returned `200` with
real data on those same routes. Once a course's `Access` window closes, the REST
API locks it exactly as the web UI does — the enrollments route will still *list*
an ended course, but you cannot read its content, announcements, grades, or
assignments through the API. Ended courses are therefore **not** usable as
fixture data; the only org units the API will actually serve are the ones inside
a live `Access` window.

## Matrix (HTTP status per org unit × route)

| Org unit | bucket | course_info¹ | content_root | news | my_grades | dropbox_folders |
|---|---|---|---|---|---|---|
| 1488325 Spring 2026 CS 25200 | ended | 403 | **403** | **403** | **403** | **403** |
| 1495427 Spring 2026 CS 47100 | ended | 403 | **403** | **403** | **403** | **403** |
| 1360027 Fall 2025 CS 25100 | ended | 403 | **403** | **403** | **403** | **403** |
| 1095299 Fall 2024 CS 17600 | ended | 403 | **403** | **403** | **403** | **403** |
| 412690 Civics Knowledge Test | live | 403 | **200** (6 mod) | **200** (4) | **200** (1) | **200** (1) |
| 440703 Scholarly Project Milestones | live | 403 | **200** (11 mod) | **200** (466) | **200** (0) | **200** (3) |

The four **content-bearing LE routes** (content / news / grades / dropbox) are the
signal, and they split perfectly clean: **live = 200, ended = 403.**

¹ **`course_info` (`/d2l/api/lp/1.62/courses/{id}`) is route-shape noise, not
gating.** It returned `403` for *every* org unit including both live controls, so
it fails uniformly regardless of course state — that LP endpoint needs a
permission/role this token doesn't carry, and it tells us nothing about the
ended-vs-live question. Excluded from the verdict. The `403` bodies on this route
were non-JSON (no `problem+json` `title`/`detail`), consistent with a
permission-denied page rather than an API error object.

## Reading the controls correctly

This is why the live controls matter: if we'd only probed ended courses and seen
`403` everywhere, we couldn't distinguish "access gated" from "these routes just
don't work for me." The controls prove the routes work — the same content route
that `403`s on ended CS 25100 returns 6 modules on the live Civics course. The
difference is the course's `Access` state, nothing else.

## Surprises worth knowing

- **The two live "shells" are richer than expected.** Civics: 6 content modules,
  4 announcements, 1 grade value, 1 dropbox folder. Scholarly Project Milestones:
  11 modules, **466 announcements**, 3 dropbox folders. They aren't semester
  courses, but they are real content surfaces — enough to exercise content /
  news / grades / dropbox parsers against genuine data.
- **`403` is instant and total**, not a slow timeout or a partial read. The gate
  is enforced at the org-unit level before any route logic runs.
- The session stayed live throughout (JWT minted, length 812; no
  `sessionExpired=1` stub).

## Implication for getting real test data

Ended courses are off the table. The realistic options, in order:

1. **Wait for live enrollment.** When Fall 2026 registration lands, those org
   units enter a live `Access` window and every route opens. This is the natural
   source of real, current course data.
2. **Use the two live shells as content fixtures now.** They already serve real
   content/news/grades/dropbox payloads — good enough to validate parsers even if
   they aren't term courses.
3. **Capture-and-freeze while a course is live.** The only durable way to keep a
   real course's data as a fixture is to snapshot its API responses *during* its
   `Access` window; once the window closes the API will not serve it again.

## Files

- `SPEC.md` — question, hypothesis, method, verdict criteria (written before the run)
- `src/probe.py` — GET-only probe (mint POST excepted); secrets never logged
- `artifacts/findings.json` — full result matrix

## Reproduce

```sh
python3 src/probe.py   # needs a live session at
                       # ~/Library/Application Support/BrightspaceBar/session.json
```
