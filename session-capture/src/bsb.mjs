#!/usr/bin/env node
/**
 * `bsb` — Brightspace Bar for agents (and for the terminal).
 *
 * The app is deterministic on purpose: it shows the handful of things D2L's
 * API reports as work, and nothing it cannot verify. An AI agent has no such
 * limit — it can read a syllabus — but until now it had no way to hand what
 * it found to the bar. This CLI is that way. Two halves, one rule each:
 *
 *   READ  — the cache the daemon already wrote (`courses`, `work`, `status`,
 *           `announcements`), and, through the daemon's own session, the
 *           Brightspace read API (`api`, `content`, `fetch`, `overview`,
 *           `syllabus`, `grades`): GET only, structurally — `agent/api.mjs`
 *           has no method parameter, and every path must sit under /d2l/api/
 *           on the session's own tenant.
 *   WRITE — `$BSB_ROOT/manual-items.json`, the student's own items, the same
 *           file the add-form in the menu writes. Never `cache/` (the daemon's),
 *           never `session.json` (a credential), never Brightspace.
 *
 * `refresh` is the one command that does more: it runs the daemon's ladder
 * (`refresh.mjs`), which may put an MFA number on the menu-bar icon.
 *
 * Thin by design, like `refresh.mjs`: argv in, an exit code out, everything
 * decidable without a process tested in `src/agent/`.
 *
 * Exit codes: 0 done · 1 refused (usage, validation, a missing cache, an HTTP
 * error) · 2 the session is expired (run `bsb refresh`).
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { resolvePaths } from "./paths.mjs";
import { createApi } from "./agent/api.mjs";
import {
  currentCourses, readCache, readStatus, tenantBaseUrl, workOf,
} from "./agent/cache.mjs";
import {
  filenameFrom, flattenToc, gradeRows, overviewText, syllabusCandidates,
} from "./agent/content.mjs";
import { ageOf, courseLabel, json, localStamp, table } from "./agent/format.mjs";
import {
  KINDS, addItems, draftToItem, manualItemsFile, readManualItems, removeItems,
} from "./agent/manual-items.mjs";

const USAGE = `Usage: bsb <command> [options]

Reads from the cache the daemon wrote (no network):
  courses [--all]                the courses you are in now (--all: every enrollment)
  work --course ID               what Brightspace reports due in one course
  announcements --course ID      the course's latest announcements
  items [--course ID]            the items added by hand or by an agent
  status                         when the cache was written and how the last run went

Reads from Brightspace, through the app's own session (GET only):
  content --course ID            the course's table of contents (topic ids, files, links)
  fetch --course ID --topic ID [--out DIR|FILE] [--stdout]
                                 download a File topic (a syllabus PDF, a .docx, a .txt)
  overview --course ID           the course overview text (often the syllabus itself)
  syllabus --course ID [--out DIR]
                                 find the syllabus: overview text + every topic named
                                 like one, downloaded
  grades --course ID             your grades in the course, as the grades page shows them
  api PATH [--out FILE]          any read route: /d2l/api/… or le:<ou>/… or lp:…
                                 (le: = /d2l/api/le/<version>/, lp: = /d2l/api/lp/<version>/)

Writes (to the bar only — never to Brightspace):
  add --course ID --kind KIND --title TEXT --due WHEN [--link URL]
                                 one item; appears in the menu immediately
  add --batch FILE|-             many items from a JSON array of
                                 {courseId, kind, title, due, link?} (- reads stdin);
                                 validated as a whole, written as a whole
  remove ID [ID…]                remove items by id
  remove --course ID --all       remove every hand-added item of one course

The session:
  refresh [--no-full-login]      run the daemon's login ladder now. May put an MFA
                                 number on the menu-bar icon; tell the human first.

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

const commands = {
  courses, work, announcements, items, status,
  content, fetch: fetchTopic, overview, syllabus, grades, api,
  add, remove, refresh,
};
if (!Object.hasOwn(commands, command)) {
  process.stderr.write(`bsb: unknown command "${command}"\n\n${USAGE}\n`);
  process.exit(1);
}

const paths = resolvePaths();
const world = {
  paths,
  now: new Date(),
  api: createApi({ paths }),
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
// Reads — the cache
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
  if (!enrolled(cache, courseId)) return refuse(err, notEnrolled(courseId));
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

async function announcements(args, { paths, out, err }) {
  const { values } = options(args, { course: { type: "string" } });
  const courseId = requireCourseId(values.course, err);
  if (courseId === null) return 1;
  const cache = readCache(paths);
  if (!cache.ok) return refuse(err, cache.detail);
  if (!enrolled(cache, courseId)) return refuse(err, notEnrolled(courseId));
  const listed = cache.data.announcements?.[String(courseId)] ?? [];
  if (values.json) {
    out(json(listed));
    return 0;
  }
  if (listed.length === 0) {
    out("No announcements in the cache for this course.\n");
    return 0;
  }
  out(table(["DATE (local)", "TITLE", "ID"], listed.map((item) => [localStamp(item.date) || "—", item.title, item.id])));
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
// Reads — Brightspace, through the session (GET only)
// ---------------------------------------------------------------------------

async function content(args, { api, out, err }) {
  const { values } = options(args, { course: { type: "string" } });
  const courseId = requireCourseId(values.course, err);
  if (courseId === null) return 1;
  const answer = await api.get(`le:${courseId}/content/toc`);
  if (!answer.ok) return failed(err, answer);
  const rows = flattenToc(parseJson(answer.body));
  if (values.json) {
    out(json(rows));
    return 0;
  }
  if (rows.length === 0) {
    out("The course has no content topics.\n");
    return 0;
  }
  out(table(
    ["TOPIC", "TYPE", "TITLE", "MODULE", "URL"],
    rows.map((row) => [row.topicId, row.type, row.title, row.module, row.type === "Link" ? row.url ?? "" : ""]),
  ));
  out("\nA File topic downloads with: bsb fetch --course ID --topic TOPIC\n");
  return 0;
}

async function fetchTopic(args, { api, out, err }) {
  const { values } = options(args, {
    course: { type: "string" }, topic: { type: "string" }, out: { type: "string" }, stdout: { type: "boolean" },
  });
  const courseId = requireCourseId(values.course, err);
  if (courseId === null) return 1;
  const topicId = Number(values.topic);
  if (!Number.isInteger(topicId)) return refuse(err, "--topic ID is required (run `bsb content --course ID` for the ids)");
  const answer = await api.get(`le:${courseId}/content/topics/${topicId}/file`);
  if (!answer.ok) return failed(err, answer);
  if (values.stdout) {
    process.stdout.write(answer.body);
    return 0;
  }
  const saved = save(answer, values.out, `topic-${topicId}`);
  if (values.json) {
    out(json({ file: saved, bytes: answer.body.length, contentType: answer.contentType }));
    return 0;
  }
  out(`saved ${saved} (${answer.body.length} bytes, ${answer.contentType || "unknown type"})\n`);
  return 0;
}

async function overview(args, { api, out, err }) {
  const { values } = options(args, { course: { type: "string" } });
  const courseId = requireCourseId(values.course, err);
  if (courseId === null) return 1;
  const answer = await api.get(`le:${courseId}/overview`);
  if (!answer.ok && answer.reason === "http" && answer.status === 404) {
    if (values.json) out(json(null));
    else out("The course has no overview.\n");
    return 0;
  }
  if (!answer.ok) return failed(err, answer);
  const parsed = parseJson(answer.body);
  if (values.json) {
    out(json(parsed));
    return 0;
  }
  const text = overviewText(parsed);
  out(text ? `${text}\n` : "The course overview is empty.\n");
  return 0;
}

/**
 * The one the whole surface is for. A syllabus lives in one of two places on
 * this tenant — the overview text, or a File topic named like one — so both
 * are looked at, and every candidate file is downloaded so the agent can read
 * it (PDF, .docx, .txt) without a second round trip.
 */
async function syllabus(args, { api, out, err }) {
  const { values } = options(args, { course: { type: "string" }, out: { type: "string" } });
  const courseId = requireCourseId(values.course, err);
  if (courseId === null) return 1;
  const found = { overviewText: null, files: [], links: [] };

  const over = await api.get(`le:${courseId}/overview`);
  if (!over.ok && over.reason === "sessionExpired") return failed(err, over);
  if (over.ok) {
    const text = overviewText(parseJson(over.body));
    if (text) found.overviewText = text;
  }

  const toc = await api.get(`le:${courseId}/content/toc`);
  if (!toc.ok) return failed(err, toc);
  for (const row of syllabusCandidates(flattenToc(parseJson(toc.body)))) {
    if (row.type !== "File") {
      found.links.push({ topicId: row.topicId, title: row.title, url: row.url });
      continue;
    }
    const file = await api.get(`le:${courseId}/content/topics/${row.topicId}/file`);
    if (!file.ok) {
      err(`bsb syllabus: topic ${row.topicId} (${row.title}) could not be downloaded — ${file.detail}`);
      continue;
    }
    found.files.push({
      topicId: row.topicId, title: row.title,
      file: save(file, values.out, `syllabus-${row.topicId}`, { directory: true }),
      bytes: file.body.length, contentType: file.contentType,
    });
  }

  if (values.json) {
    out(json(found));
    return 0;
  }
  if (found.overviewText) {
    out(`── Course overview (${found.overviewText.length} chars) ──\n${found.overviewText}\n\n`);
  }
  for (const file of found.files) out(`saved ${file.file}  ← topic ${file.topicId} "${file.title}" (${file.bytes} bytes)\n`);
  for (const link of found.links) out(`link  ${link.url}  ← topic ${link.topicId} "${link.title}" (not a file; open it yourself)\n`);
  if (!found.overviewText && found.files.length === 0 && found.links.length === 0) {
    out("No syllabus found: the overview is empty and no topic is named like one. Try `bsb content --course ID` and read the titles.\n");
  }
  return 0;
}

async function grades(args, { api, out, err }) {
  const { values } = options(args, { course: { type: "string" } });
  const courseId = requireCourseId(values.course, err);
  if (courseId === null) return 1;
  const answer = await api.get(`le:${courseId}/grades/values/myGradeValues/`);
  if (!answer.ok) return failed(err, answer);
  const rows = gradeRows(parseJson(answer.body));
  if (values.json) {
    out(json(rows));
    return 0;
  }
  if (rows.length === 0) {
    out("No grade values released in this course.\n");
    return 0;
  }
  out(table(["GRADE", "POINTS", "NAME", "TYPE"], rows.map((row) => [row.grade, row.points, row.name, row.type])));
  return 0;
}

async function api(args, { api, out, err }) {
  const { values, positionals } = options(args, { out: { type: "string" } });
  const target = positionals[0];
  if (!target) return refuse(err, "api needs a path: /d2l/api/…, le:<courseId>/…, or lp:…");
  const answer = await api.get(target);
  if (!answer.ok) return failed(err, answer);
  if (values.out) {
    const saved = save(answer, values.out, "response");
    out(values.json ? json({ file: saved, bytes: answer.body.length, contentType: answer.contentType })
      : `saved ${saved} (${answer.body.length} bytes)\n`);
    return 0;
  }
  const parsed = /json/i.test(answer.contentType) ? parseJson(answer.body) : undefined;
  if (parsed !== undefined && parsed !== null) out(json(parsed));
  else process.stdout.write(answer.body);
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
// The session — the daemon's ladder, run on request
// ---------------------------------------------------------------------------

/**
 * `refresh.mjs`, with its own stdio and its own exit code (0 fresh · 2
 * needs-login · 1 error). The ladder may reach the full rung, which puts an
 * MFA number on the menu-bar icon — the skill tells the agent to say so
 * before running this. `--no-full-login` is passed through for the callers
 * that must never reach a phone.
 */
async function refresh(args, { err }) {
  const { values } = options(args, { "no-full-login": { type: "boolean" } });
  const cli = process.env.BSB_REFRESH_CLI
    ?? path.join(path.dirname(fileURLToPath(import.meta.url)), "refresh.mjs");
  err(`bsb: running the login ladder (${values["no-full-login"] ? "silent rungs only" : "full login allowed — watch the menu-bar icon for an MFA number"})`);
  const child = spawn(process.execPath, [cli, ...(values["no-full-login"] ? ["--no-full-login"] : [])], {
    stdio: "inherit",
    env: process.env,
  });
  return new Promise((resolve) => {
    child.on("error", (error) => {
      err(`bsb refresh: could not start ${cli}: ${error.message}`);
      resolve(1);
    });
    child.on("exit", (code) => resolve(code ?? 1));
  });
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

// Function declarations, not consts: the top-level `await` above runs before
// any `const` below it is initialized, and a helper reached from a command
// would be a TDZ error at the first call.
function enrolled(cache, courseId) {
  return cache.data.courses.some((course) => course.id === courseId);
}

function notEnrolled(courseId) {
  return `course ${courseId} is not one of your enrollments (run \`bsb courses --all\`)`;
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

/**
 * Where a download lands. `--out` names a file, or an existing directory —
 * or, for a command that may save several files (`syllabus`), always a
 * directory, created if need be. With no `--out`, the working directory. The
 * filename is the server's own (Content-Disposition), so a syllabus lands as
 * `PHIL 219 Syllabus fall 2026.docx` and not as `topic-22438392`.
 */
function save(answer, outOption, fallbackName, { directory = false } = {}) {
  const name = filenameFrom(answer.disposition, fallbackName);
  let target;
  if (!outOption) target = path.resolve(name);
  else if (directory || (existsSync(outOption) && statSync(outOption).isDirectory())) target = path.resolve(outOption, name);
  else target = path.resolve(outOption);
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, answer.body);
  return target;
}

function parseJson(buffer) {
  try {
    return JSON.parse(buffer.toString("utf8"));
  } catch {
    return null;
  }
}

/** A failed live read → the exit code the reason deserves, and one sentence. */
function failed(err, answer) {
  if (answer.reason === "sessionExpired") {
    err(`bsb: the session is expired (${answer.detail}) — run \`bsb refresh\` to climb the login ladder (it may put an MFA number on the menu-bar icon)`);
    return 2;
  }
  return refuse(err, answer.detail);
}

function refuse(err, detail) {
  err(`bsb: ${detail}`);
  return 1;
}
