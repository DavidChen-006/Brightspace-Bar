# Read routes an agent can use through `bsb api`

Every route below is a GET on the Brightspace (D2L Valence) API, called
through the app's own session. `bsb api` accepts:

- a full path: `/d2l/api/le/1.96/1631476/content/toc`
- a shorthand: `le:1631476/content/toc` → `/d2l/api/le/<LE version>/…`,
  `lp:users/whoami` → `/d2l/api/lp/<LP version>/…`
- a full URL on the session's own tenant

Anything outside `/d2l/api/` or on another host is refused. The versions
(`le` 1.96, `lp` 1.62) are the ones the app itself uses on this tenant;
`GET /d2l/api/versions/` lists what the tenant supports. `ID` below is the
course's org-unit id from `bsb courses`.

Answers are JSON unless noted. `bsb api … --out FILE` saves the bytes instead
of printing. A `403` on a course from a past term is normal — ended courses
refuse content access. `404` is a wrong id or a tool the course does not use.

## Who and what

| Route | Returns |
|---|---|
| `lp:users/whoami` | The student's identifier and display name. |
| `lp:enrollments/myenrollments/?orgUnitTypeId=3&isActive=true` | Every course enrollment (`Items[].OrgUnit`, `Access`). `bsb courses --all` is the cached version. |
| `/d2l/api/versions/` | Supported API versions per product. |

## Course content

| Route | Returns |
|---|---|
| `le:ID/content/toc` | The table of contents: nested `Modules[]`, each with `Topics[]` (`TopicId`, `Title`, `TypeIdentifier` File/Link/…, `Url`, `EndDateTime`, `IsHidden`). `bsb content` flattens this. |
| `le:ID/content/root/` | Root modules with descriptions (`Description.Text`). |
| `le:ID/content/modules/MODULEID/structure/` | One module's children. |
| `le:ID/content/topics/TOPICID` | One topic's metadata (`DueDate`, `Description`, `Url`, `TopicType`). |
| `le:ID/content/topics/TOPICID/file` | The file behind a File topic — bytes, with `Content-Disposition`. `bsb fetch` uses this. |
| `le:ID/overview` | `Description.Text` — the course overview; on many courses this IS the syllabus. `404` when the course has none. |
| `le:ID/overview/attachment` | The overview's attached file, when there is one (`404` otherwise). |

## Work

| Route | Returns |
|---|---|
| `le:ID/dropbox/folders/` | Assignment folders (`Id`, `Name`, `DueDate`, `TotalFiles`, `Availability`). A bare array. Cached as `bsb work` kind `assignment`. |
| `le:ID/quizzes/` | `{Objects: [{QuizId, Name, DueDate, StartDate, EndDate, IsActive}]}`. Cached as kind `quiz`. |
| `le:ID/checklists/` | `{Objects: [{ChecklistId, Name, Description}]}`. |
| `le:ID/calendar/events/?startDateTime=ISO&endDateTime=ISO` | Calendar events in the window (`Title`, `StartDateTime`, `EndDateTime`, `Description`) — instructors often put exam times here. |
| `le:ID/calendar/events/myEvents/?startDateTime=ISO&endDateTime=ISO` | The student's own view of the same window. |

## Grades

| Route | Returns |
|---|---|
| `le:ID/grades/` | The gradebook's columns (`Id`, `Name`, `GradeObjectTypeId`, `AssociatedTool`). Bare array. |
| `le:ID/grades/values/myGradeValues/` | The student's values per column (`GradeObjectName`, `DisplayedGrade`, `PointsNumerator`, `PointsDenominator`). `bsb grades` tabulates this. |
| `le:ID/grades/final/values/myGradeValue` | The final grade, if released. |

## Communication

| Route | Returns |
|---|---|
| `le:ID/news/` | Announcements (`Id`, `Title`, `Body.Text`, `StartDate`, `IsPublished`). Bare array, newest first. `bsb announcements` is the cached top ten. |
| `le:ID/discussions/forums/` | Discussion forums (`ForumId`, `Name`). Then `…/forums/FORUMID/topics/` and `…/topics/TOPICID/posts/`. |

## Reading a syllabus that is a file

`bsb syllabus --course ID --out DIR` already downloads every topic whose title
or module says "syllabus". For anything else, find the topic id in
`bsb content` and `bsb fetch` it. PDFs: read them with your document tools.
`.docx`: `unzip -p FILE.docx word/document.xml | sed 's/<[^>]*>/ /g'` is
readable enough to extract dates from.
