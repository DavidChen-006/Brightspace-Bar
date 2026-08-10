# Experiment 7 — assignment deep links

## Verdict: `DERIVABLE` — green light

A per-assignment URL **can** be built purely from ids the API already gives us, and it
lands on the real assignment page. The answer did not come from the API handing us a link
(it doesn't) but from asking Brightspace's own UI what link *it* uses, then proving the
`db` parameter in that href is exactly the `Id` the dropbox API returns. Verified in a
real browser on the live session for **both** reachable courses: each link opens a fully
authenticated page whose own heading is that assignment's name, with instructions and the
submission UI — and critically, three different folder ids open three different pages, so
this is a genuine deep link and not a bounce to a shared list. No runtime browser is
needed; the app can compute the URL and hand it to `NSWorkspace`.

## The answer

```
{baseUrl}/d2l/lms/dropbox/user/folder_submit_files.d2l?db={folderId}&grpid=0&ou={orgUnitId}
```

| Input | Where it comes from | Already in the app? |
|---|---|---|
| `baseUrl` | `session.baseUrl` | yes |
| `orgUnitId` | `myenrollments` → `OrgUnit.Id` | yes — it's `Course.id` |
| `folderId` | `GET /d2l/api/le/1.96/{ou}/dropbox/folders/` → `folder.Id` | new call, one per course |

The UI's own href also carries `isprv=` and `bp=0`; both proved **optional** — the shorter
form above works identically. `grpid=0` means "not a group assignment"; group folders may
need a real group id, which these two courses cannot exercise.

## Approach results

| # | Approach | Outcome |
|---|---|---|
| A | API hands us a link | **Failed** — no such field exists |
| B | Harvest hrefs from rendered UI | **Succeeded** — this produced the answer |
| C | Test constructed patterns | **Succeeded** for one of four shapes |
| D | Has the MCP server solved it? | **No** — it constructs no deep links |

### A — the API does not give you a link

A dropbox folder has 28 fields (`Id`, `Name`, `DueDate`, `ActivityId`, `Availability`,
`SubmissionType`, …). Exactly one is link-shaped, and it is a **trap**:

- `LinkAttachments[].Href` is an **instructor-attached external resource** — a reading, a
  rubric hosted elsewhere. Treating it as "the assignment link" would build a menu that
  opens unrelated third-party pages. The MCP server surfaces this field, which is easy to
  mistake for a solution.
- Content topics are a separate story: `content/root/` returns no `Url` at all (only `Id`,
  `Title`, `ShortTitle`, `Type`, `LastModifiedDate`). The per-topic detail route
  `content/topics/{id}` *does* carry `Url`, but it is a **raw file path** like
  `/content/enforced/440703-scholarly_project_milestones/Information Before You Begin.html`
   — the underlying file, not a Brightspace page.

### B — the UI knows, so ask it

Loading `/d2l/lms/dropbox/user/folders_list.d2l?ou={ou}` and scraping anchors gave six
dropbox hrefs for the three-assignment course, two for the one-assignment course:

```
/d2l/lms/dropbox/user/folder_submit_files.d2l?db=445296&grpid=0&isprv=&bp=0&ou=440703
/d2l/lms/dropbox/user/folder_submit_files.d2l?db=445297&grpid=0&isprv=&bp=0&ou=440703
/d2l/lms/dropbox/user/folder_submit_files.d2l?db=529524&grpid=0&isprv=&bp=0&ou=440703
```

Those `db` values are precisely the folder `Id`s the API returned — **the mapping is
`folder.Id` → `db`**, which is what makes the link derivable rather than scrape-only.

### C — constructed candidates

| Candidate | HTTP | Outcome |
|---|---|---|
| `/d2l/lms/dropbox/user/folder_submit_files.d2l?db&grpid&ou` | 200 | **the answer** |
| `/d2l/le/{ou}/dropbox/user/folder_submit_files?db` | 404 | wrong shape |
| `/d2l/lms/dropbox/dropbox.d2l?ou` | 200 | assignments **list**, not per-assignment |
| `/d2l/lms/dropbox/user/folders_list.d2l?ou` | 200 | assignments **list**, not per-assignment |

## The verification that mattered

The first classifier scored a candidate `WORKS` when the assignment's name appeared on the
rendered page — and by that rule **the two list pages also passed**, because a list
contains every assignment's name. That check could not distinguish "landed on the
assignment" from "landed on a page that mentions it," so it was replaced.

The property that actually matters is **distinctness**, tested the same way the app's menu
tests prove clicks route correctly ("never a neighbour"):

| Page | Rendered heading | Names its own folder? |
|---|---|---|
| assignments list | `Assignments` | — (baseline) |
| `db=445296` | `Upload your CITI Certificate to Complete Module 2` | ✅ |
| `db=445297` | `Report on your PURC Experience.` | ✅ |
| `db=529524` | `Getting Started on Scholarly Project Ideation` | ✅ |
| `db=648911` (other course) | `Untitled` | ✅ |

All three headings differ from each other and from the list page, and none redirected to
login. Screenshots in `artifacts/` are the evidence — `D-440703-445297.png` shows the
authenticated page with breadcrumb `Assignments › Report on your PURC Experience.`, the
instructions, and the submission form.

**Caveat, stated plainly:** 412690 has a single folder, so its distinctness check is
trivially satisfied. The real proof rests on the three-folder course.

## What this means for the next vertical

The nested-menu design is unblocked: `Course → assignments submenu → click → that
assignment's page`. One extra API call per course (`dropbox/folders/`) supplies both the
row text (`Name`, `DueDate`) and the click target (`Id`). Same shape as the existing course
rows, so `MenuTranslation` gains a derivation and the GUI gains a submenu — no new
capability, no browser at runtime.

Two things to carry forward:

- **Group assignments are untested.** `grpid=0` is hardcoded; a group folder
  (`GroupTypeId` non-null) may need a real group id. Neither reachable course has one.
- **These two courses are the only live ones.** Experiment 6 proved ended courses 403, so
  the template's behaviour on a normal semester course is inferred from the URL shape, not
  measured. Worth re-confirming once Fall 2026 enrollment lands — and worth capturing a
  real course's `dropbox/folders/` payload as a fixture *while it is live*, since that data
  becomes unreachable the moment the term ends.

## Files

| Path | What |
|---|---|
| `SPEC.md` | question, approaches, verdict criteria — written before probing |
| `src/probe_api.py` | Approach A — full field dump of folders and content |
| `src/probe-browser.mjs` | Approaches B and C — harvest + candidate testing |
| `src/probe-distinctness.mjs` | the decisive per-folder distinctness check |
| `artifacts/findings.json` | consolidated result matrix |
| `artifacts/*.png` | 16 screenshots, one per navigation, as evidence |

Read-only throughout: the only non-GET anywhere was the token mint. Submit buttons were
rendered but never clicked. No cookie, CSRF token, or JWT was printed or stored (JWT
length 812 logged). Session stayed live. **Uncommitted**, and `node_modules` is a symlink
to experiment 1's — delete the folder freely.
