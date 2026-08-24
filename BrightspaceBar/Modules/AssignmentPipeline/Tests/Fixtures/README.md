# AssignmentPipeline fixtures

Hand-built from a **live capture** of
`GET /d2l/api/le/1.96/{orgUnitId}/dropbox/folders/`, recorded by
`experiments/experiment-7-assignment-deeplinks/artifacts/approach-a.json` against the real
Purdue tenant on 2026-08-09.

They are hand-built rather than saved verbatim for one reason: experiment 6
proved that **once a course's `Access` window closes the API returns 403**, so
this data becomes permanently unreachable. The only two courses with API access
are administrative shells that run until graduation. If these fixtures are ever
lost they cannot be re-captured from those courses, and no semester course is
reachable until Fall 2026 goes live.

## Which file is faithful, and which is synthetic

| File | Faithful to the capture? |
|---|---|
| `dropbox-folders-440703.json` | **Yes** — the 3 real folders, real ids, real names, real nulls |
| `dropbox-folders-412690.json` | **Yes** — the 1 real folder (`Untitled`) |
| `dropbox-folders-empty.json` | Synthetic: a course with zero assignments |
| `dropbox-folders-malformed.json` | Synthetic: not an array at all |
| `dropbox-folders-with-due-date.json` | **Synthetic** — no reachable assignment has a `DueDate`, but the feature must work when Fall 2026 arrives |
| `dropbox-folders-with-link-attachment.json` | **Synthetic** — every real folder has `LinkAttachments: []`; this one is populated purely to defend against the trap below |

## Field shapes worth knowing (measured, not assumed)

- The response is a **bare JSON array**, not an `{"Items": [...]}` envelope.
- `Availability` is **`null` itself** on every real folder — not an object with
  null members.
- `ActivityId` is a **string** (a `https://ids.brightspace.com/activities/dropbox/...`
  URI), not an integer.
- `TotalFiles`, `UnreadFiles`, `FlaggedFiles`, `TotalUsers`,
  `TotalUsersWithSubmissions`, `TotalUsersWithFeedback` are all **`-1`** for a
  student — they are instructor-facing counters.
- `DueDate`, `GroupTypeId`, `CategoryId`, `GradeItemId`,
  `AllowOnlyUsersWithSpecialAccess`, `NotificationEmail`,
  `CustomAllowableFileTypes` are all `null`.
- `DropboxType: 2`, `SubmissionType: 0`, `CompletionType: 0`,
  `AllowableFileType: 0`, `IsHidden: false`, `IsAnonymous: false`,
  `DisplayInCalendar: false`.
- Only the **key count** of `CustomInstructions` and `Assessment` was captured
  (2 keys each), not the key names. The shapes here are plausible D2L shapes.
  This does not weaken any test: the parser must ignore both fields entirely,
  so their internal names are irrelevant to every assertion.

## The trap

`LinkAttachments[].Href` looks like a link to the assignment and **is not** — it
is an instructor-attached *external* resource (a reading, an outside rubric).
The `brightspace-mcp-server` surfaces this field, which makes it an easy mistake
to inherit. A parser that derives a click target from it sends the user to an
unrelated third-party page. `dropbox-folders-with-link-attachment.json` exists
so a test can forbid it.

The correct click target is derived, never read from the payload:

```
{baseUrl}/d2l/lms/dropbox/user/folder_submit_files.d2l?db={folderId}&grpid=0&ou={orgUnitId}
```

Verified by experiment 7 in a real browser: three distinct folder ids rendered
three distinct assignment pages, each naming its own folder.
