# Experiment 8 — the calendar route

**Verdict: `CALENDAR_EMPTY` for assignments. Keep `dropbox/folders/` as the source.**

The route works — HTTP 200 on every query, never a 403, even for ended courses — but
it returned **zero assignment due dates** for any course in any window. The only three
events it produced are `EventType: 1` announcements on the Civics shell (guest
lectures, voter registration info), each with `AssociatedEntity: null` and
`IsAssociatedWithEntity: false`. Nothing due, nothing gradeable, nothing to click
through to an assignment. So the calendar reflects what instructors *choose* to publish
as calendar entries, not the dropbox folders that actually carry deadlines — which
makes it a strictly worse source for "what's due soon" than the per-course
`dropbox/folders/` route, and that route is already proven and already deep-linkable.

## The matrix

| Cohort | Window | Status | Events |
|---|---|---|---|
| live (412690, 440703) | now → +90d | 200 | 0 |
| live | Fall 2025 | 200 | 0 |
| live | Spring 2026 | 200 | **3** (announcements) |
| ended Fall 2025 (6 courses) | any of the three | 200 | 0 |
| ended Spring 2026 (5 courses) | any of the three | 200 | 0 |
| all 27 mixed | Spring 2026 | 200 | 3 (same three) |

## Findings worth carrying forward

1. **H1 is neither confirmed nor refuted, but the failure mode is informative.**
   The hypothesis was that a *global* route might escape experiment 6's org-unit gate.
   It does escape the 403 — ended courses return **200, not 403** — but they return
   zero events, so we cannot tell whether events are filtered by access or were never
   there. Either way it yields no usable past-semester data. Experiment 6's conclusion
   stands: real semester data must be captured while a course is live.

2. **A mixed CSV of live + ended org unit ids does not error.** It silently returns
   only what you may see. Useful robustness fact: the app can pass every enrolled
   course id without pre-filtering and without risking a hard failure.

3. **The MCP's field list is incomplete — 7 of 24 fields.** `get-upcoming-due-dates.ts`
   maps `CalendarEventId`, `Title`, `OrgUnitName`, `OrgUnitId`, `StartDateTime`,
   `EndDateTime`, `IsAllDayEvent`. The live payload also carries `EventType`,
   `Description`, `AssociatedEntity`, `IsAssociatedWithEntity`, `GroupId`,
   `LocationName`, `Presenters`, `RecurrenceInfo`, `VisibilityRestrictions`,
   `HasVisibilityRestrictions`, `OrgUnitCode`, `CreatorUserId`, `StartDay`, `EndDay`,
   `IsRecurring`, `LocationId`, and **`CalendarEventViewUrl`**.

4. **`CalendarEventViewUrl` is a real, server-provided deep link** — e.g.
   `{baseUrl}/d2l/le/calendar/{orgUnitId}/event/{eventId}/detailsview`. This is the
   thing experiment 7 looked for and did not find on dropbox folders: a link the API
   hands over directly, no template guessing. It is useless for *assignments* here
   (these events are announcements), but it is the pattern to reach for if a calendar
   feature is ever built, and it confirms D2L does expose view URLs on some entities.

5. **`AssociatedEntity` is the field that would link a calendar event to its
   assignment** — null on all three samples because they are standalone announcements.
   On a course where an instructor publishes assignment deadlines to the calendar, this
   is where the dropbox id would appear, and `IsAssociatedWithEntity` is the flag that
   says whether to look. Untestable until a real semester course is live.

## Consequence for the design

Build the upcoming-assignments feature on **`GET /d2l/api/le/1.96/{ou}/dropbox/folders/`**
(N calls, one per current course — with the currentness filter already shipped, N is
about 5, not 27) and derive click targets with experiment 7's template. The calendar
route is not a shortcut; revisit it only if a real course turns out to publish
assignment deadlines as calendar events with a non-null `AssociatedEntity`.

## Method notes

LE version taken from `GET /d2l/api/versions/` (1.96 confirmed, not assumed).
Response wrapper is `Objects`, not `Items` — the MCP's comment is correct.
`orgUnitIdsCSV` is required; the route will not enumerate courses for you, so it does
not remove the enrollments call. GET-only apart from the token mint; no cookie, CSRF
token, or JWT was printed or stored (JWT length only). Uncommitted.
