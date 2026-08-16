/**
 * The real fetcher: session.json → JWT → enrollments → per-course assignments,
 * quizzes, gradebook and announcements → the data.json contract.
 *
 * A port of David's own proven Swift path (`BrightspaceCourseSource`,
 * `EnrollmentParser`, `BrightspaceAssignmentSource`/`AssignmentParser`,
 * `BrightspaceQuizSource`/`QuizParser`), semantics kept identical — the same
 * endpoints, the same versions, the same failure taxonomy — because those were
 * measured against this tenant, not guessed.
 *
 * Shape: HTTP is the one injected effect and the parsers are pure functions on
 * (status, body). That is what makes the classification inspectable without a
 * socket, and the classification is the whole job:
 *
 *   - `sessionExpired` is the ONLY reason that makes the orchestrator climb the
 *     ladder, and the dead-session answer here is an HTTP **200** carrying a
 *     redirect stub. Reading it as success writes an empty cache over the user's
 *     courses; reading an outage as sessionExpired drags a human through a
 *     pointless login.
 *   - Only the two whole-run steps (the mint and the enrollments call) may
 *     report it. A stub on one course's content route is that course failing —
 *     a really dead session is caught by the next run's mint anyway, so this
 *     self-heals in one cycle instead of holding 27 courses hostage to one route.
 *
 * D7: the cookie, the CSRF token and the JWT are read from session.json, sent as
 * headers, and never logged, never returned, never written into the payload the
 * cache writer receives.
 */
import { readFileSync } from "node:fs";

/** Confirmed against this tenant's own `GET /d2l/api/versions/`. */
const LP_VERSION = "1.62";
const LE_VERSION = "1.96";

/** The marker in the HTTP-200 stub a dead cookie gets instead of a payload. */
const EXPIRED_MARKER = "sessionExpired=1";

const expired = () => ({ ok: false, reason: "sessionExpired" });
const transport = (detail) => ({ ok: false, reason: "transport", detail });

/**
 * @param {{http?: (request: {method: string, url: string, headers: object,
 *          body?: string}) => Promise<{status: number, body: string}>}} [deps]
 */
export function createFetcher({ http = nodeHttp } = {}) {
  return {
    /** @param {{paths: object, log: (m: string) => void}} world */
    async fetch({ paths, log }) {
      const credentials = readCredentials(paths.sessionFile);
      // No credentials is not an error state: it is the same recovery path as an
      // expired one, because a rung can produce the file that is missing.
      if (!credentials) return expired();

      const minted = await send(http, mintRequest(credentials));
      if (!minted.ok) return minted;
      const mint = decodeMint(minted);
      if (mint.expired) return expired();
      if (!mint.token) return transport(mint.detail);

      const answered = await send(http, enrollmentsRequest(credentials, mint.token));
      if (!answered.ok) return answered;
      const enrolled = decodeEnrollments(answered);
      if (enrolled.expired) return expired();
      if (!enrolled.courses) return transport(enrolled.detail);

      const assignments = {};
      const announcements = {};
      for (const course of enrolled.courses) {
        const outcome = await courseItems(http, credentials, mint.token, course.id);
        // Announcements are answered first and separately: they are their own
        // question about the course, so the verdict on its work — including the
        // `continue` below — must not decide them either way.
        if (outcome.news.ok) {
          announcements[course.id] = outcome.news.items;
        } else {
          log(`course ${course.id}: no announcements (${outcome.news.detail})`);
        }
        // A course with no key means "unknown", which is what lets the app keep
        // whatever it already had; an empty list would claim it owes nothing.
        if (!outcome.ok) {
          log(`course ${course.id}: no assignments or quizzes (${outcome.detail})`);
          continue;
        }
        assignments[course.id] = outcome.items;
        // A heads-up section missing from one course is invisible on its own —
        // the rows it lost are the ones nothing else in the menu knows about.
        if (outcome.gradesDetail) {
          log(`course ${course.id}: no gradebook heads-up rows (${outcome.gradesDetail})`);
        }
      }
      log(`fetched ${enrolled.courses.length} courses`);

      return { ok: true, data: { courses: enrolled.courses, assignments, announcements } };
    },
  };
}

// ---------------------------------------------------------------------------
// Doing: the network, and the credentials on disk
// ---------------------------------------------------------------------------

/** The production HTTP seam — a thin wrapper over global fetch. */
async function nodeHttp({ method, url, headers, body }) {
  const response = await fetch(url, { method, headers, body });
  return { status: response.status, body: await response.text() };
}

/**
 * The only place a socket is touched. Anything that stops a request from
 * returning a response — offline, DNS, TLS, timeout — becomes a transport
 * failure, never an empty success.
 */
async function send(http, request) {
  try {
    const { status, body } = await http(request);
    return { ok: true, status, body: String(body ?? "") };
  } catch (error) {
    return transport(String(error?.message ?? error));
  }
}

/**
 * One course's four routes, in parallel, merged content-first. Half the data
 * beats none: a failing quiz route must not regress the assignments that already
 * worked. Only when BOTH content routes fail is the course unknown — neither the
 * gradebook nor the news route votes, they only add their own rows or report why
 * they could not.
 *
 * The gradebook is fetched with the others but read after them: a heads-up row
 * is a column NOTHING the content routes returned matched, so the diff cannot be
 * decided until they have answered.
 *
 * `news` rides along and comes back on its own field rather than merged into
 * `items`, because an announcement is not work the student owes — it answers a
 * different question about the course and fails independently of that one. One
 * more entry in this `Promise.all` is also all it costs: a fourth route awaited
 * separately would double a 27-course refresh's wall time.
 */
async function courseItems(http, credentials, token, courseId) {
  const [folders, quizzes, gradebook, news] = await Promise.all([
    route(http, contentRequest(credentials, token, courseId, "dropbox/folders/"), (body) =>
      parseFolders(body, credentials.baseUrl, courseId),
    ),
    route(http, contentRequest(credentials, token, courseId, "quizzes/"), (body) =>
      parseQuizzes(body, credentials.baseUrl, courseId),
    ),
    readBody(http, contentRequest(credentials, token, courseId, "grades/")),
    route(http, contentRequest(credentials, token, courseId, "news/"), parseNews),
  ]);
  if (!folders.ok && !quizzes.ok) {
    return { ok: false, detail: `${folders.detail}; ${quizzes.detail}`, news };
  }
  const items = [...(folders.items ?? []), ...(quizzes.items ?? [])];
  const headsUp = gradebook.ok
    ? parseGradebook(gradebook.body, items, credentials.baseUrl, courseId)
    : gradebook;
  return headsUp.ok
    ? { ok: true, items: [...items, ...headsUp.items], news }
    : { ok: true, items, gradesDetail: headsUp.detail, news };
}

/** Fetch one route down to its body, or the reason there is none. */
async function readBody(http, request) {
  const answer = await send(http, request);
  if (!answer.ok) return { ok: false, detail: answer.detail };
  // 403 is the expected steady state for last term's courses, not an exception.
  if (!isSuccess(answer.status)) return { ok: false, detail: `HTTP ${answer.status}` };
  return { ok: true, body: answer.body };
}

/** Fetch one content route and hand the body to its parser. */
async function route(http, request, parse) {
  const answer = await readBody(http, request);
  return answer.ok ? parse(answer.body) : answer;
}

/**
 * The credentials, or null when there are none to work with. A missing file and
 * a half-written one are the same answer: a rung can produce what is missing.
 */
function readCredentials(sessionFile) {
  let session;
  try {
    session = JSON.parse(readFileSync(sessionFile, "utf8"));
  } catch {
    return null;
  }
  const { baseUrl, cookieHeader, csrfToken } = session ?? {};
  if (!isFilled(baseUrl) || !isFilled(cookieHeader)) return null;
  return {
    baseUrl: baseUrl.replace(/\/+$/, ""),
    cookieHeader,
    csrfToken: isFilled(csrfToken) ? csrfToken : null,
  };
}

// ---------------------------------------------------------------------------
// The requests
// ---------------------------------------------------------------------------

/** Cookie-authenticated token mint — the one non-GET request the daemon makes. */
const mintRequest = (credentials) => ({
  method: "POST",
  url: `${credentials.baseUrl}/d2l/lp/auth/oauth2/token`,
  headers: {
    "content-type": "application/x-www-form-urlencoded",
    cookie: credentials.cookieHeader,
    ...(credentials.csrfToken ? { "x-csrf-token": credentials.csrfToken } : {}),
  },
  body: "scope=*:*:*",
});

const bearerGet = (url, token) => ({
  method: "GET",
  url,
  headers: { authorization: `Bearer ${token}` },
});

const enrollmentsRequest = (credentials, token) =>
  bearerGet(
    `${credentials.baseUrl}/d2l/api/lp/${LP_VERSION}/enrollments/myenrollments/` +
      "?orgUnitTypeId=3&isActive=true",
    token,
  );

const contentRequest = (credentials, token, courseId, suffix) =>
  bearerGet(`${credentials.baseUrl}/d2l/api/le/${LE_VERSION}/${courseId}/${suffix}`, token);

// ---------------------------------------------------------------------------
// Deciding: pure classification and parsing (no I/O, no secrets)
// ---------------------------------------------------------------------------

/**
 * Classify a mint response. Measured, not guessed: a dead session comes back at
 * HTTP 200 carrying an HTML stub whose script redirects to
 * `/d2l/login?sessionExpired=1`. There is no 401 on this path, so the marker —
 * not the status — is the only honest signal, and it is checked first.
 */
function decodeMint({ status, body }) {
  if (body.includes(EXPIRED_MARKER)) return { expired: true };
  if (!isSuccess(status)) return { detail: `the token mint answered HTTP ${status}` };
  const token = jsonOf(body)?.access_token;
  if (!isFilled(token)) return { detail: "the token mint returned no access_token" };
  return { token };
}

/**
 * `{"Items":[…]}` → courses. An undecodable item among decodable ones is
 * skipped (one org unit mid-deletion costs one row out of 27); a non-empty
 * `Items` where nothing decoded is a shape mismatch, not an empty account.
 *
 * The stub marker is checked only AFTER the envelope fails to decode, so a real
 * payload that merely mentions it can never be misclassified — and a 502 page
 * stays a transport failure instead of dragging a human through a re-login.
 */
function decodeEnrollments({ status, body }) {
  if (!isSuccess(status)) return { detail: `the enrollments call answered HTTP ${status}` };
  const payload = jsonOf(body);
  if (!Array.isArray(payload?.Items)) {
    if (body.includes(EXPIRED_MARKER)) return { expired: true };
    return { detail: "the enrollments payload was not the {Items: […]} envelope" };
  }
  const courses = payload.Items.map(courseOf).filter((course) => course !== null);
  if (courses.length === 0 && payload.Items.length > 0) {
    return { detail: `none of ${payload.Items.length} enrollments was decodable` };
  }
  return { courses };
}

/**
 * One enrollment onto the data.json contract, every value read and none
 * computed: `HomeUrl` is null in 25 of 27 real items, and deriving one is a
 * click-layer policy decision the fetched layer does not make. The access window
 * passes through as the raw strings D2L sent — Swift's `Course` keeps those as
 * String?, and only assignment due dates get normalized.
 */
function courseOf(item) {
  const orgUnit = item?.OrgUnit;
  const access = item?.Access;
  if (typeof orgUnit?.Id !== "number") return null;
  if (typeof orgUnit.Name !== "string" || typeof orgUnit.Code !== "string") return null;
  if (typeof access?.IsActive !== "boolean" || typeof access.ClasslistRoleName !== "string") {
    return null;
  }
  return {
    id: orgUnit.Id,
    name: orgUnit.Name,
    code: orgUnit.Code,
    role: access.ClasslistRoleName,
    isActive: access.IsActive,
    homeUrl: orgUnit.HomeUrl ?? null,
    startDate: access.StartDate ?? null,
    endDate: access.EndDate ?? null,
  };
}

/**
 * `dropbox/folders` is a BARE ARRAY while `quizzes` is `{"Objects":[…]}`. The
 * two shapes are checked separately and neither decoder accepts the other's, or
 * a copy-paste between them would report success with nothing in it.
 *
 * A folder with no id or no name fails the whole course: without an id the row
 * can never be clicked, and a course has a handful of assignments, so serving
 * the rest is indistinguishable from an instructor having deleted them. An
 * unreadable DATE is survivable and costs one line.
 */
function parseFolders(body, baseUrl, courseId) {
  const payload = jsonOf(body);
  if (!Array.isArray(payload)) return { ok: false, detail: "not a dropbox folder array" };
  const items = [];
  for (const folder of payload) {
    if (typeof folder?.Id !== "number" || typeof folder.Name !== "string") {
      return { ok: false, detail: "a dropbox folder carried no id or no name" };
    }
    items.push({
      id: folder.Id,
      title: folder.Name,
      dueDate: isoSeconds(folder.DueDate),
      url: assignmentUrl(baseUrl, courseId, folder.Id),
      kind: "assignment",
    });
  }
  return { ok: true, items };
}

/** The quiz envelope. Same asymmetry as the folders: fatal id, survivable date. */
function parseQuizzes(body, baseUrl, courseId) {
  const payload = jsonOf(body);
  if (!Array.isArray(payload?.Objects)) return { ok: false, detail: "not a quiz envelope" };
  const items = [];
  for (const quiz of payload.Objects) {
    if (typeof quiz?.QuizId !== "number" || typeof quiz.Name !== "string") {
      return { ok: false, detail: "a quiz carried no id or no name" };
    }
    items.push({
      id: quiz.QuizId,
      title: quiz.Name,
      dueDate: isoSeconds(quiz.DueDate),
      url: quizUrl(baseUrl, courseId, quiz.QuizId),
      kind: "quiz",
    });
  }
  return { ok: true, items };
}

/** The four types a student is scored on: numeric, passfail, selectbox, text. */
const STUDENT_SCORED = new Set([1, 2, 3, 4]);

/**
 * The gradebook, as a BARE ARRAY again, kept down to the columns that describe
 * work no other route already offered: student-scored AND matching no fetched
 * item. "Unlinked only" is the wrong second half — a released midterm's column
 * IS linked, to a quiz the student's own `quizzes/` call cannot see, and that
 * column is the whole reason this section exists. The bookkeeping types
 * (category, calculated, formula, final) are excluded before anything is read
 * off them, so one nameless category cannot veto a course's heads-up rows.
 *
 * Same asymmetry as the folders, applied to the kept rows only: no id or no name
 * fails the whole gradebook, because a nameless row is a blank line in the menu
 * and an id-less one can never be clicked.
 */
function parseGradebook(body, items, baseUrl, courseId) {
  const payload = jsonOf(body);
  if (!Array.isArray(payload)) return { ok: false, detail: "not a grade object array" };
  const fetched = new Set(items.map((item) => item.id));
  const headsUp = [];
  for (const column of payload) {
    if (!STUDENT_SCORED.has(column?.GradeObjectTypeId)) continue;
    if (fetched.has(column.AssociatedTool?.ToolItemId)) continue;
    if (typeof column.Id !== "number" || typeof column.Name !== "string") {
      return { ok: false, detail: "a grade column carried no id or no name" };
    }
    headsUp.push({
      id: column.Id,
      title: column.Name,
      // Always null in v1: a date ladder is a Fall decision, to be designed from
      // logged real column names rather than guessed now.
      dueDate: null,
      url: gradebookUrl(baseUrl, courseId),
      kind: "gradeOnly",
    });
  }
  return { ok: true, items: headsUp };
}

/**
 * How many of a course's announcements reach the cache. 440703 really carries
 * 467 of them; a menu bar shows the top few, so the rest are bytes the Swift
 * side decodes on every refresh and never renders.
 */
const ANNOUNCEMENT_LIMIT = 10;

/**
 * The news route: a BARE ARRAY again, kept down to the three fields a row needs.
 * Two rules are D2L's, not ours:
 *
 *   - An unpublished item is a draft the instructor has not posted. Only
 *     `IsPublished === false` is excluded — an item that omits the field is a
 *     shape this tenant has never sent, and reading unknown as unpublished would
 *     empty the section the day D2L renames it.
 *   - `StartDate` is when the instructor scheduled the post and is the honest
 *     answer whenever it exists; `CreatedDate` is the fallback for the ones
 *     scheduled by nobody. Unreadable and absent are the same answer here — the
 *     field yielded no date — so both fall through to the same next-best one.
 *
 * Sorted here rather than trusted from the server: D2L happens to answer
 * newest-first today, and a cap applied to an order nobody promised would
 * quietly keep the ten OLDEST the day that changes.
 *
 * Same fatal-id/fatal-title asymmetry as the other parsers, with a smaller blast
 * radius: a bad row costs the course its announcements, never its assignments.
 */
function parseNews(body) {
  const payload = jsonOf(body);
  if (!Array.isArray(payload)) return { ok: false, detail: "not a news item array" };
  const items = [];
  for (const item of payload) {
    if (item?.IsPublished === false) continue;
    if (typeof item?.Id !== "number" || typeof item.Title !== "string") {
      return { ok: false, detail: "a news item carried no id or no title" };
    }
    items.push({
      id: item.Id,
      title: item.Title,
      date: isoSeconds(item.StartDate) ?? isoSeconds(item.CreatedDate),
    });
  }
  return { ok: true, items: items.sort(newestFirst).slice(0, ANNOUNCEMENT_LIMIT) };
}

/**
 * Newest first, undated last. The dates are already normalized to whole-second
 * UTC, so they are fixed-width strings in one zone and compare chronologically
 * as text. Equal dates return 0 and keep the server's own order, which is what
 * makes the cap deterministic when a course posts twice in one minute.
 */
const newestFirst = (a, b) => {
  if (a.date === b.date) return 0;
  // An undated row sorts to the end rather than to 1970, where a null read as
  // an epoch would put it — ahead of nothing, but behind everything real.
  if (a.date === null) return 1;
  if (b.date === null) return -1;
  return a.date < b.date ? 1 : -1;
};

/**
 * The deep links, computed from ids alone because D2L sends nothing usable as
 * one. Both templates were harvested from Brightspace's own markup and then
 * navigated in a real browser (experiment 7 for `db`, a live probe for `qi`);
 * the query order is theirs — db, grpid, ou — and `qi, ou` has no group
 * parameter to carry over, because quizzes have no group concept.
 */
const assignmentUrl = (baseUrl, courseId, folderId) =>
  `${baseUrl}/d2l/lms/dropbox/user/folder_submit_files.d2l?db=${folderId}&grpid=0&ou=${courseId}`;

const quizUrl = (baseUrl, courseId, quizId) =>
  `${baseUrl}/d2l/lms/quizzing/user/quiz_summary.d2l?qi=${quizId}&ou=${courseId}`;

/** The gradebook has no per-column page a student may open: one link per course. */
const gradebookUrl = (baseUrl, courseId) =>
  `${baseUrl}/d2l/lms/grades/my_grades/main.d2l?ou=${courseId}`;

/**
 * D2L sends `2026-03-01T04:59:00.000Z` and, inconsistently, `2026-09-15T23:59:00Z`.
 * Swift decodes data.json with `.iso8601`, which REJECTS fractional seconds, so
 * the daemon hands over seconds precision. Anything unreadable yields null —
 * the fail-open half of the taxonomy.
 */
const ISO_8601 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/;
function isoSeconds(raw) {
  if (typeof raw !== "string" || !ISO_8601.test(raw)) return null;
  const at = new Date(raw);
  return Number.isNaN(at.getTime()) ? null : `${at.toISOString().slice(0, 19)}Z`;
}

const isSuccess = (status) => status >= 200 && status < 300;
const isFilled = (value) => typeof value === "string" && value.length > 0;
const jsonOf = (body) => {
  try {
    return JSON.parse(body);
  } catch {
    return null;
  }
};
