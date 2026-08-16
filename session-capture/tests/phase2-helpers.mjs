/**
 * Shared scaffolding for the phase-2 tests: the real fetcher and the real rungs.
 *
 * Three rules shape everything here, and they are the same rules phase 1 set:
 *
 *  1. HERMETIC. No socket, no browser, no production BSB_ROOT. The fetcher's
 *     HTTP and the rungs' browser are INJECTED, so every claim below is a
 *     Google-small test with a temp directory as its only real I/O.
 *  2. FIXTURES OVER INVENTION. The payloads are the ones the Swift pipeline
 *     recorded off the live tenant (copied verbatim into tests/fixtures/), so a
 *     Node port that disagrees with them disagrees with Brightspace.
 *  3. SECRETS ARE MARKED. Every credential in this file spells SECRET, so a
 *     leak assertion is a substring search and can never pass by accident.
 *
 * ---------------------------------------------------------------------------
 * THE TWO SEAMS THIS FILE FAKES — binding on the builder
 * ---------------------------------------------------------------------------
 *
 * The HTTP seam, injected into `createFetcher({ http })`:
 *
 *     http({ method, url, headers, body }) -> Promise<{ status: number, body: string }>
 *
 *   `headers` is a plain object, `body` a string (or undefined). A REJECTION is
 *   how "the network never answered" arrives — offline, DNS, TLS, timeout — and
 *   must be classified as a transport failure, never as an empty success. The
 *   default `http` (the one production uses) is a thin wrapper over global fetch.
 *
 * The browser seam, injected into `createSilentRung({ capture })` /
 * `createFullLoginRung({ capture })`:
 *
 *     capture({ profileDir, baseUrl, log }) -> Promise<
 *         { ok: true, cookies: [{name, value}], csrfToken: string|null, landedUrl: string }
 *       | { ok: false, reason: string }>
 *
 *   Everything playwright is on the far side of it. The rung's own job — the
 *   part these tests pin — is: call the seam, turn its cookies into the
 *   `buildSession` shape, and land that at `paths.sessionFile` with mode 0600.
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const FIXTURE_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures");

/** Read a recorded payload verbatim. Fixtures are strings: bodies arrive as bytes. */
export const fixture = (name) => readFileSync(path.join(FIXTURE_DIR, name), "utf8");

/** Fixture JSON as a value, for tests that need to slice or count it. */
export const fixtureJson = (name) => JSON.parse(fixture(name));

// ---------------------------------------------------------------------------
// The credentials. Every one is marked SECRET so a leak test is a substring
// search — and so a real credential can never be mistaken for one of these.
// ---------------------------------------------------------------------------

export const TEST_BASE = "https://test.brightspace.example";
export const SESSION_COOKIE = "d2lSessionVal=SECRET-session-abc123; d2lSecureSessionVal=SECRET-secure-def456";
export const CSRF_TOKEN = "SECRET-csrf-xyz789";
export const JWT = "SECRET.jwt-payload.signature";

/** Every marked credential, for the "did anything leak?" assertions. */
export const SECRETS = [SESSION_COOKIE, "SECRET-session-abc123", "SECRET-secure-def456", CSRF_TOKEN, JWT];

/**
 * Write a session.json in the shape `buildSession` produces. Overrides replace
 * fields wholesale, and `undefined` deletes one — that is how the
 * missing-cookieHeader case is built without hand-rolling a second writer.
 */
export function writeSessionFile(paths, overrides = {}) {
  const session = {
    capturedAt: 1_755_267_600_000,
    baseUrl: TEST_BASE,
    cookieHeader: SESSION_COOKIE,
    cookies: [
      { name: "d2lSessionVal", value: "SECRET-session-abc123" },
      { name: "d2lSecureSessionVal", value: "SECRET-secure-def456" },
    ],
    csrfToken: CSRF_TOKEN,
    landedUrl: `${TEST_BASE}/d2l/home`,
    ...overrides,
  };
  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) delete session[key];
  }
  writeFileSync(paths.sessionFile, JSON.stringify(session, null, 2));
  return session;
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

export const json = (value, status = 200) => ({ status, body: JSON.stringify(value) });
export const raw = (body, status = 200) => ({ status, body });
export const status = (code, body = "") => ({ status: code, body });

/**
 * A mint success. SYNTHESIZED, unlike every other payload here: no capture of a
 * successful `POST /d2l/lp/auth/oauth2/token` body was ever recorded. Only
 * `access_token` is load-bearing — it is the single field the Swift decoder
 * reads — and the two companions are the OAuth2 shape every server sends.
 */
export const mintOk = (token = JWT) =>
  json({ access_token: token, token_type: "Bearer", expires_in: 3600 });

/** The measured dead-session answer: HTTP 200 carrying a redirect stub. */
export const sessionExpiredStub = () => raw(fixture("session-expired-stub.html"));

/** `{"Items": [...]}` limited to the given org-unit ids, straight from the fixture. */
export function enrollmentsFor(ids) {
  const payload = fixtureJson("myenrollments-200.json");
  return json({
    ...payload,
    Items: payload.Items.filter((item) => ids.includes(item.OrgUnit.Id)),
  });
}

// ---------------------------------------------------------------------------
// The fake HTTP seam
// ---------------------------------------------------------------------------

const MINT_MARK = "/d2l/lp/auth/oauth2/token";
const ENROLLMENTS_MARK = "/enrollments/myenrollments";
const DROPBOX_MARK = "/dropbox/folders";
const QUIZZES_MARK = "/quizzes";
const GRADES_MARK = "/grades/";
const NEWS_MARK = "/news/";

/** The org-unit id out of a per-course route, so a router can answer per course. */
export const courseIdOf = (url) => Number(url.match(/\/d2l\/api\/le\/[\d.]+\/(\d+)\//)?.[1] ?? 0);

/**
 * A Brightspace-shaped fake. Every route has a working default, so each test
 * overrides only the response it is about and the other 53 requests stay quiet.
 *
 * A route value may be a response object, a function of the request, or an
 * Error — an Error is THROWN, which is how a dead network arrives at the seam.
 * Per-course routes take `{ [courseId]: response, default: response }`.
 *
 * The returned function carries `.requests`, every request in the order it was
 * made, which is what lets a test read the Bearer header off the second call.
 */
export function fakeHttp(routes = {}) {
  const {
    mint = mintOk(),
    enrollments = raw(fixture("myenrollments-200.json")),
    dropbox = {},
    quizzes = {},
    grades = {},
    news = {},
  } = routes;

  const answer = async (route, request) => {
    if (route instanceof Error) throw route;
    return typeof route === "function" ? route(request) : route;
  };

  const perCourse = (table, request, fallback) => {
    const id = courseIdOf(request.url);
    const route = table[id] ?? table.default ?? fallback;
    return answer(route, request);
  };

  const http = async (request) => {
    http.requests.push(request);
    const { url } = request;
    if (url.includes(MINT_MARK)) return answer(mint, request);
    if (url.includes(ENROLLMENTS_MARK)) return answer(enrollments, request);
    if (url.includes(DROPBOX_MARK)) return perCourse(dropbox, request, json([]));
    if (url.includes(QUIZZES_MARK)) return perCourse(quizzes, request, json({ Objects: [], Next: null }));
    // A gradebook of no columns is the quiet default: every test that is not
    // about the diff must keep answering this route without saying so.
    if (url.includes(GRADES_MARK)) return perCourse(grades, request, json([]));
    // A course with no announcements, likewise: the quiet default every test
    // that is not about the news route keeps answering without saying so.
    if (url.includes(NEWS_MARK)) return perCourse(news, request, json([]));
    throw new Error(`the fake was asked for an unrouted URL: ${url}`);
  };
  http.requests = [];
  return http;
}

/** Every recorded request whose URL contains `mark`, in order. */
export const requestsFor = (http, mark) => http.requests.filter((r) => r.url.includes(mark));

/** One header, case-insensitively — the seam does not promise a casing. */
export function headerOf(request, name) {
  const wanted = name.toLowerCase();
  const found = Object.entries(request.headers ?? {}).find(([key]) => key.toLowerCase() === wanted);
  return found?.[1];
}

export const MARKS = {
  mint: MINT_MARK,
  enrollments: ENROLLMENTS_MARK,
  dropbox: DROPBOX_MARK,
  quizzes: QUIZZES_MARK,
  grades: GRADES_MARK,
  news: NEWS_MARK,
};

// ---------------------------------------------------------------------------
// The fake browser seam
// ---------------------------------------------------------------------------

/** The cookies a real capture harvests, DELIBERATELY in the wrong order. */
export const CAPTURED_COOKIES = [
  { name: "d2lSecureSessionVal", value: "SECRET-secure-def456" },
  { name: "d2lSessionVal", value: "SECRET-session-abc123" },
];

/**
 * A browser that never launches. `result` is what the capture reports; `throws`
 * makes it explode the way playwright does when a profile is locked. Records
 * every call so a test can read back which profile directory was driven.
 */
export function fakeCapture(spec = {}) {
  const {
    result = {
      ok: true,
      cookies: CAPTURED_COOKIES,
      csrfToken: CSRF_TOKEN,
      landedUrl: `${TEST_BASE}/d2l/home`,
    },
    throws = null,
  } = spec;
  const capture = async (world) => {
    capture.calls.push(world);
    if (throws) throw new Error(throws);
    return result;
  };
  capture.calls = [];
  return capture;
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

/** A temp directory that is NOT a BSB_ROOT — for tests that need a bare path. */
export function scratchDir(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), "bsb-phase2-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

/** The keys the plan's data.json contract fixes for each kind of object. */
export const COURSE_KEYS = ["id", "name", "code", "role", "isActive", "homeUrl", "startDate", "endDate"];
export const ITEM_KEYS = ["id", "title", "dueDate", "url", "kind"];
export const ANNOUNCEMENT_KEYS = ["id", "title", "date"];

/** ISO-8601 with no fractional seconds — the form Swift's `.iso8601` decodes. */
export const ISO_SECONDS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
