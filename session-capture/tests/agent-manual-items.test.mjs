/**
 * The agent's write surface, pinned at the function level: what a draft must
 * look like to become an item, and how the file is changed. The Swift side
 * quarantines a whole file over one bad entry, so every refusal here is a
 * menu that did NOT go blank.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import {
  KINDS, addItems, draftToItem, manualItemsFile, parseDue, readManualItems, removeItems, resolveKind,
} from "../src/agent/manual-items.mjs";
import { tempPaths } from "./helpers.mjs";

const COURSES = [{ id: 1631476, name: "Fall 2026 CS 25200-LE1 LEC" }, { id: 412690, name: "Civics" }];
const BASE = "https://purdue.brightspace.com";
const iso = (at) => `${at.toISOString().slice(0, 19)}Z`;

// ── parseDue ────────────────────────────────────────────────────────────────

test("a bare date means 23:59 in the local zone — the add-form's own default", () => {
  assert.equal(parseDue("2026-10-06"), iso(new Date(2026, 9, 6, 23, 59, 0)));
});

test("a local date-time is read in the local zone, with a space or a T", () => {
  const expected = iso(new Date(2026, 9, 6, 14, 30, 0));
  assert.equal(parseDue("2026-10-06 14:30"), expected);
  assert.equal(parseDue("2026-10-06T14:30"), expected);
  assert.equal(parseDue("2026-10-06T14:30:00"), expected);
});

test("a zoned instant is kept exactly, to the second", () => {
  assert.equal(parseDue("2026-10-06T14:30:00Z"), "2026-10-06T14:30:00Z");
  assert.equal(parseDue("2026-10-06T14:30:00-04:00"), "2026-10-06T18:30:00Z");
  assert.equal(parseDue("2026-10-06T14:30:00.250Z"), "2026-10-06T14:30:00Z");
});

test("anything else is refused, never guessed", () => {
  for (const bad of ["", "tomorrow", "10/06/2026", "2026-13-01", "2026-02-30", "2026-10-06 25:00", 42, null]) {
    assert.equal(parseDue(bad), null, `accepted ${JSON.stringify(bad)}`);
  }
});

// ── kinds ───────────────────────────────────────────────────────────────────

test("the three kinds are the Swift enum's, and the aliases land on them", () => {
  assert.deepEqual(KINDS, ["assignment", "quiz", "test"]);
  assert.equal(resolveKind("Quiz"), "quiz");
  assert.equal(resolveKind("EXAM"), "test");
  assert.equal(resolveKind("midterm"), "test");
  assert.equal(resolveKind("final"), "test");
  assert.equal(resolveKind("homework"), "assignment");
  assert.equal(resolveKind("hw"), "assignment");
  assert.equal(resolveKind("project"), "assignment");
  assert.equal(resolveKind("lab"), null);
  assert.equal(resolveKind(undefined), null);
});

// ── draftToItem ─────────────────────────────────────────────────────────────

test("a good draft becomes an item in the file's shape, with an uppercase UUID", () => {
  const result = draftToItem(
    { courseId: "1631476", kind: "Exam", title: "  Midterm 1 ", due: "2026-10-06T14:30:00Z", link: "https://x.test/m1" },
    { courses: COURSES, baseUrl: BASE },
  );
  assert.ok(result.ok, JSON.stringify(result));
  const { item } = result;
  assert.match(item.id, /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/);
  assert.deepEqual({ ...item, id: "X" }, {
    courseId: 1631476, due: "2026-10-06T14:30:00Z", id: "X", kind: "test", link: "https://x.test/m1", name: "Midterm 1",
  });
  // Sorted keys, as the Swift encoder writes them, so the file reads as one hand wrote it.
  assert.deepEqual(Object.keys(item), ["courseId", "due", "id", "kind", "link", "name"]);
});

test("the link defaults to the course home when omitted", () => {
  const result = draftToItem(
    { courseId: 1631476, kind: "quiz", name: "Quiz 2", due: "2026-10-06" },
    { courses: COURSES, baseUrl: BASE },
  );
  assert.ok(result.ok);
  assert.equal(result.item.link, "https://purdue.brightspace.com/d2l/home/1631476");
});

test("every problem is reported at once, and nothing is built", () => {
  const result = draftToItem(
    { courseId: "abc", kind: "lab", title: " ", due: "soon", link: "  " },
    { courses: COURSES, baseUrl: BASE },
  );
  assert.equal(result.ok, false);
  assert.equal(result.errors.length, 5, result.errors.join("\n"));
  assert.match(result.errors.join("\n"), /courseId must be an integer/);
  assert.match(result.errors.join("\n"), /kind must be one of assignment, quiz, test/);
  assert.match(result.errors.join("\n"), /title is required/);
  assert.match(result.errors.join("\n"), /due must be/);
  assert.match(result.errors.join("\n"), /link may be omitted but not blank/);
});

test("an id that is not an enrollment is refused with the fix in the sentence", () => {
  const result = draftToItem(
    { courseId: 999, kind: "quiz", title: "Q", due: "2026-10-06" },
    { courses: COURSES, baseUrl: BASE },
  );
  assert.equal(result.ok, false);
  assert.match(result.errors[0], /course 999 is not one of your enrollments.*bsb courses --all/);
});

// ── the file ────────────────────────────────────────────────────────────────

const item = (overrides = {}) => ({
  courseId: 1631476, due: "2026-10-07T03:59:00Z", id: "0F0E0D0C-0B0A-0908-0706-050403020100",
  kind: "quiz", link: "https://x.test", name: "Quiz 1", ...overrides,
});

test("a missing file reads as empty — the Swift store's P2", (t) => {
  const paths = tempPaths(t);
  assert.deepEqual(readManualItems(manualItemsFile(paths)), { ok: true, items: [] });
});

test("add writes the file atomically at the root, beside session.json and not under cache/", (t) => {
  const paths = tempPaths(t);
  const file = manualItemsFile(paths);
  const result = addItems(file, [item()]);
  assert.ok(result.ok);
  assert.deepEqual(result.added, [item()]);
  assert.deepEqual(readdirSync(paths.root), ["manual-items.json"]); // no temp debris, no cache/
  assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), [item()]);
});

test("add appends and keeps what was there", (t) => {
  const paths = tempPaths(t);
  const file = manualItemsFile(paths);
  addItems(file, [item()]);
  const second = item({ id: "11111111-1111-1111-1111-111111111111", name: "Quiz 2" });
  const result = addItems(file, [second]);
  assert.deepEqual(result.all, [item(), second]);
  assert.deepEqual(readManualItems(file).items, [item(), second]);
});

test("an identical item is skipped, so a re-run import cannot double the squares", (t) => {
  const paths = tempPaths(t);
  const file = manualItemsFile(paths);
  addItems(file, [item()]);
  const again = item({ id: "22222222-2222-2222-2222-222222222222", name: "  quiz 1 " });
  const result = addItems(file, [again]);
  assert.deepEqual(result.added, []);
  assert.deepEqual(result.skipped, [again]);
  assert.equal(readManualItems(file).items.length, 1);
  const forced = addItems(file, [again], { allowDuplicate: true });
  assert.deepEqual(forced.added, [again]);
  assert.equal(readManualItems(file).items.length, 2);
});

test("a duplicate inside one batch is skipped too", (t) => {
  const paths = tempPaths(t);
  const result = addItems(manualItemsFile(paths), [item(), item({ id: "33333333-3333-3333-3333-333333333333" })]);
  assert.equal(result.added.length, 1);
  assert.equal(result.skipped.length, 1);
});

test("a file the Swift decoder would quarantine is never overwritten", (t) => {
  const paths = tempPaths(t);
  const file = manualItemsFile(paths);
  mkdirSync(paths.root, { recursive: true });
  for (const [label, contents] of [
    ["not json", "{ not json ["],
    ["not an array", JSON.stringify({ items: [] })],
    ["unknown kind", JSON.stringify([item({ kind: "lab" })])],
    ["bad date", JSON.stringify([item({ due: "next week" })])],
    ["blank link", JSON.stringify([item({ link: " " })])],
  ]) {
    writeFileSync(file, contents);
    const read = readManualItems(file);
    assert.equal(read.ok, false, label);
    const added = addItems(file, [item()]);
    assert.equal(added.ok, false, label);
    const removed = removeItems(file, { ids: [item().id] });
    assert.equal(removed.ok, false, label);
    assert.equal(readFileSync(file, "utf8"), contents, `${label}: the bytes were touched`);
  }
});

test("remove by id keeps the rest and names the ids it could not find", (t) => {
  const paths = tempPaths(t);
  const file = manualItemsFile(paths);
  const other = item({ id: "44444444-4444-4444-4444-444444444444", name: "Quiz 2" });
  addItems(file, [item(), other]);
  const result = removeItems(file, { ids: [item().id.toLowerCase(), "nope"] });
  assert.ok(result.ok);
  assert.deepEqual(result.removed, [item()]);
  assert.deepEqual(result.missing, ["NOPE"]);
  assert.deepEqual(readManualItems(file).items, [other]);
});

test("remove by course drops exactly that course's items", (t) => {
  const paths = tempPaths(t);
  const file = manualItemsFile(paths);
  const elsewhere = item({ id: "55555555-5555-5555-5555-555555555555", courseId: 412690 });
  addItems(file, [item(), elsewhere]);
  const result = removeItems(file, { courseId: 1631476 });
  assert.deepEqual(result.removed, [item()]);
  assert.deepEqual(readManualItems(file).items, [elsewhere]);
});

test("removing nothing writes nothing", (t) => {
  const paths = tempPaths(t);
  const result = removeItems(manualItemsFile(paths), { ids: ["nope"] });
  assert.ok(result.ok);
  assert.deepEqual(result.removed, []);
  assert.deepEqual(readdirSync(paths.root), []);
});
