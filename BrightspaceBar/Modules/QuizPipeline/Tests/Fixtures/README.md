# QuizPipeline fixtures

Hand-built from a **live probe** of `GET /d2l/api/le/1.96/{orgUnitId}/quizzes/`
against the real Purdue tenant on 2026-08-10.

Hand-built rather than saved verbatim for the same reason as the assignment
fixtures: experiment 6 proved that once a course's `Access` window closes the API
answers **403**, and the only two reachable courses are administrative shells. If
these are lost they cannot be re-captured until a semester course goes live.

## Which file is faithful, and which is synthetic

| File | Faithful? |
|---|---|
| `quizzes-412690.json` | **Ids, names, `IsActive`, and the null `DueDate`s are real** — the 3 genuine Civics quizzes. See the caveat below about the other fields. |
| `quizzes-440703.json` | **Same** — the 1 genuine Scholarly Project quiz. |
| `quizzes-empty.json` | Synthetic: a course with no quizzes. |
| `quizzes-bare-array.json` | Synthetic: the *assignment* shape (a bare array) served on the quiz route. |
| `quizzes-malformed.json` | Synthetic: a `problem+json` error body. |
| `quizzes-session-expired.html` | Synthetic: the HTTP-200 login stub a dead cookie produces. |
| `quizzes-with-due-date.json` | **Synthetic** — no reachable quiz has a `DueDate`, but the feature must work when Fall 2026 arrives. Includes both ISO-8601 variants and one unparseable date. |
| `quizzes-inactive.json` | **Synthetic** — every real quiz is `IsActive: true`. |
| `quizzes-missing-name.json`, `quizzes-missing-id.json` | Synthetic: the two fatal shapes. |

## Measured facts (these ARE verified)

- **The envelope is `{"Objects": [...], "Next": ...}`** — *not* a bare array. This
  is the single most important difference from `dropbox/folders`, which returns a
  bare array. A decoder shared between the two would silently yield zero quizzes,
  and zero-on-success means `AssignmentStore` *replaces* good data with nothing.
- The 4 real quizzes:

  | orgUnitId | QuizId | Name | DueDate | IsActive |
  |---|---|---|---|---|
  | 412690 | 619243 | Honor Pledge | null | true |
  | 412690 | 619244 | Practice Quiz - Requires Respondus LockDown Browser | null | true |
  | 412690 | 790340 | Welcome Quiz | null | true |
  | 440703 | 476481 | Module 1 Completion Quiz - What Is Research? | null | true |

- A quiz object carries **37 keys**:
  `ActivityId, AllowHints, AllowOnlyUsersWithSpecialAccess, AttemptsAllowed,
  AutoExportToGrades, CalcTypeId, CategoryId, DeductionPercentage, Description,
  DisablePagerAndAlerts, DisableRightClick, DisplayInCalendar, DueDate, EndDate,
  Footer, GradeItemId, Header, HideQuestionPoints, Instructions, IsActive,
  IsAutoSetGraded, IsRetakeIncorrectOnly, IsSingleSession, IsSynchronous,
  LateSubmissionInfo, Name, NotificationEmail, PagingTypeId, Password,
  PreventMovingBackwards, QuizId, RestrictIPAddressRange, Shuffle, SortOrder,
  StartDate, SubmissionGracePeriod, SubmissionTimeLimit`

  Note there is **no `TimeLimit` field**. `brightspace-mcp-server`'s TypeScript
  interface declares one, along with only 12 of the 37 keys — it is wrong, and it
  is the third time inference from that repo would have produced a broken decoder
  (`Availability` and `ActivityId` were the first two). Nothing in this directory
  is derived from it.

## The caveat on non-load-bearing fields

Only `QuizId`, `Name`, `DueDate` and `IsActive` were captured **with their values**.
The other 33 keys were captured as *names only*, so their shapes here — including
`AttemptsAllowed`, `SubmissionTimeLimit`, `Description`, `Header`, `Footer`,
`Instructions`, `LateSubmissionInfo` — are plausible D2L shapes, not measured ones.

This does not weaken any test, and the reason is a design rule rather than luck:
**the parser must ignore all 33.** `QuizParserTests` asserts that explicitly, so
the fixtures' internal shapes are irrelevant to every assertion — and a parser that
started reading them would be relying on unverified data, which is the failure mode
the assertion exists to prevent.

## The click target

Derived, never read from the payload:

```
{baseUrl}/d2l/lms/quizzing/user/quiz_summary.d2l?qi={QuizId}&ou={orgUnitId}
```

Verified in a real browser against all four quizzes above: each rendered a page
whose `<h1>` named its own quiz (`"Summary - Honor Pledge"`, `"Summary - Welcome
Quiz"`, …). Note the parameter is **`qi=`**, not the assignments' `db=`, and there
is no `grpid`. `quiz_submissions.d2l?qi=…&ou=…` also resolves and shows past
attempts; the summary page is the destination for "I owe this".
