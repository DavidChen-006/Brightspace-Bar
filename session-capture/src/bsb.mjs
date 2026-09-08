#!/usr/bin/env node
/**
 * `bsb` — Brightspace Bar for agents (and for the terminal).
 *
 * The app is deterministic on purpose: it shows the handful of things D2L's
 * API reports as work, and nothing it cannot verify. An AI agent has no such
 * limit — it can read a syllabus — but until now it had no way to hand what it
 * found to the bar. This CLI is that way. Two halves, one rule each:
 *
 *   READ  — the cache the daemon already wrote (`courses`, `work`, `status`),
 *           and, through the daemon's own session, the Brightspace API
 *           (`api`, `content`, `fetch`, …): GET only, structurally. There is
 *           no code path here that sends any other verb to the tenant.
 *   WRITE — `$BSB_ROOT/manual-items.json`, the student's own items, the same
 *           file the add-form in the menu writes. Never `cache/` (the daemon's),
 *           never `session.json` (a credential), never Brightspace.
 *
 * Thin by design, like `refresh.mjs`: argv in, an exit code out, everything
 * decidable without a process tested in `src/agent/`.
 *
 * Exit codes: 0 done · 1 refused (usage, validation, a missing cache) ·
 * 2 the session is expired (run `bsb refresh`).
 */
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { resolvePaths } from "./paths.mjs";
import {
  currentCourses, readCache, readStatus, tenantBaseUrl, workOf,
} from "./agent/cache.mjs";
import { ageOf, courseLabel, json, localStamp, table } from "./agent/format.mjs";
import {
  KINDS, addItems, draftToItem, manualItemsFile, readManualItems, removeItems,
} from "./agent/manual-items.mjs";

const USAGE = `Usage: bsb <command> [options]

Reads (from the cache the daemon wrote — no network):
  courses [--all]                the courses you are in now (--all: every enrollment)
  work --course ID               what Brightspace reports due in one course
  items [--course ID]            the items added by hand or by an agent
  status                         when the cache was written and how the last run went

Writes (to the bar only — never to Brightspace):
  add --course ID --kind KIND --title TEXT --due WHEN [--link URL]
                                 one item; appears in the menu immediately
  add --batch FILE|-             many items from a JSON array of
                                 {courseId, kind, title, due, link?} (- reads stdin);
                                 validated as a whole, written as a whole
  remove ID [ID…]                remove items by id
  remove --course ID --all       remove every hand-added item of one course

Options:
  --json                         machine output on stdout (every command)
  --allow-duplicate              add an item identical to one already there
  --help                         this text

KIND is one of ${KINDS.join(", ")} (exam/midterm/final → test; homework/hw/project → assignment).
WHEN is YYYY-MM-DD (23:59 local), "YYYY-MM-DD HH:MM" (local), or an ISO-8601 instant.
BSB_ROOT selects the install (default ~/Library/Application Support/BrightspaceBar).

Exit codes: 0 done · 1 refused (nothing was written) · 2 session expired (run: bsb refresh)`;

const argv = process.argv.slice(2);
const command = argv[0];
if (!command || command === "help" || command === "--help" || command === "-h") {
  process.stdout.write(`${USAGE}\n`);
  process.exit(command ? 0 : 1);
}

const commands = { courses, work, items, add, remove, status };
if (!Object.hasOwn(commands, command)) {
  process.stderr.write(`bsb: unknown command "${command}"\n\n${USAGE}\n`);
  process.exit(1);
}

const world = {
  paths: resolvePaths(),
  now: new Date(),
  out: (text) => process.stdout.write(text),
  err: (text) => process.stderr.write(text.endsWith("\n") ? text : `${text}\n`),
};

let code;
try {
  code = await commands[command](argv.slice(1), world);
} catch (error) {
  // A refusal is a sentence; anything else is a bug and says so.
  world.err(`bsb ${command}: ${error?.message ?? error}`);
  code = 1;
}
process.exit(code);

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

async function courses(args, { paths, now, out, err }) {
  const { values } = options(args, { all: { type: "boolean" } });
  const cache = readCache(paths);
  if (!cache.ok) return refuse(err, cache.detail);
  const listed = values.all ? cache.data.courses : currentCourses(cache.data.courses, now);
  if (values.json) {
    out(json(listed.map((course) => ({ ...course, label: courseLabel(course.code) }))));
    return 0;
  }
  if (listed.length === 0) {
    out(values.all ? "No enrollments in the cache.\n" : "No current courses (try --all for every enrollment).\n");
    return 0;
  }
  out(table(
    ["ID", "LABEL", "NAME", "ENDS"],
    listed.map((course) => [
      course.id, courseLabel(course.code) ?? "", course.name, (course.endDate ?? "").slice(0, 10),
    ]),
  ));
  return 0;
}

async function work(args, { paths, out, err }) {
  const { values } = options(args, { course: { type: "string" } });
  const courseId = requireCourseId(values.course, err);
  if (courseId === null) return 1;
  const cache = readCache(paths);
  if (!cache.ok) return refuse(err, cache.detail);
  if (!cache.data.courses.some((course) => course.id === courseId)) {
    return refuse(err, `course ${courseId} is not one of your enrollments (run \`bsb courses --all\`)`);
  }
  const listed = workOf(cache.data, courseId);
  if (values.json) {
    out(json(listed));
    return 0;
  }
  if (listed.length === 0) {
    out("Brightspace reports nothing due in this course (or the daemon could not read it).\n");
    return 0;
  }
  out(table(
    ["KIND", "DUE (local)", "TITLE", "ID"],
    listed.map((item) => [item.kind, localStamp(item.dueDate) || "—", item.title, item.id]),
  ));
  return 0;
}

async function items(args, { paths, out, err }) {
  const { values } = options(args, { course: { type: "string" } });
  const courseId = values.course === undefined ? null : requireCourseId(values.course, err);
  if (values.course !== undefined && courseId === null) return 1;
  const stored = readManualItems(manualItemsFile(paths));
  if (!stored.ok) return refuse(err, stored.detail);
  const listed = courseId === null
    ? stored.items
    : stored.items.filter((item) => item.courseId === courseId);
  if (values.json) {
    out(json(listed));
    return 0;
  }
  if (listed.length === 0) {
    out("No hand-added items.\n");
    return 0;
  }
  out(table(
    ["COURSE", "KIND", "DUE (local)", "TITLE", "ID"],
    listed.map((item) => [item.courseId, item.kind, localStamp(item.due), item.name, item.id]),
  ));
  return 0;
}

async function status(args, { paths, now, out }) {
  const { values } = options(args, {});
  const cache = readCache(paths);
  const last = readStatus(paths);
  const stored = readManualItems(manualItemsFile(paths));
  const report = {
    root: paths.root,
    cache: cache.ok
      ? {
        fetchedAt: cache.data.fetchedAt,
        courses: cache.data.courses.length,
        current: currentCourses(cache.data.courses, now).length,
      }
      : null,
    lastRun: last,
    manualItems: stored.ok ? stored.items.length : null,
    manualItemsProblem: stored.ok ? null : stored.detail,
  };
  if (values.json) {
    out(json(report));
    return 0;
  }
  const lines = [`root       ${paths.root}`];
  lines.push(cache.ok
    ? `cache      ${cache.data.courses.length} enrollments, ${report.cache.current} current — fetched ${ageOf(cache.data.fetchedAt, now)}`
    : `cache      none (${cache.detail})`);
  lines.push(last
    ? `last run   ${last.state ?? "?"} via rung ${last.rungUsed ?? "?"}, ${ageOf(last.lastAttemptAt, now)}${last.error ? ` — ${last.error}` : ""}`
    : "last run   none recorded");
  lines.push(stored.ok
    ? `items      ${stored.items.length} hand-added`
    : `items      unreadable — ${stored.detail}`);
  out(`${lines.join("\n")}\n`);
  return 0;
}

// ---------------------------------------------------------------------------
// Writes — to manual-items.json, and to nothing else
// ---------------------------------------------------------------------------

async function add(args, { paths, out, err }) {
  const { values } = options(args, {
    course: { type: "string" },
    kind: { type: "string" },
    title: { type: "string" },
    due: { type: "string" },
    link: { type: "string" },
    batch: { type: "string" },
    "allow-duplicate": { type: "boolean" },
  });
  const drafts = values.batch !== undefined
    ? readBatch(values.batch, err)
    : [{ courseId: values.course, kind: values.kind, title: values.title, due: values.due, link: values.link }];
  if (drafts === null) return 1;
  if (drafts.length === 0) return refuse(err, "the batch is empty — nothing to add");

  const cache = readCache(paths);
  if (!cache.ok) return refuse(err, cache.detail);
  const baseUrl = tenantBaseUrl(paths);

  // Validate EVERYTHING before writing ANYTHING: a batch of fourteen syllabus
  // dates with one typo lands as zero items and fourteen sentences, not as
  // thirteen items and a silent hole.
  const built = [];
  const problems = [];
  drafts.forEach((draft, index) => {
    const result = draftToItem(draft, { courses: cache.data.courses, baseUrl });
    if (result.ok) built.push(result.item);
    else problems.push(...result.errors.map((error) => (drafts.length > 1 ? `item ${index}: ${error}` : error)));
  });
  if (problems.length > 0) {
    err(`bsb add: refused — nothing was written\n${problems.map((p) => `  - ${p}`).join("\n")}`);
    return 1;
  }

  const written = addItems(manualItemsFile(paths), built, { allowDuplicate: values["allow-duplicate"] });
  if (!written.ok) return refuse(err, written.detail);
  if (values.json) {
    out(json({ added: written.added, skipped: written.skipped, total: written.all.length }));
    return 0;
  }
  for (const item of written.added) {
    out(`added   ${item.kind.padEnd(10)} ${localStamp(item.due)}  ${item.name}  (${item.id})\n`);
  }
  for (const item of written.skipped) {
    out(`skipped ${item.kind.padEnd(10)} ${localStamp(item.due)}  ${item.name}  — already there (--allow-duplicate to add anyway)\n`);
  }
  out(`${written.added.length} added, ${written.skipped.length} skipped; the menu updates on its own.\n`);
  return 0;
}

async function remove(args, { paths, out, err }) {
  const { values, positionals } = options(args, {
    course: { type: "string" },
    all: { type: "boolean" },
  });
  let courseId = null;
  if (values.course !== undefined) {
    courseId = requireCourseId(values.course, err);
    if (courseId === null) return 1;
    if (!values.all) return refuse(err, "remove --course needs --all (it removes every hand-added item of that course)");
  }
  if (courseId === null && positionals.length === 0) {
    return refuse(err, "remove needs at least one item id, or --course ID --all");
  }
  const result = removeItems(manualItemsFile(paths), { ids: positionals, courseId });
  if (!result.ok) return refuse(err, result.detail);
  if (values.json) {
    out(json({ removed: result.removed, missing: result.missing, total: result.all.length }));
    return result.missing.length > 0 && result.removed.length === 0 ? 1 : 0;
  }
  for (const item of result.removed) {
    out(`removed ${item.kind.padEnd(10)} ${localStamp(item.due)}  ${item.name}  (${item.id})\n`);
  }
  for (const id of result.missing) err(`bsb remove: no item with id ${id}`);
  out(`${result.removed.length} removed; the menu updates on its own.\n`);
  return result.missing.length > 0 && result.removed.length === 0 ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/** parseArgs with the one option every command shares; a typo is a refusal with usage. */
function options(args, spec) {
  try {
    return parseArgs({
      args,
      options: { ...spec, json: { type: "boolean" } },
      allowPositionals: true,
      strict: true,
    });
  } catch (error) {
    throw new Error(`${error.message}\n\n${USAGE}`);
  }
}

function requireCourseId(raw, err) {
  if (raw === undefined) {
    refuse(err, "--course ID is required (run `bsb courses` for the ids)");
    return null;
  }
  const id = Number(raw);
  if (!Number.isInteger(id)) {
    refuse(err, `--course must be an integer id (got ${JSON.stringify(raw)})`);
    return null;
  }
  return id;
}

/** `--batch FILE` or `--batch -`: a JSON array of drafts, or null after explaining why not. */
function readBatch(source, err) {
  let raw;
  try {
    raw = readFileSync(source === "-" ? 0 : source, "utf8");
  } catch (error) {
    refuse(err, `could not read the batch ${source === "-" ? "from stdin" : `file ${source}`}: ${error.message}`);
    return null;
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    refuse(err, "the batch is not JSON — expected an array of {courseId, kind, title, due, link?}");
    return null;
  }
  if (!Array.isArray(parsed)) {
    refuse(err, "the batch must be a JSON array of {courseId, kind, title, due, link?}");
    return null;
  }
  return parsed;
}

function refuse(err, detail) {
  err(`bsb: ${detail}`);
  return 1;
}
