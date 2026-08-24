# Experiment 8 — the calendar route

## Question

Is `GET /d2l/api/le/{ver}/calendar/events/myEvents/` a better source for "what's due
soon" than looping `dropbox/folders/` per course — and does it carry anything we can
deep-link with experiment 7's template?

## Why it might matter more than expected

The route is **global**, not org-unit-scoped: `apiClient.leGlobal(...)` in the MCP,
i.e. `/d2l/api/le/{ver}/calendar/events/myEvents/`, with the courses passed as a
query parameter (`orgUnitIdsCSV`) rather than in the path.

Experiment 6 proved every *org-unit-scoped* route 403s once a course's `Access`
window closes. A global route may be governed by a different permission check.

**H1 (the valuable hypothesis): the calendar route returns events for ENDED courses.**
If true, we recover real assignment titles and real due dates from real semester
courses — which is exactly the test-data problem experiment 6 left us with. If false,
experiment 6's verdict simply extends here and nothing is lost.

## What the MCP source already tells us (read, not guessed)

From `brightspace-mcp-server/src/tools/get-upcoming-due-dates.ts`:

- `orgUnitIdsCSV` is **required** — the route will not enumerate courses for you, so
  it does not remove the enrollments call, it only replaces the per-course fan-out.
- The response wrapper is **`Objects`**, not `Items` (explicitly commented as a
  gotcha), with a `Next` field for pagination.
- Event fields: `CalendarEventId`, `Title`, `OrgUnitName`, `OrgUnitId`,
  `StartDateTime`, `EndDateTime`, `IsAllDayEvent`.
- **No dropbox folder id.** `CalendarEventId` is a calendar id, not the `db=` value
  experiment 7's template needs — so calendar rows are not directly deep-linkable.

## Probes

1. **Version discovery** — `GET /d2l/api/versions/` for the LE version this tenant
   supports, rather than assuming 1.96.
2. **Live courses, forward window** — the two courses with API access (412690, 440703),
   now → +90 days. Expected: possibly empty (summer, shell courses).
3. **H1: ended courses, historical window** — the real semester courses over
   Fall 2025 (2025-08-01 → 2025-12-31). This is the hypothesis test.
4. **All 27 org units at once, wide window** — does a mixed CSV of live + ended ids
   error, or silently drop the ended ones?
5. **Field dump** — every field on a real event, to confirm whether anything
   deep-linkable exists (checking the MCP's claim rather than trusting it).

## Verdict criteria

- `CALENDAR_OPEN_FOR_ENDED` — H1 holds; real past-semester assignment data is
  reachable. Big win for test fixtures.
- `CALENDAR_LOCKED_LIKE_CONTENT` — ended courses yield nothing; experiment 6's
  gate applies here too.
- `CALENDAR_EMPTY` — route works but returns nothing usable for any window;
  professors here may not publish calendar dates.

Separately, state whether the route is **preferable to `dropbox/folders/`** for the
upcoming-assignments feature, given that it carries no `db=` id.

## Rules

GET-only (the token mint POST is the sole exception). No cookie/CSRF/JWT ever
printed or logged — JWT length only. Sequential requests, 30s timeouts.
Uncommitted; this folder is disposable.
