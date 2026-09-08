/**
 * `bsb` — the agent CLI, tested through a real process against a seeded temp
 * BSB_ROOT. The logic is pinned function by function in agent-*.test.mjs;
 * what a process adds is the surface an agent actually touches: argv, exit
 * codes, JSON on stdout, refusals on stderr, and the one write it may make.
 *
 * No network, no browser: the only commands here are the cache-and-file ones.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { SAMPLE_DATA, run, tempPaths } from "./helpers.mjs";

/** A root the daemon "already refreshed": the sample cache plus a current course. */
function seededRoot(t) {
  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  const courses = [
    ...SAMPLE_DATA.courses,
    {
      id: 1631476, name: "Fall 2026 CS 25200-LE1 LEC", code: "wl.202710.CS.25200.LE1", role: "Student",
      isActive: true, homeUrl: null, startDate: "2026-08-24T04:00:00.000Z", endDate: "2027-01-03T04:59:00.000Z",
    },
    {
      id: 1095315, name: "Fall 2024 CS 18000", code: "wl.202510.CS.18000.BLK", role: "Student",
      isActive: true, homeUrl: null, startDate: "2024-08-14T04:00:00.000Z", endDate: "2024-12-29T04:59:00.000Z",
    },
  ];
  writeFileSync(paths.dataFile, JSON.stringify({ fetchedAt: "2026-09-08T18:00:00.000Z", ...SAMPLE_DATA, courses }));
  writeFileSync(paths.statusFile, JSON.stringify({
    state: "fresh", rungUsed: "none", lastAttemptAt: "2026-09-08T18:00:00.000Z",
    lastSuccessAt: "2026-09-08T18:00:00.000Z", lastFullLoginAttemptAt: null, error: null,
  }));
  return paths;
}

/** The CLI, in a fixed zone so local dates are the same on every machine. */
const bsb = (paths, args, extra = {}) =>
  run("node", ["src/bsb.mjs", ...args], {
    ...extra,
    env: { ...process.env, BSB_ROOT: paths.root, TZ: "America/New_York", ...(extra.env ?? {}) },
  });

const itemsFile = (paths) => path.join(paths.root, "manual-items.json");

// ── help and refusals ───────────────────────────────────────────────────────

test("--help documents every command and touches no files", async (t) => {
  const paths = tempPaths(t);
  const result = await bsb(paths, ["--help"]);
  assert.equal(result.code, 0);
  for (const word of ["courses", "work", "items", "status", "add", "remove", "--json", "--batch", "BSB_ROOT"]) {
    assert.match(result.stdout, new RegExp(word), `help never mentions ${word}`);
  }
  assert.deepEqual(readdirSync(paths.root), []);
});

test("no command is a usage error; an unknown command names itself", async (t) => {
  const paths = tempPaths(t);
  assert.equal((await bsb(paths, [])).code, 1);
  const unknown = await bsb(paths, ["frobnicate"]);
  assert.equal(unknown.code, 1);
  assert.match(unknown.stderr, /unknown command "frobnicate"/);
});

test("an unknown option is refused with usage, not silently ignored", async (t) => {
  const paths = seededRoot(t);
  const result = await bsb(paths, ["courses", "--everything"]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /--everything/);
  assert.match(result.stderr, /Usage/);
});

test("reads on a never-refreshed root say so and point at bsb refresh", async (t) => {
  const paths = tempPaths(t);
  for (const args of [["courses"], ["work", "--course", "1"], ["add", "--course", "1", "--kind", "quiz", "--title", "q", "--due", "2026-10-06"]]) {
    const result = await bsb(paths, args);
    assert.equal(result.code, 1, args.join(" "));
    assert.match(result.stderr, /bsb refresh/);
  }
  assert.deepEqual(readdirSync(paths.root), []);
});

// ── reads ───────────────────────────────────────────────────────────────────

test("courses lists the current ones, with the menu's label; --all lists every enrollment", async (t) => {
  const paths = seededRoot(t);
  const current = await bsb(paths, ["courses", "--json"]);
  assert.equal(current.code, 0, current.stderr);
  const listed = JSON.parse(current.stdout);
  assert.deepEqual(listed.map((c) => c.id), [412690, 1631476]);
  assert.equal(listed[1].label, "CS 25200");
  assert.equal(listed[0].label, null);

  const all = await bsb(paths, ["courses", "--all", "--json"]);
  assert.deepEqual(JSON.parse(all.stdout).map((c) => c.id), [412690, 1631476, 1095315]);

  const human = await bsb(paths, ["courses"]);
  assert.match(human.stdout, /^ID\s+LABEL\s+NAME/);
  assert.match(human.stdout, /1631476\s+CS 25200\s+Fall 2026 CS 25200-LE1 LEC/);
  assert.doesNotMatch(human.stdout, /1095315/);
});

test("work lists what the cache says is due in one course", async (t) => {
  const paths = seededRoot(t);
  const result = await bsb(paths, ["work", "--course", "412690", "--json"]);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), SAMPLE_DATA.assignments[412690]);
  const empty = await bsb(paths, ["work", "--course", "1631476"]);
  assert.equal(empty.code, 0);
  assert.match(empty.stdout, /nothing due/);
  const unknown = await bsb(paths, ["work", "--course", "7"]);
  assert.equal(unknown.code, 1);
  assert.match(unknown.stderr, /not one of your enrollments/);
  const missing = await bsb(paths, ["work"]);
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /--course ID is required/);
});

test("status reports the root, the cache age, the last run and the item count", async (t) => {
  const paths = seededRoot(t);
  const result = await bsb(paths, ["status", "--json"]);
  assert.equal(result.code, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.equal(report.root, paths.root);
  assert.deepEqual(report.cache, { fetchedAt: "2026-09-08T18:00:00.000Z", courses: 3, current: 2 });
  assert.equal(report.lastRun.state, "fresh");
  assert.equal(report.manualItems, 0);
  const human = await bsb(paths, ["status"]);
  assert.match(human.stdout, /cache\s+3 enrollments, 2 current/);
  assert.match(human.stdout, /last run\s+fresh via rung none/);
});

// ── the write ───────────────────────────────────────────────────────────────

test("add writes one item the Swift store will decode, and reports it", async (t) => {
  const paths = seededRoot(t);
  const result = await bsb(paths, [
    "add", "--course", "1631476", "--kind", "exam", "--title", "Midterm 1", "--due", "2026-10-06", "--json",
  ]);
  assert.equal(result.code, 0, result.stderr);
  const { added, skipped, total } = JSON.parse(result.stdout);
  assert.equal(total, 1);
  assert.deepEqual(skipped, []);
  assert.equal(added.length, 1);
  const stored = JSON.parse(readFileSync(itemsFile(paths), "utf8"));
  assert.deepEqual(stored, added);
  assert.deepEqual({ ...stored[0], id: "X" }, {
    courseId: 1631476,
    due: "2026-10-07T03:59:00Z",   // 23:59 New York on the 6th, whole seconds, Z
    id: "X",
    kind: "test",
    link: "https://purdue.brightspace.com/d2l/home/1631476",
    name: "Midterm 1",
  });
  assert.deepEqual(readdirSync(paths.root).sort(), ["cache", "manual-items.json"]);
});

test("add refuses a bad draft with every problem listed, and writes nothing", async (t) => {
  const paths = seededRoot(t);
  const result = await bsb(paths, ["add", "--course", "7", "--kind", "lab", "--due", "never"]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /nothing was written/);
  assert.match(result.stderr, /course 7 is not one of your enrollments/);
  assert.match(result.stderr, /kind must be one of/);
  assert.match(result.stderr, /title is required/);
  assert.match(result.stderr, /due must be/);
  assert.deepEqual(readdirSync(paths.root), ["cache"]);
});

test("add --batch validates the whole file before writing any of it", async (t) => {
  const paths = seededRoot(t);
  const batch = path.join(paths.root, "syllabus.json");
  writeFileSync(batch, JSON.stringify([
    { courseId: 1631476, kind: "quiz", title: "Quiz 1", due: "2026-09-15" },
    { courseId: 1631476, kind: "lab", title: "Lab 1", due: "2026-09-16" },
  ]));
  const refused = await bsb(paths, ["add", "--batch", batch]);
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, /item 1: kind must be one of/);
  assert.doesNotMatch(refused.stderr, /item 0/);
  assert.deepEqual(readdirSync(paths.root).sort(), ["cache", "syllabus.json"]);

  writeFileSync(batch, JSON.stringify([
    { courseId: 1631476, kind: "quiz", title: "Quiz 1", due: "2026-09-15" },
    { courseId: 1631476, kind: "homework", name: "HW 1", due: "2026-09-16 17:00", link: "https://x.test/hw1" },
  ]));
  const written = await bsb(paths, ["add", "--batch", batch, "--json"]);
  assert.equal(written.code, 0, written.stderr);
  const stored = JSON.parse(readFileSync(itemsFile(paths), "utf8"));
  assert.deepEqual(stored.map((i) => [i.kind, i.name, i.due, i.link]), [
    ["quiz", "Quiz 1", "2026-09-16T03:59:00Z", "https://purdue.brightspace.com/d2l/home/1631476"],
    ["assignment", "HW 1", "2026-09-16T21:00:00Z", "https://x.test/hw1"],
  ]);
});

test("add --batch - reads the array from stdin", async (t) => {
  const paths = seededRoot(t);
  const { execFile } = await import("node:child_process");
  const result = await new Promise((resolve) => {
    const child = execFile("node", ["src/bsb.mjs", "add", "--batch", "-", "--json"], {
      cwd: path.resolve(new URL("..", import.meta.url).pathname),
      env: { ...process.env, BSB_ROOT: paths.root, TZ: "America/New_York" },
    }, (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr }));
    child.stdin.end(JSON.stringify([{ courseId: 412690, kind: "test", title: "Final", due: "2026-12-14T15:00:00Z" }]));
  });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).added[0].name, "Final");
});

test("a second identical add is skipped, not doubled", async (t) => {
  const paths = seededRoot(t);
  const args = ["add", "--course", "1631476", "--kind", "quiz", "--title", "Quiz 1", "--due", "2026-09-15"];
  assert.equal((await bsb(paths, args)).code, 0);
  const again = await bsb(paths, [...args, "--json"]);
  assert.equal(again.code, 0);
  const { added, skipped, total } = JSON.parse(again.stdout);
  assert.deepEqual(added, []);
  assert.equal(skipped.length, 1);
  assert.equal(total, 1);
  const forced = await bsb(paths, [...args, "--allow-duplicate", "--json"]);
  assert.equal(JSON.parse(forced.stdout).total, 2);
});

test("items lists what was added, filtered by course; remove takes it back", async (t) => {
  const paths = seededRoot(t);
  await bsb(paths, ["add", "--course", "1631476", "--kind", "quiz", "--title", "Quiz 1", "--due", "2026-09-15"]);
  await bsb(paths, ["add", "--course", "412690", "--kind", "test", "--title", "Civics", "--due", "2026-09-20"]);
  const all = JSON.parse((await bsb(paths, ["items", "--json"])).stdout);
  assert.equal(all.length, 2);
  const one = JSON.parse((await bsb(paths, ["items", "--course", "412690", "--json"])).stdout);
  assert.deepEqual(one.map((i) => i.name), ["Civics"]);

  const removed = await bsb(paths, ["remove", one[0].id, "--json"]);
  assert.equal(removed.code, 0, removed.stderr);
  assert.deepEqual(JSON.parse(removed.stdout).removed.map((i) => i.name), ["Civics"]);
  assert.equal(JSON.parse((await bsb(paths, ["items", "--json"])).stdout).length, 1);

  const gone = await bsb(paths, ["remove", one[0].id]);
  assert.equal(gone.code, 1);
  assert.match(gone.stderr, /no item with id/);

  const byCourse = await bsb(paths, ["remove", "--course", "1631476", "--all", "--json"]);
  assert.equal(byCourse.code, 0, byCourse.stderr);
  assert.equal(JSON.parse(byCourse.stdout).total, 0);
  const guard = await bsb(paths, ["remove", "--course", "1631476"]);
  assert.equal(guard.code, 1);
  assert.match(guard.stderr, /needs --all/);
});

test("a corrupt manual-items.json is reported and left untouched by every write", async (t) => {
  const paths = seededRoot(t);
  writeFileSync(itemsFile(paths), "{ not json [");
  const add = await bsb(paths, ["add", "--course", "1631476", "--kind", "quiz", "--title", "Q", "--due", "2026-09-15"]);
  assert.equal(add.code, 1);
  assert.match(add.stderr, /not JSON/);
  const status = await bsb(paths, ["status", "--json"]);
  assert.match(JSON.parse(status.stdout).manualItemsProblem, /not JSON/);
  assert.equal(readFileSync(itemsFile(paths), "utf8"), "{ not json [");
});
