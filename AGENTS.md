# For agents working in this repository

This is Brightspace Bar: a macOS menu-bar app for Brightspace (D2L), plus a
Node daemon that owns the login session, plus an agent surface.

**If the task is about the user's courses, syllabus, due dates, grades, or
putting items on their calendar, use the `brightspace` skill**
(`skills/brightspace/SKILL.md`). It teaches the `bsb` CLI (`./bsb --help`),
which reads Brightspace through the app's own session and can add
assignments, quizzes and tests to the menu-bar heatmap. It never writes to
Brightspace.

If the task is about the code: read `docs/architecture.md` first, then
`CONTRIBUTING.md` for the module rules and the D7/D8/D9 invariants. Tests are
`make test` (Swift) and `cd session-capture && npm test` (daemon + CLI).
