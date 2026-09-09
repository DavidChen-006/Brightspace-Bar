# The items you can write

`bsb add` is the only write. It appends to `manual-items.json` in the app's
root (`~/Library/Application Support/BrightspaceBar`, or `$BSB_ROOT`) — the
same file the "Add assignment / quiz / test" forms in the menu write. The app
watches that file and repaints the heatmap the moment a new one lands.

## A draft

One item, as you hand it to `bsb add --batch`:

```json
{ "courseId": 1631476, "kind": "test", "title": "Midterm 1", "due": "2026-10-06", "link": "https://…" }
```

| Field | Rule |
|---|---|
| `courseId` | Integer. Must be one of the student's enrollments (`bsb courses --all`). |
| `kind` | `assignment`, `quiz` or `test`. Accepted aliases: `exam`, `midterm`, `final` → `test`; `homework`, `hw`, `project` → `assignment`. Anything else (e.g. `lab`) is refused — decide. |
| `title` (or `name`) | Non-empty. Shown verbatim in the menu. Keep it short: the popup is narrow. |
| `due` | `YYYY-MM-DD` → 23:59 that day, local zone. `YYYY-MM-DD HH:MM` (space or `T`) → that local time. Full ISO-8601 with `Z` or an offset → that instant. Nothing else is accepted, nothing is guessed. |
| `link` | Optional. Where a click on the item goes. Defaults to the course home. Blank is refused. |

## Validation is all-or-nothing

A batch is checked entirely before anything is written. One bad row → exit
`1`, nothing written, every problem listed as `item N: …`. Fix and re-run.

Exact duplicates — same course, same kind, same title (case-insensitive),
same due instant — are skipped and reported, so a second run of the same
import adds nothing. `--allow-duplicate` overrides that for the rare real case.

## What is written

```json
{
  "courseId": 1631476,
  "due": "2026-10-07T03:59:00Z",
  "id": "C17A9177-BE73-43B4-843F-04CD67E3AC8C",
  "kind": "test",
  "link": "https://purdue.brightspace.com/d2l/home/1631476",
  "name": "Midterm 1"
}
```

`id` is minted by the CLI and is what `bsb remove` takes. `due` is whole
seconds, UTC. The shape is exactly what the app's `ManualItemStore` decodes;
one entry it cannot decode would quarantine the whole file, which is why the
CLI refuses before writing rather than after.

## Undo

- `bsb items --course ID --json` → the ids.
- `bsb remove ID [ID…]` → those items.
- `bsb remove --course ID --all` → everything hand-added in that course.

Removal is a rewrite of the file; the heatmap updates immediately.

## What not to add

- Things Brightspace already lists (`bsb work --course ID`): the bar shows
  them from the cache already.
- Undated things. Every item needs a due date; that is what a square is.
- Lectures, readings without a deliverable, office hours. The heatmap is work
  owed, not a timetable.
