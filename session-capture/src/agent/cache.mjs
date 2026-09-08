/**
 * The agent surface's view of what the daemon already wrote: `cache/data.json`
 * and `cache/status.json`, read fresh and never modified. This is the zero-
 * network half of the CLI — a course list, a course's known work, the last
 * run's verdict — and it is deliberately the SAME file the Swift app renders,
 * so what an agent sees is what the human sees in the bar.
 *
 * Pure reads. Nothing here creates a file or a directory, so `bsb courses` on
 * a machine that has never run the daemon leaves the Library untouched and
 * says so.
 */
import { readFileSync } from "node:fs";

/** The tenant when nothing on disk says otherwise — the app's own constant. */
export const DEFAULT_BASE_URL = "https://purdue.brightspace.com";

/**
 * `data.json`, or the reason there is none. A missing cache is not an error in
 * the crash sense: the honest answer is "the daemon has not run yet", and the
 * CLI turns that into an instruction (`bsb refresh`).
 *
 * @returns {{ok: true, data: object} | {ok: false, detail: string}}
 */
export function readCache(paths) {
  let raw;
  try {
    raw = readFileSync(paths.dataFile, "utf8");
  } catch {
    return { ok: false, detail: `no cache at ${paths.dataFile} — the daemon has not run yet (try: bsb refresh)` };
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    return { ok: false, detail: `${paths.dataFile} is not JSON — a refresh will rewrite it (try: bsb refresh)` };
  }
  if (!Array.isArray(data?.courses)) {
    return { ok: false, detail: `${paths.dataFile} carries no course list — a refresh will rewrite it (try: bsb refresh)` };
  }
  return {
    ok: true,
    data: {
      fetchedAt: typeof data.fetchedAt === "string" ? data.fetchedAt : null,
      courses: data.courses,
      assignments: data.assignments ?? {},
      announcements: data.announcements ?? {},
    },
  };
}

/** `status.json` as written by the last run, or null when there is none. */
export function readStatus(paths) {
  try {
    const status = JSON.parse(readFileSync(paths.statusFile, "utf8"));
    return status && typeof status === "object" ? status : null;
  } catch {
    return null;
  }
}

/**
 * The courses a student is IN right now: active, started (or undated), and
 * not yet ended. The cache holds every enrollment — 32 of them on a real
 * account, most from past terms — and an agent asked to "read my classes"
 * means the current ones. `--all` on the CLI lifts the filter.
 */
export function currentCourses(courses, now) {
  const at = now.getTime();
  return courses.filter((course) => {
    if (course.isActive === false) return false;
    const start = Date.parse(course.startDate ?? "");
    const end = Date.parse(course.endDate ?? "");
    if (!Number.isNaN(start) && start > at) return false;
    if (!Number.isNaN(end) && end < at) return false;
    return true;
  });
}

/**
 * The tenant's base URL, for the deep links a manual item defaults to. Read
 * off `session.json` — the daemon's own file, which this CLI shares a package
 * with — but ONLY that one field: the cookie beside it is never returned by
 * this module, let alone printed (D7). Falls back to the app's constant when
 * there is no session yet.
 */
export function tenantBaseUrl(paths) {
  try {
    const { baseUrl } = JSON.parse(readFileSync(paths.sessionFile, "utf8")) ?? {};
    if (typeof baseUrl === "string" && /^https?:\/\//.test(baseUrl)) {
      return baseUrl.replace(/\/+$/, "");
    }
  } catch {
    // No session yet — the default tenant is the right answer.
  }
  return DEFAULT_BASE_URL;
}

/** `{courseId: [items]}` → one course's items, `[]` when the cache has no verdict on it. */
export function workOf(data, courseId) {
  const items = data.assignments?.[String(courseId)];
  return Array.isArray(items) ? items : [];
}
