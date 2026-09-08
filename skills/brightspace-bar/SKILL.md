---
name: brightspace-bar
description: Read a student's Brightspace (D2L) courses, syllabi, content files, announcements and grades through the Brightspace Bar menu-bar app's own session, and add assignments, quizzes and tests to the app's calendar heatmap. Use when the user mentions Brightspace, D2L, a syllabus, due dates, a course schedule, "what's due", grades, or wants dates from a syllabus put on their Brightspace Bar calendar. Uses the `bsb` CLI; never writes to Brightspace.
license: MIT
compatibility: macOS with Brightspace Bar checked out and set up (`make setup`, `make start`); node >= 22 on PATH
metadata:
  repo: https://github.com/DavidChen-006/Brightspace-Bar
---

# Brightspace Bar for agents

Brightspace Bar is a macOS menu-bar app that shows a student's Brightspace
(D2L) work as a heatmap per course. It is deliberately deterministic: it only
shows what the D2L API reports as work. You are not so limited — you can read
a syllabus — and `bsb` is how you hand what you find to the bar, and how you
read everything the bar can see.

**One rule above all: `bsb` never writes to Brightspace.** Every Brightspace
call is a GET, structurally. The only thing you can write is the student's own
item list in the app. Treat that as their calendar: show them what you intend
to add and get a yes before `bsb add`.

## The command

`scripts/bsb` (next to this file) runs the CLI. It finds the Brightspace Bar
checkout on its own — through the symlink this skill was installed as, or the
path `make setup` recorded — and `./bsb` at the repo root is the same thing.
If it says it cannot find the checkout, ask the user where the repo is and
set `BSB_REPO=/that/path`. Every command takes `--json` for machine output;
use it. Exit codes: `0` done · `1` refused, nothing written · `2` session
expired (see *Session*).

Start every task with:

```sh
scripts/bsb status          # is there a cache? when was it written? how many items?
scripts/bsb courses         # the current courses with their numeric ids
```

Course ids (e.g. `1631476`) are what every other command takes. `--all` lists
past enrollments too.

## Reading

| Need | Command | Notes |
|---|---|---|
| What Brightspace says is due | `bsb work --course ID` | From the cache — assignments, quizzes, gradebook heads-up rows. Check this before adding items so you do not duplicate them. |
| Announcements | `bsb announcements --course ID` | From the cache, newest first. |
| The syllabus | `bsb syllabus --course ID --out DIR` | Prints the course overview text (often the syllabus itself) and downloads every content topic named like a syllabus into `DIR`. Read the files with your document tools (PDF, .docx, .txt). |
| Everything in the course | `bsb content --course ID` | The table of contents: topic ids, File/Link, module path. |
| One file | `bsb fetch --course ID --topic TOPICID --out DIR` | Downloads a File topic under the server's filename. `--stdout` streams it. |
| Course overview | `bsb overview --course ID` | The text alone. |
| Grades | `bsb grades --course ID` | What the student's grades page shows. |
| Anything else | `bsb api le:ID/…` or `bsb api lp:…` | Any read route. See [references/endpoints.md](references/endpoints.md). |

A `.docx` with no converter at hand: `unzip -p FILE.docx word/document.xml | sed 's/<[^>]*>/ /g'`
gives readable text.

## Writing to the bar

Items are `assignment`, `quiz` or `test` (also accepted: `exam`, `midterm`,
`final` → test; `homework`, `hw`, `project` → assignment). Each needs a course
id, a title and a due date. `due` is `YYYY-MM-DD` (23:59 local — Brightspace's
own default), `"YYYY-MM-DD HH:MM"` (local), or an ISO-8601 instant. The link
defaults to the course home.

```sh
scripts/bsb add --course 1631476 --kind test --title "Midterm 1" --due 2026-10-06
```

For more than one, write a JSON array and add it as a whole — validated as a
whole, written as a whole, so one bad row means nothing is written and every
problem is listed:

```sh
scripts/bsb add --batch items.json --json     # or --batch - to read stdin
scripts/bsb items --course 1631476            # what is there now
scripts/bsb remove ID [ID…]                   # undo by id
scripts/bsb remove --course 1631476 --all     # undo a whole import
```

Exact duplicates (same course, kind, title, due) are skipped, so re-running an
import is safe. Items appear in the menu-bar heatmap the moment the file lands
— no relaunch, no click. The contract is in [references/items.md](references/items.md).

## The recipe: put a syllabus on the calendar

1. `bsb courses --json` → pick the course, note its id and end date (the term
   tells you the year for dates written like "Oct 6").
2. `bsb syllabus --course ID --out ./syllabus` → read the overview text and
   the downloaded files.
3. Extract every dated deliverable: homework, projects, quizzes, exams. Decide
   the kind. Resolve relative dates ("Week 5 Friday") against the course's start
   date and say when you guessed.
4. `bsb work --course ID --json` → drop what Brightspace already lists (same
   title and day), so the bar does not show it twice.
5. Write the batch file, print it as a table for the user, and ask for a yes.
6. `bsb add --batch items.json --json` → report what was added and skipped.
7. Tell them how to undo: `bsb remove --course ID --all`.

## Session

Reads from Brightspace need a live session. Exit code `2` with "session is
expired" means it is not. `bsb refresh` runs the app's login ladder; it can put
a verification number on the menu-bar icon that the student must match on
their phone. **Tell the user before running it** and do not run it repeatedly.
The app also refreshes on its own every 30 minutes. Cache-only commands
(`courses`, `work`, `announcements`, `items`, `status`, `add`, `remove`) work
without a session.

## Never

- Never send anything but a GET to Brightspace. `bsb` cannot; do not go around
  it with curl. There is no supported write to the LMS.
- Never read or print `session.json`, `credentials.json` or the `profile/`
  directory under the app's root. They are credentials.
- Never add items without showing the user the list first.
- Never treat `--all` enrollments from past terms as current.
