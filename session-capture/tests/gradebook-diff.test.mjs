/**
 * The gradebook diff — rung 2 v1. A third per-course route, `grades/`, whose
 * student-scored columns that match NO fetched item become `gradeOnly` items:
 * the "Heads up" section, name only, no date, linking to the course gradebook.
 *
 * Priorities these tests defend (everything else was culled):
 *
 *  1. MEMBERSHIP. The diff rule is the whole feature and it is the one thing a
 *     plausible implementation gets wrong. Too loose and every assignment shows
 *     up twice, once as itself and once as its own grade column; too tight —
 *     "unlinked only" — and the case worth building this for disappears, because
 *     a hidden midterm's column IS linked, just linked to a quiz the content
 *     routes are not allowed to see. Both directions are pinned below.
 *  2. FAILURE ISOLATION. `grades/` is a NEW route bolted onto a shipped path.
 *     It may cost its own rows and nothing else: not the assignments, not the
 *     quizzes, not the course's presence in the map. Course-unknown stays
 *     "dropbox AND quizzes both failed"; the gradebook never votes.
 *
 * Every isolation test below carries a second, healthy course. That control is
 * what makes "only the heads-up rows were lost" observable at all: on its own,
 * "this course grew no gradeOnly items" is also exactly what a fetcher that
 * never learned the route reports.
 *
 * Scope: small. HTTP is injected; the only real I/O is a temp BSB_ROOT.
 *
 * The grade payloads here are SYNTHESIZED, unlike the dropbox and quiz fixtures
 * they are diffed against — no live gradebook was ever recorded off this tenant
 * (25 of 27 courses 403 until Fall). They are shaped to the documented
 * GradeObject and to the probe's finding: the Civics shell's columns point at
 * quizzes rung 1 cannot see. The ids they link to are the real fixtures' own.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { createFetcher } from "../src/fetch-engine.mjs";
import { recorder, tempPaths } from "./helpers.mjs";
import {
  JWT,
  MARKS,
  TEST_BASE,
  enrollmentsFor,
  fakeHttp,
  fixture,
  headerOf,
  json,
  raw,
  requestsFor,
  status,
  writeSessionFile,
} from "./phase2-helpers.mjs";

/** The whole act, in one line — the same world builder the fetcher tests use. */
async function fetchWith(t, { routes = {}, log = () => {} } = {}) {
  const paths = tempPaths(t);
  writeSessionFile(paths);
  const http = fakeHttp(routes);
  const result = await createFetcher({ http }).fetch({ paths, log });
  return { result, http };
}

// ---------------------------------------------------------------------------
// The two courses. 412690 is the one under test; 440703 is the control whose
// gradebook always works, so a lost row is distinguishable from an absent
// feature. Both content fixtures are the live tenant's own recordings.
// ---------------------------------------------------------------------------

const COURSE = 412690;
const CONTROL = 440703;

const gradebookUrl = (courseId) => `${TEST_BASE}/d2l/lms/grades/my_grades/main.d2l?ou=${courseId}`;

/** 412690's recorded content: dropbox folder 648911, quizzes 619243/619244/790340. */
const courseContent = {
  dropbox: { [COURSE]: raw(fixture("dropbox-folders-412690.json")) },
  quizzes: { [COURSE]: raw(fixture("quizzes-412690.json")) },
};

/** The control's gradebook: one unlinked column, and so one heads-up row. */
const CONTROL_COLUMN = { Id: 991001, Name: "Peer Review Credit", GradeObjectTypeId: 1, AssociatedTool: null };
const CONTROL_HEADS_UP = {
  id: 991001,
  title: "Peer Review Credit",
  dueDate: null,
  kind: "gradeOnly",
  url: gradebookUrl(CONTROL),
};
const controlWorld = {
  dropbox: { [CONTROL]: raw(fixture("dropbox-folders-440703.json")) },
  quizzes: { [CONTROL]: raw(fixture("quizzes-440703.json")) },
  grades: { [CONTROL]: json([CONTROL_COLUMN]) },
};

/** Both courses at once, with the course under test's gradebook scripted. */
const withControl = (gradesUnderTest) => ({
  enrollments: enrollmentsFor([COURSE, CONTROL]),
  dropbox: { ...courseContent.dropbox, ...controlWorld.dropbox },
  quizzes: { ...courseContent.quizzes, ...controlWorld.quizzes },
  grades: { [COURSE]: gradesUnderTest, ...controlWorld.grades },
});

// ---------------------------------------------------------------------------
// The columns. Extra D2L fields ride along on purpose: none of them may reach
// the cache.
// ---------------------------------------------------------------------------

/** Linked — to a quiz the content routes never returned. The case worth building. */
const HIDDEN_EXAM = {
  Id: 990001,
  Name: "Midterm Exam",
  GradeObjectTypeId: 1,
  AssociatedTool: { ToolId: 19, ToolItemId: 888888 },
  MaxPoints: 100,
  IsBonus: false,
};

/** Unlinked — a column an instructor scores by hand. */
const PARTICIPATION = {
  Id: 990002,
  Name: "Class Participation",
  GradeObjectTypeId: 1,
  AssociatedTool: null,
  MaxPoints: 50,
  ShortName: "Partic.",
};

/** Linked to dropbox folder 648911, which the content route DID return. */
const LINKED_TO_FOLDER = {
  Id: 990003,
  Name: "Untitled",
  GradeObjectTypeId: 1,
  AssociatedTool: { ToolId: 6, ToolItemId: 648911 },
  MaxPoints: 10,
};

/** Linked to quiz 619243, which the content route DID return. */
const LINKED_TO_QUIZ = {
  Id: 990004,
  Name: "Honor Pledge",
  GradeObjectTypeId: 2,
  AssociatedTool: { ToolId: 19, ToolItemId: 619243 },
  MaxPoints: 1,
};

const column = (id, name, typeId) => ({ Id: id, Name: name, GradeObjectTypeId: typeId, AssociatedTool: null });

/** Only the heads-up rows, in the order the course's list carries them. */
const headsUp = (items = []) => items.filter((item) => item.kind === "gradeOnly");
const headsUpIds = (items) => headsUp(items).map((item) => item.id);

// ---------------------------------------------------------------------------
// The request — a third route per course, on the same bearer.
// ---------------------------------------------------------------------------

test("asks each enrolled course for its gradebook", async (t) => {
  // Arrange / Act
  const { http } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([COURSE, CONTROL]) } });

  // Assert — the ids, not just the count: a course quietly skipped is a heads-up
  // section that never fills for the course that needed it.
  assert.deepStrictEqual(
    requestsFor(http, MARKS.grades).map((request) => request.url),
    [`${TEST_BASE}/d2l/api/le/1.96/412690/grades/`, `${TEST_BASE}/d2l/api/le/1.96/440703/grades/`],
  );
});

test("carries the bearer onto the gradebook route", async (t) => {
  // Arrange / Act
  const { http } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([COURSE]) } });

  // Assert
  assert.deepStrictEqual(
    requestsFor(http, MARKS.grades).map((request) => headerOf(request, "authorization")),
    [`Bearer ${JWT}`],
  );
});

// ---------------------------------------------------------------------------
// Membership — student-scored AND unmatched.
// ---------------------------------------------------------------------------

test("maps an unlinked student-scored column onto a gradeOnly item", async (t) => {
  // Arrange — a course that owes nothing anyone can click, whose gradebook says
  // otherwise. Every field of the contract is read off the plan, not computed:
  // the title is the column's Name and the date is ALWAYS null in v1.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([COURSE]),
      dropbox: { [COURSE]: raw(fixture("dropbox-folders-empty.json")) },
      quizzes: { [COURSE]: raw(fixture("quizzes-empty.json")) },
      grades: { [COURSE]: json([PARTICIPATION]) },
    },
  });

  // Assert
  assert.deepStrictEqual(result.data.assignments[COURSE], [
    {
      id: 990002,
      title: "Class Participation",
      dueDate: null,
      kind: "gradeOnly",
      url: `${TEST_BASE}/d2l/lms/grades/my_grades/main.d2l?ou=412690`,
    },
  ]);
});

test("keeps a column whose linked activity the content routes never returned", async (t) => {
  // Arrange — THE case: a released midterm's grade column points at a quiz the
  // student's own quizzes/ call cannot see. "Unlinked only" would drop it, and
  // dropping it is the difference between a warning and a surprise.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([COURSE]),
      ...courseContent,
      grades: { [COURSE]: json([HIDDEN_EXAM]) },
    },
  });

  // Assert
  assert.deepStrictEqual(headsUp(result.data.assignments[COURSE]), [
    { id: 990001, title: "Midterm Exam", dueDate: null, kind: "gradeOnly", url: gradebookUrl(COURSE) },
  ]);
});

test("drops a column already served as an assignment", async (t) => {
  // Arrange — the unlinked column rides along as the control: without it, "no
  // heads-up rows" is also what a fetcher with no gradebook at all reports.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([COURSE]),
      ...courseContent,
      grades: { [COURSE]: json([LINKED_TO_FOLDER, PARTICIPATION]) },
    },
  });

  // Assert — folder 648911 is already a clickable row; a second copy of it under
  // "Heads up" is the menu telling the student the same thing twice.
  assert.deepStrictEqual(headsUpIds(result.data.assignments[COURSE]), [990002]);
});

test("drops a column already served as a quiz", async (t) => {
  // Arrange — the join is against BOTH content routes, not just the dropbox one.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([COURSE]),
      ...courseContent,
      grades: { [COURSE]: json([LINKED_TO_QUIZ, PARTICIPATION]) },
    },
  });

  // Assert
  assert.deepStrictEqual(headsUpIds(result.data.assignments[COURSE]), [990002]);
});

test("keeps every student-scored column type", async (t) => {
  // Arrange — numeric, passfail, selectbox, text: the four a student is scored
  // on, all unlinked.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([COURSE]),
      ...courseContent,
      grades: {
        [COURSE]: json([
          column(990101, "Numeric Column", 1),
          column(990102, "Pass/Fail Column", 2),
          column(990103, "Selectbox Column", 3),
          column(990104, "Text Column", 4),
        ]),
      },
    },
  });

  // Assert
  assert.deepStrictEqual(headsUpIds(result.data.assignments[COURSE]), [990101, 990102, 990103, 990104]);
});

test("drops categories, final grades and formulas however unlinked they are", async (t) => {
  // Arrange — these are the gradebook's own bookkeeping, not work. A "Final
  // Calculated Grade" row under "Heads up" is visible nonsense, and it would be
  // in EVERY course, which is how a good section becomes noise nobody reads.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([COURSE]),
      ...courseContent,
      grades: {
        [COURSE]: json([
          column(990201, "Homework Category", 5),
          column(990202, "Final Calculated Grade", 6),
          column(990203, "Final Adjusted Grade", 7),
          column(990204, "Weighted Formula", 8),
          PARTICIPATION,
        ]),
      },
    },
  });

  // Assert
  assert.deepStrictEqual(headsUpIds(result.data.assignments[COURSE]), [990002]);
});

test("lists the heads-up columns after a course's assignments and quizzes", async (t) => {
  // Arrange — order is pinned because Swift's MenuModel is Equatable and drives
  // a skip-rebuild: a list whose order depends on which request finished first
  // makes identical data compare unequal every refresh.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([COURSE]),
      ...courseContent,
      grades: { [COURSE]: json([HIDDEN_EXAM, PARTICIPATION]) },
    },
  });

  // Assert
  assert.deepStrictEqual(
    result.data.assignments[COURSE].map((item) => [item.kind, item.id]),
    [
      ["assignment", 648911],
      ["quiz", 619243],
      ["quiz", 619244],
      ["quiz", 790340],
      ["gradeOnly", 990001],
      ["gradeOnly", 990002],
    ],
  );
});

test("adds nothing to a course whose every column is already an item", async (t) => {
  // Arrange — the no-regression case: a healthy course whose gradebook agrees
  // with its content routes must come out byte for byte as it does today. The
  // control course proves the diff was running while it added nothing.
  const { result } = await fetchWith(t, {
    routes: withControl(json([LINKED_TO_FOLDER, LINKED_TO_QUIZ])),
  });

  // Assert
  assert.deepStrictEqual(
    result.data.assignments[COURSE].map((item) => [item.kind, item.id]),
    [
      ["assignment", 648911],
      ["quiz", 619243],
      ["quiz", 619244],
      ["quiz", 790340],
    ],
  );
  assert.deepStrictEqual(headsUp(result.data.assignments[CONTROL]), [CONTROL_HEADS_UP]);
});

// ---------------------------------------------------------------------------
// Failure isolation — the gradebook may cost its own rows and nothing else.
// ---------------------------------------------------------------------------

test("keeps the assignments and quizzes when the gradebook never answered", async (t) => {
  // Arrange — the seam rejects: offline, DNS, TLS, timeout.
  const { result } = await fetchWith(t, { routes: withControl(new Error("socket hang up")) });

  // Assert
  assert.deepStrictEqual(
    result.data.assignments[COURSE].map((item) => item.id),
    [648911, 619243, 619244, 790340],
  );
  assert.deepStrictEqual(headsUp(result.data.assignments[COURSE]), []);
  assert.deepStrictEqual(headsUp(result.data.assignments[CONTROL]), [CONTROL_HEADS_UP]);
});

test("keeps the assignments and quizzes when the gradebook answers 403", async (t) => {
  // Arrange — 403 is the expected steady state for last term's courses, and a
  // gradebook can be shut long before its content routes are.
  const { result } = await fetchWith(t, { routes: withControl(status(403, "forbidden")) });

  // Assert
  assert.deepStrictEqual(
    result.data.assignments[COURSE].map((item) => item.id),
    [648911, 619243, 619244, 790340],
  );
  assert.deepStrictEqual(headsUp(result.data.assignments[COURSE]), []);
  assert.deepStrictEqual(headsUp(result.data.assignments[CONTROL]), [CONTROL_HEADS_UP]);
});

test("keeps the assignments and quizzes when the gradebook body is not an array", async (t) => {
  // Arrange — the route answers a bare array; an envelope on it is a shape
  // mismatch, and reading it as zero columns would report success with nothing
  // in it. A maintenance page arrives the same way.
  const { result } = await fetchWith(t, { routes: withControl(json({ Objects: [PARTICIPATION] })) });

  // Assert
  assert.deepStrictEqual(
    result.data.assignments[COURSE].map((item) => item.id),
    [648911, 619243, 619244, 790340],
  );
  assert.deepStrictEqual(headsUp(result.data.assignments[COURSE]), []);
  assert.deepStrictEqual(headsUp(result.data.assignments[CONTROL]), [CONTROL_HEADS_UP]);
});

test("drops the whole gradebook when a column it would keep has no id", async (t) => {
  // Arrange — same asymmetry the folder parser has: without an Id the row can
  // never be clicked, and serving the rest of a handful is indistinguishable
  // from the columns having been deleted.
  const { result } = await fetchWith(t, {
    routes: withControl(json([PARTICIPATION, { Name: "No Id Here", GradeObjectTypeId: 1, AssociatedTool: null }])),
  });

  // Assert
  assert.deepStrictEqual(
    result.data.assignments[COURSE].map((item) => item.id),
    [648911, 619243, 619244, 790340],
  );
  assert.deepStrictEqual(headsUp(result.data.assignments[COURSE]), []);
  assert.deepStrictEqual(headsUp(result.data.assignments[CONTROL]), [CONTROL_HEADS_UP]);
});

test("drops the whole gradebook when a column it would keep has no name", async (t) => {
  // Arrange — a nameless row is a blank line in the menu.
  const { result } = await fetchWith(t, {
    routes: withControl(json([PARTICIPATION, { Id: 990009, GradeObjectTypeId: 1, AssociatedTool: null }])),
  });

  // Assert
  assert.deepStrictEqual(headsUp(result.data.assignments[COURSE]), []);
  assert.deepStrictEqual(
    result.data.assignments[COURSE].map((item) => item.id),
    [648911, 619243, 619244, 790340],
  );
  assert.deepStrictEqual(headsUp(result.data.assignments[CONTROL]), [CONTROL_HEADS_UP]);
});

test("survives a malformed column the membership rule already excluded", async (t) => {
  // Arrange — categories and calculated columns are dropped before anything is
  // read off them, so a nameless category costs nothing. Validating the whole
  // payload first would hand one odd bookkeeping row a veto over the section.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([COURSE]),
      ...courseContent,
      grades: { [COURSE]: json([{ GradeObjectTypeId: 5 }, PARTICIPATION]) },
    },
  });

  // Assert
  assert.deepStrictEqual(headsUpIds(result.data.assignments[COURSE]), [990002]);
});

test("still omits a course whose content routes both failed, gradebook or not", async (t) => {
  // Arrange — the course-unknown rule is unchanged: a course is dropped from the
  // map only when BOTH content routes failed, and the gradebook never votes. A
  // course present with heads-up rows ALONE would claim it owes no assignments,
  // which is what the missing key exists to avoid saying.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([COURSE, CONTROL]),
      dropbox: { [COURSE]: status(403, "forbidden"), ...controlWorld.dropbox },
      quizzes: { [COURSE]: status(403, "forbidden"), ...controlWorld.quizzes },
      grades: { [COURSE]: json([PARTICIPATION]), ...controlWorld.grades },
    },
  });

  // Assert
  assert.deepStrictEqual(Object.keys(result.data.assignments), [String(CONTROL)]);
  assert.deepStrictEqual(headsUp(result.data.assignments[CONTROL]), [CONTROL_HEADS_UP]);
});

test("tells the log which course's gradebook it could not read", async (t) => {
  // Arrange — a section silently missing from one course is a bug nobody can
  // see: the course still looks complete, because the rows it lost were the
  // ones nothing else knows about.
  const journal = recorder();

  // Act
  await fetchWith(t, { log: journal.log, routes: withControl(status(500, "server error")) });

  // Assert
  assert.match(journal.text(), /412690/);
  assert.match(journal.text(), /grade/i);
});
