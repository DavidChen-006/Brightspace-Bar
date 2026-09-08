/**
 * The agent's read of the cache — the same `data.json` the menu renders.
 * Reads never create anything, and the "current" filter is the whole
 * difference between 32 enrollments and the four a student is in this term.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import {
  DEFAULT_BASE_URL, currentCourses, readCache, readStatus, tenantBaseUrl, workOf,
} from "../src/agent/cache.mjs";
import { courseLabel } from "../src/agent/format.mjs";
import { SAMPLE_DATA, fixedClock, tempPaths } from "./helpers.mjs";

const course = (overrides) => ({
  id: 1, name: "c", code: "wl.202710.CS.25200.LE1", role: "Student", isActive: true,
  homeUrl: null, startDate: null, endDate: null, ...overrides,
});

test("a missing cache is a sentence pointing at bsb refresh, and nothing is created", (t) => {
  const paths = tempPaths(t);
  const result = readCache(paths);
  assert.equal(result.ok, false);
  assert.match(result.detail, /has not run yet.*bsb refresh/);
  assert.deepEqual(readdirSync(paths.root), []);
});

test("a corrupt or shapeless cache is refused, not read as empty", (t) => {
  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(paths.dataFile, "{ nope");
  assert.equal(readCache(paths).ok, false);
  writeFileSync(paths.dataFile, JSON.stringify({ fetchedAt: "x" }));
  assert.equal(readCache(paths).ok, false);
});

test("the cache comes back with every section present, defaulted when absent", (t) => {
  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(paths.dataFile, JSON.stringify({ fetchedAt: "2026-08-15T14:00:00.000Z", courses: SAMPLE_DATA.courses }));
  const result = readCache(paths);
  assert.ok(result.ok);
  assert.deepEqual(result.data, {
    fetchedAt: "2026-08-15T14:00:00.000Z", courses: SAMPLE_DATA.courses, assignments: {}, announcements: {},
  });
  assert.deepEqual(workOf(result.data, 412690), []);
});

test("workOf answers one course's items by string or number key", () => {
  assert.deepEqual(workOf(SAMPLE_DATA, 412690), SAMPLE_DATA.assignments[412690]);
  assert.deepEqual(workOf(SAMPLE_DATA, "412690"), SAMPLE_DATA.assignments[412690]);
  assert.deepEqual(workOf(SAMPLE_DATA, 1), []);
});

test("current means active, started (or undated) and not ended", () => {
  const now = fixedClock(); // 2026-08-15
  const courses = [
    course({ id: 1 }),                                                          // undated, active
    course({ id: 2, startDate: "2026-08-01T00:00:00Z", endDate: "2026-12-20T00:00:00Z" }), // in term
    course({ id: 3, startDate: "2025-08-01T00:00:00Z", endDate: "2025-12-20T00:00:00Z" }), // last year
    course({ id: 4, startDate: "2027-01-10T00:00:00Z", endDate: null }),        // next term
    course({ id: 5, isActive: false }),                                         // inactive
    course({ id: 6, startDate: "garbage", endDate: "garbage" }),                // unreadable → kept
  ];
  assert.deepEqual(currentCourses(courses, now).map((c) => c.id), [1, 2, 6]);
});

test("status.json is returned as written, or null", (t) => {
  const paths = tempPaths(t);
  assert.equal(readStatus(paths), null);
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(paths.statusFile, JSON.stringify({ state: "fresh", rungUsed: "none" }));
  assert.deepEqual(readStatus(paths), { state: "fresh", rungUsed: "none" });
  writeFileSync(paths.statusFile, "nope");
  assert.equal(readStatus(paths), null);
});

test("the tenant base URL is session.json's, else the default — and never the cookie", (t) => {
  const paths = tempPaths(t);
  assert.equal(tenantBaseUrl(paths), DEFAULT_BASE_URL);
  mkdirSync(paths.root, { recursive: true });
  writeFileSync(paths.sessionFile, JSON.stringify({
    baseUrl: "https://school.brightspace.com/", cookieHeader: "d2lSessionVal=SECRET",
  }));
  assert.equal(tenantBaseUrl(paths), "https://school.brightspace.com");
  writeFileSync(paths.sessionFile, JSON.stringify({ baseUrl: "not a url" }));
  assert.equal(tenantBaseUrl(paths), DEFAULT_BASE_URL);
});

test("courseLabel is the menu's own short label, or null for codes of another shape", () => {
  assert.equal(courseLabel("wl.202710.CS.25200.LE1"), "CS 25200");
  assert.equal(courseLabel("wl.202710.PHIL.21900.001"), "PHIL 21900");
  assert.equal(courseLabel("wl.nc.civics.test"), null);
  assert.equal(courseLabel("scholarly_project_milestones"), null);
  assert.equal(courseLabel(undefined), null);
});
