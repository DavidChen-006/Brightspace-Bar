# Experiment 7 — Can we deep-link to a single assignment?

## The question

Clicking a course row in BrightspaceBar already works: `{baseUrl}/d2l/home/{orgUnitId}`
opens that course. The next thin vertical is **"show me my upcoming assignments"** as a
nested menu, and every row in it needs a click target.

> Given an assignment we learned about through the API, can we produce a URL that lands
> the user directly on **that assignment's page** — skipping home → course → hunt for it?

If yes, the feature is a nested `NSMenu` with a `URL` per row and nothing else. If no,
the UX has to change (deep link to the assignments *list* instead, or drop click-through).
So this experiment gates the design, and is worth running before any GUI work.

## Targets

Experiment 6 proved every ended course returns 403 on content routes, so only two org
units are reachable:

| Org unit | Name | Known surface |
|---|---|---|
| 440703 | Scholarly Project Milestones | 3 dropbox folders — primary target |
| 412690 | Purdue Civics Knowledge Test | 1 dropbox folder, quiz-style content |

Both are probed. A template that works on only one is a weaker result than one that
works on both, and the README must say which.

## Approaches

Four, cheapest first. We do not know which will work, so all are tried and each gets a
recorded outcome — including the ones that fail, because "the API does not hand us a
link" is itself a finding worth writing down.

### (A) Does the API simply give us a URL?

Dump the **complete** field list of a dropbox folder object from
`GET /d2l/api/le/1.96/{ou}/dropbox/folders/`, plus content topics from
`GET /d2l/api/le/1.96/{ou}/content/root/`. D2L content topics are known to carry a `Url`
field. Look for anything link-shaped: `Url`, `Href`, `Link`, `QuickLink`.

Trap to avoid: `LinkAttachments[].Href` on a dropbox folder is an **instructor-attached
external resource** (a reading, a rubric on some other site), *not* a link to the
assignment. Confusing the two would produce a menu that opens random third-party pages.

### (B) Harvest ground truth from the rendered UI

The most reliable source for "what is the canonical link" is Brightspace itself. Load the
course's assignments list in Playwright with the live session and scrape the real `href`
attributes the UI renders for each assignment. Then compare those hrefs against the ids
the API returned — if the href embeds the same folder id, the link is **derivable** and
no browser is needed at runtime. That mapping is the finding we want.

### (C) Test constructed URL patterns

Candidate shapes to verify (not assume):

- `/d2l/lms/dropbox/user/folder_submit_files.d2l?db={folderId}&grpid=0&ou={orgUnitId}`
- `/d2l/le/{orgUnitId}/dropbox/user/folder_submit_files?db={folderId}`
- `/d2l/lms/dropbox/dropbox.d2l?ou={orgUnitId}` (list, not per-assignment)
- `/d2l/le/content/{orgUnitId}/viewContent/{topicId}/View`

### (D) Has `brightspace-mcp-server` already solved it?

Read-only inspection of its working tools for URL construction. Harvest knowledge, copy
no code.

## Verification — the actual point

**A URL returning HTTP 200 is not proof.** Brightspace answers 200 while serving a login
page, a permission error, or a bounce to course home. So every candidate is opened in
Playwright with the real session and judged on the **rendered page**:

| Outcome | Means |
|---|---|
| `WORKS` | the assignment's own name is on the page, and it is not the course home |
| `REDIRECTS_TO_LOGIN` | bounced to SSO — the URL shape is unauthenticated or wrong |
| `WRONG_PAGE` | loads something real, but not that assignment (e.g. course home) |
| `ERROR` | 404 / 403 / server error |

Each candidate gets a screenshot in `artifacts/` as evidence. A finding with no
screenshot is an assertion, not a result.

## Verdict criteria

- **`API_PROVIDED`** — the API returns a usable link directly. Best case: no guessing.
- **`DERIVABLE`** — a template built purely from API-available ids lands on the right
  page. Green light; state the template and name its inputs.
- **`BROWSER_ONLY`** — links exist but only obtainable by scraping a rendered page.
  Workable but expensive; say what it would cost at runtime.
- **`NOT_POSSIBLE`** — no reliable per-assignment link. State the fallback UX.

## Rules

- GET / read-only navigation only. The **single** permitted non-GET anywhere is the token
  mint `POST /d2l/lp/auth/oauth2/token`.
- Nothing is submitted. No file uploads, no submit buttons, no form posts — this probes a
  dropbox, and an accidental submission would be a real side effect on a real course.
- Session read from `~/Library/Application Support/BrightspaceBar/session.json`. The
  cookie, CSRF token, and JWT are **never** printed, logged, or copied — JWT length only.
- A dead session is detected by the `sessionExpired=1` marker in a 200 response, not by
  status code (measured in experiments 2–4).
- Sequential requests, 30 s timeouts, no hammering.
- Screenshots may contain personal course data. The folder stays **uncommitted**.
