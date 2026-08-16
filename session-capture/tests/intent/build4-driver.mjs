/**
 * BUILD 4, spike C1 — the NODE HALF of the intent test.
 *
 * The Swift suite spawns this the way the app spawns the daemon: `/usr/bin/env
 * node <this file>` with `BSB_ROOT` in the environment and nothing on argv. It
 * then runs the REAL `runRefresh` over the REAL `createFetcher`, with only the
 * HTTP seam faked, and leaves behind a genuine `cache/data.json` +
 * `status.json` for the Swift half to read.
 *
 * Why a driver rather than a fixture file: a committed `data.json` would prove
 * only that Swift can decode a string a human typed. Every interesting failure
 * of this build lives in the JOIN — the daemon's diff rule deciding which
 * column becomes a `gradeOnly` item, and the exact wire words it writes for it.
 * Running the real writer is the only way the Swift assertions are about the
 * daemon at all.
 *
 * STUB MODE. No socket, no browser, no credential: the HTTP seam is
 * `fakeHttp`, the ladder is empty (`rungs: []`), and the session file is the
 * SECRET-marked fake every phase-2 test uses. Nothing here can reach the
 * tenant, so the Swift test that spawns it needs no `BS_LIVE` gate.
 *
 * NOT a `*.test.mjs`, so `npm test` (`node --test "tests/**\/*.test.mjs"`)
 * does not collect it. It has no assertions of its own; its exit code is the
 * daemon's own contract — 0 fresh · 2 needs-login · 1 error — which is exactly
 * what `DaemonRunner` on the other side classifies.
 */
import { mkdirSync } from "node:fs";

import { createFetcher } from "../../src/fetch-engine.mjs";
import { exitCode, runRefresh } from "../../src/orchestrate.mjs";
import { resolvePaths } from "../../src/paths.mjs";
import { FIXED_ISO } from "../helpers.mjs";
import {
  enrollmentsFor,
  fakeHttp,
  fixture,
  fixtureJson,
  json,
  raw,
  writeSessionFile,
} from "../phase2-helpers.mjs";

// An unset BSB_ROOT resolves to the REAL install, and the first thing below is
// a fake session.json over David's credentials followed by a fake cache over
// his courses. Refusing is not defensive programming for an impossible case —
// it is one forgotten environment variable away.
if (!process.env.BSB_ROOT) {
  console.error(
    "build4-driver refuses to run without BSB_ROOT: it writes a fake session and a fake cache."
  );
  process.exit(1);
}

// ---------------------------------------------------------------------------
// THE DESIGNED WORLD — one course, and the story of a released midterm.
//
// 412690 is the real Purdue Civics shell, and the probe that motivated this
// build is its gradebook: columns pointing at quizzes the student's own
// `quizzes/` call is not allowed to see. Its content fixture is the tenant's
// own recording; the only value invented on top of it is a DueDate, which the
// heatmap half of the intent test needs in order to have a filled cell to
// compare "no cell" against.
//
// The gradebook is synthesized, as it must be — no live gradebook was ever
// recorded off this tenant.
// ---------------------------------------------------------------------------

const COURSE = 412690;

/** The quiz "Exam 1" is graded on. Absent from `quizzes/` — released, gated. */
const HIDDEN_QUIZ = 907_733;

/** The recorded dropbox folder (id 648911, "Untitled"), given a deadline. */
const RECORDED_FOLDER = fixtureJson("dropbox-folders-412690.json")[0];
const FOLDERS = [{ ...RECORDED_FOLDER, DueDate: "2026-03-04T04:59:00.000Z" }];

/**
 * Four columns: one heads-up row and three ways of not being one. Ordered so
 * the row that must survive is neither first nor last — "take the first
 * student-scored column" yields the matched one and fails.
 */
const GRADEBOOK = [
  // Matched: `ToolItemId` is the folder the content route just returned, so the
  // student already has a clickable row for it.
  {
    Id: 814_771,
    Name: "Untitled",
    GradeObjectTypeId: 1,
    AssociatedTool: { ToolId: 6, ToolItemId: 648_911 },
    MaxPoints: 10,
  },
  // A category — the gradebook's own bookkeeping, not work.
  { Id: 812_004, Name: "Homework Category", GradeObjectTypeId: 5, AssociatedTool: null },
  // THE ROW. Student-scored, linked, and linked to something nothing else can
  // see: the only trace this exam leaves anywhere in the app.
  {
    Id: 812_311,
    Name: "Exam 1",
    GradeObjectTypeId: 1,
    AssociatedTool: { ToolId: 19, ToolItemId: HIDDEN_QUIZ },
    MaxPoints: 100,
    IsBonus: false,
  },
  // A final grade. Unlinked, and so a heads-up row under a rule that tested
  // linkage alone — in every course, which is how a section becomes noise.
  { Id: 813_902, Name: "Final Calculated Grade", GradeObjectTypeId: 6, AssociatedTool: null },
];

const routes = {
  enrollments: enrollmentsFor([COURSE]),
  dropbox: { [COURSE]: json(FOLDERS) },
  // Empty on purpose, twice over: it is why the exam's quiz is unfetchable, and
  // it leaves exactly two populated sections, which is the labelling rule's
  // boundary.
  quizzes: { [COURSE]: raw(fixture("quizzes-empty.json")) },
  grades: { [COURSE]: json(GRADEBOOK) },
};

// ---------------------------------------------------------------------------
// The run — the production orchestrator and the production fetcher.
// ---------------------------------------------------------------------------

const paths = resolvePaths();
mkdirSync(paths.root, { recursive: true });
writeSessionFile(paths);

const status = await runRefresh({
  paths,
  // Empty: the session on disk works, so no rung is ever attempted. A ladder
  // here could only ever reach for a browser.
  rungs: [],
  fetcher: createFetcher({ http: fakeHttp(routes) }),
  clock: () => new Date(FIXED_ISO),
  allowFullLogin: false,
  log: (message) => console.error(message),
});

console.error(`${status.state} (rung: ${status.rungUsed})${status.error ? ` — ${status.error}` : ""}`);
process.exit(exitCode(status));
