/**
 * fetch-engine.mjs — the real Fetcher: session.json → JWT → enrollments →
 * per-course assignments and quizzes → the data.json contract.
 *
 * Priorities these tests defend (everything else was culled):
 *
 *  1. FAILURE CLASSIFICATION. `sessionExpired` is the ONLY reason that makes
 *     the orchestrator climb the ladder, and the dead-session answer on this
 *     tenant is an HTTP **200** carrying a redirect stub. Read that as success
 *     and the daemon writes an empty cache over the user's courses; read a 502
 *     as sessionExpired and cron drags a human through a pointless login. Every
 *     classification test below exists to keep those two apart.
 *  2. CONTRACT FIDELITY. The writer of data.json is one program and the reader
 *     is another, with no compiler in between. Field names, the exact `kind`
 *     strings, the deep-link templates and — the sharp one — ISO-8601 dates
 *     WITHOUT fractional seconds (Swift's `.iso8601` strategy rejects them) are
 *     pinned here or nowhere.
 *
 * Scope: small. HTTP is injected; the only real I/O is a temp BSB_ROOT, because
 * the fetcher reads its credentials off disk like the real thing does.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { createFetcher } from "../src/fetch-engine.mjs";
import { recorder, tempPaths } from "./helpers.mjs";
import {
  COURSE_KEYS,
  CSRF_TOKEN,
  ISO_SECONDS,
  ITEM_KEYS,
  JWT,
  MARKS,
  SECRETS,
  SESSION_COOKIE,
  TEST_BASE,
  enrollmentsFor,
  fakeHttp,
  fixture,
  fixtureJson,
  headerOf,
  json,
  mintOk,
  raw,
  requestsFor,
  sessionExpiredStub,
  status,
  writeSessionFile,
} from "./phase2-helpers.mjs";

/**
 * The whole act, in one line: a world with credentials on disk and a scripted
 * network. Returns the fetch result plus the http fake, so the assertions can
 * read either the payload or the requests it took to build it.
 */
async function fetchWith(t, { routes = {}, session = {}, log = () => {} } = {}) {
  const paths = tempPaths(t);
  if (session !== null) writeSessionFile(paths, session);
  const http = fakeHttp(routes);
  const result = await createFetcher({ http }).fetch({ paths, log });
  return { result, http, paths };
}

/** Courses keyed by id — spot-checking one course should not depend on order. */
const byId = (courses) => new Map(courses.map((course) => [course.id, course]));

// ---------------------------------------------------------------------------
// Credentials — the fetcher reads session.json itself (the seam's own rule).
// No credentials is not an error state: it is the SAME recovery path as an
// expired one, because a rung can produce the file that is missing.
// ---------------------------------------------------------------------------

test("reports sessionExpired when session.json does not exist", async (t) => {
  // Arrange — an empty root: the state after reset.sh --session.
  const paths = tempPaths(t);

  // Act
  const result = await createFetcher({ http: fakeHttp() }).fetch({ paths, log: () => {} });

  // Assert
  assert.deepStrictEqual(result, { ok: false, reason: "sessionExpired" });
});

test("reports sessionExpired when session.json is not valid JSON", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  writeFileSync(paths.sessionFile, "{ half a file");

  // Act
  const result = await createFetcher({ http: fakeHttp() }).fetch({ paths, log: () => {} });

  // Assert
  assert.equal(result.ok, false);
  assert.equal(result.reason, "sessionExpired");
});

test("reports sessionExpired when session.json carries no cookieHeader", async (t) => {
  // Arrange
  const { result } = await fetchWith(t, { session: { cookieHeader: undefined } });

  // Assert
  assert.equal(result.reason, "sessionExpired");
});

test("reports sessionExpired when the cookieHeader is empty", async (t) => {
  // Arrange
  const { result } = await fetchWith(t, { session: { cookieHeader: "" } });

  // Assert
  assert.equal(result.reason, "sessionExpired");
});

test("asks the network for nothing when there are no credentials to ask with", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const http = fakeHttp();

  // Act
  await createFetcher({ http }).fetch({ paths, log: () => {} });

  // Assert
  assert.deepStrictEqual(http.requests, []);
});

// ---------------------------------------------------------------------------
// The mint — David's proven first step, and the one that classifies a dead
// session. Ported from BrightspaceCourseSource.mintJWT.
// ---------------------------------------------------------------------------

test("mints against the session's own base url", async (t) => {
  // Arrange / Act
  const { http } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([]) } });

  // Assert
  assert.equal(requestsFor(http, MARKS.mint)[0].url, `${TEST_BASE}/d2l/lp/auth/oauth2/token`);
});

test("posts the form-encoded wildcard scope to the mint", async (t) => {
  // Arrange / Act
  const { http } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([]) } });

  // Assert
  const mint = requestsFor(http, MARKS.mint)[0];
  assert.equal(mint.method, "POST");
  assert.equal(headerOf(mint, "content-type"), "application/x-www-form-urlencoded");
  assert.equal(mint.body, "scope=*:*:*");
});

test("authenticates the mint with the cookie and the csrf token", async (t) => {
  // Arrange / Act
  const { http } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([]) } });

  // Assert
  const mint = requestsFor(http, MARKS.mint)[0];
  assert.equal(headerOf(mint, "cookie"), SESSION_COOKIE);
  assert.equal(headerOf(mint, "x-csrf-token"), CSRF_TOKEN);
});

test("omits the csrf header when the session captured no token", async (t) => {
  // Arrange / Act
  const { http } = await fetchWith(t, {
    session: { csrfToken: null },
    routes: { enrollments: enrollmentsFor([]) },
  });

  // Assert
  assert.equal(headerOf(requestsFor(http, MARKS.mint)[0], "x-csrf-token"), undefined);
});

test("classifies the HTTP-200 session stub as exactly sessionExpired", async (t) => {
  // Arrange — measured, not guessed: a dead cookie answers 200 with a redirect
  // stub. Anything but this exact reason string strands the ladder.
  const { result } = await fetchWith(t, { routes: { mint: sessionExpiredStub() } });

  // Assert
  assert.deepStrictEqual(result, { ok: false, reason: "sessionExpired" });
});

test("does not read a server error as an expired session", async (t) => {
  // Arrange — a 502 is the network, not the login: climbing here would pop a
  // browser at a human because Brightspace was down.
  const { result } = await fetchWith(t, { routes: { mint: status(502, "<html>bad gateway</html>") } });

  // Assert
  assert.equal(result.ok, false);
  assert.equal(result.reason, "transport");
});

test("names the status code when the mint fails", async (t) => {
  // Arrange / Act
  const { result } = await fetchWith(t, { routes: { mint: status(502, "bad gateway") } });

  // Assert
  assert.match(result.detail, /502/);
});

test("treats a mint with no access_token as a failure, not an empty account", async (t) => {
  // Arrange
  const { result } = await fetchWith(t, { routes: { mint: json({ token_type: "Bearer" }) } });

  // Assert
  assert.equal(result.ok, false);
  assert.equal(result.reason, "transport");
});

test("carries the minted token as the bearer on the enrollments call", async (t) => {
  // Arrange / Act
  const { http } = await fetchWith(t, {
    routes: { mint: mintOk("SECRET.jwt-payload.signature"), enrollments: enrollmentsFor([]) },
  });

  // Assert
  const call = requestsFor(http, MARKS.enrollments)[0];
  assert.equal(headerOf(call, "authorization"), `Bearer ${JWT}`);
});

test("mints once for the whole run, not once per course", async (t) => {
  // Arrange — 2 courses, 4 content routes; a per-request mint would be 5 posts.
  const { http } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([412690, 440703]) } });

  // Assert
  assert.equal(requestsFor(http, MARKS.mint).length, 1);
});

// ---------------------------------------------------------------------------
// Enrollments — the fixture is the live tenant's own answer, 27 courses deep.
// ---------------------------------------------------------------------------

test("reads every enrolled course out of the recorded payload", async (t) => {
  // Arrange
  const expected = fixtureJson("myenrollments-200.json").Items.length;

  // Act
  const { result } = await fetchWith(t);

  // Assert
  assert.equal(result.ok, true);
  assert.equal(result.data.courses.length, expected);
});

test("maps a course field for field onto the data.json contract", async (t) => {
  // Arrange / Act
  const { result } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([412690]) } });

  // Assert — every value read off the fixture, none of them computed.
  assert.deepStrictEqual(result.data.courses[0], {
    id: 412690,
    name: "Purdue Civics Knowledge Test",
    code: "wl.nc.civics.test",
    role: "Learner",
    isActive: true,
    homeUrl: "https://purdue.brightspace.com/d2l/home/412690",
    startDate: null,
    endDate: null,
  });
});

test("preserves a course's access window as the raw strings D2L sent", async (t) => {
  // Arrange — Swift's Course keeps these as String?, so they pass through
  // untouched; only assignment due dates get normalized.
  const { result } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([1092755]) } });

  // Assert
  const course = byId(result.data.courses).get(1092755);
  assert.equal(course.startDate, "2024-08-14T04:00:00.000Z");
  assert.equal(course.endDate, "2024-12-29T04:59:00.000Z");
  assert.equal(course.homeUrl, null);
});

test("drops the dozen D2L fields the contract does not model", async (t) => {
  // Arrange — the fixture item carries Type, ImageUrl, LISRoles, LastAccessed,
  // PinDate, CanAccess. None of them may reach the app.
  const { result } = await fetchWith(t);

  // Assert
  for (const course of result.data.courses) {
    assert.deepStrictEqual(Object.keys(course).sort(), [...COURSE_KEYS].sort());
  }
});

test("returns no courses rather than a failure for an account with none", async (t) => {
  // Arrange — an empty Items list is data, not an error.
  const { result } = await fetchWith(t, { routes: { enrollments: json({ Items: [] }) } });

  // Assert
  assert.equal(result.ok, true);
  assert.deepStrictEqual(result.data.courses, []);
});

test("classifies an enrollments body that is not the envelope as transport", async (t) => {
  // Arrange
  const { result } = await fetchWith(t, { routes: { enrollments: raw("<html>maintenance</html>") } });

  // Assert
  assert.equal(result.ok, false);
  assert.equal(result.reason, "transport");
  assert.ok(result.detail, "a malformed payload must say what was wrong");
});

test("climbs the ladder when the session dies between the mint and the enrollments", async (t) => {
  // Arrange — the same stub can appear on the second call.
  const { result } = await fetchWith(t, { routes: { enrollments: sessionExpiredStub() } });

  // Assert
  assert.deepStrictEqual(result, { ok: false, reason: "sessionExpired" });
});

test("classifies a rejected bearer as transport, not as an expired cookie", async (t) => {
  // Arrange — a 401 here means the JWT, which the ladder cannot fix by logging in.
  const { result } = await fetchWith(t, {
    routes: { enrollments: status(401, '{"title":"Unauthorized","status":401}') },
  });

  // Assert
  assert.equal(result.reason, "transport");
  assert.match(result.detail, /401/);
});

test("classifies a network that never answered as transport", async (t) => {
  // Arrange — the seam rejects; nothing downstream ever sees a status.
  const { result } = await fetchWith(t, {
    routes: { mint: new Error("getaddrinfo ENOTFOUND test.brightspace.example") },
  });

  // Assert
  assert.equal(result.reason, "transport");
  assert.match(result.detail, /ENOTFOUND/);
});

// ---------------------------------------------------------------------------
// Assignments and quizzes — two routes per course, merged into one list.
// ---------------------------------------------------------------------------

test("asks both content routes for every enrolled course", async (t) => {
  // Arrange / Act
  const { http } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([412690, 440703]) } });

  // Assert — the ids, not just the count: a course silently skipped is a
  // submenu that never fills.
  assert.deepStrictEqual(
    requestsFor(http, MARKS.dropbox).map((r) => r.url),
    [
      `${TEST_BASE}/d2l/api/le/1.96/412690/dropbox/folders/`,
      `${TEST_BASE}/d2l/api/le/1.96/440703/dropbox/folders/`,
    ],
  );
  assert.deepStrictEqual(
    requestsFor(http, MARKS.quizzes).map((r) => r.url),
    [
      `${TEST_BASE}/d2l/api/le/1.96/412690/quizzes/`,
      `${TEST_BASE}/d2l/api/le/1.96/440703/quizzes/`,
    ],
  );
});

test("carries the bearer onto the content routes too", async (t) => {
  // Arrange / Act
  const { http } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([412690]) } });

  // Assert
  for (const call of [...requestsFor(http, MARKS.dropbox), ...requestsFor(http, MARKS.quizzes)]) {
    assert.equal(headerOf(call, "authorization"), `Bearer ${JWT}`);
  }
});

test("maps a dropbox folder onto the contract with its proven deep link", async (t) => {
  // Arrange — the template is experiment 7's, harvested from Brightspace's own
  // markup and navigated in a real browser: db, grpid, ou, in that order.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: { 412690: raw(fixture("dropbox-folders-412690.json")) },
    },
  });

  // Assert
  assert.deepStrictEqual(result.data.assignments[412690], [
    {
      id: 648911,
      title: "Untitled",
      dueDate: null,
      url: `${TEST_BASE}/d2l/lms/dropbox/user/folder_submit_files.d2l?db=648911&grpid=0&ou=412690`,
      kind: "assignment",
    },
  ]);
});

test("maps a quiz onto the contract with the quizzing deep link", async (t) => {
  // Arrange — a different template and a different kind; the assignment link
  // applied to a quiz id is a well-formed URL for a folder that does not exist.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([440703]),
      quizzes: { 440703: raw(fixture("quizzes-440703.json")) },
    },
  });

  // Assert
  assert.deepStrictEqual(result.data.assignments[440703], [
    {
      id: 476481,
      title: "Module 1 Completion Quiz - What Is Research?",
      dueDate: null,
      url: `${TEST_BASE}/d2l/lms/quizzing/user/quiz_summary.d2l?qi=476481&ou=440703`,
      kind: "quiz",
    },
  ]);
});

test("lists a course's assignments before its quizzes, each in server order", async (t) => {
  // Arrange — order is pinned because Swift's MenuModel is Equatable and drives
  // a skip-rebuild: an order that depends on which request finished first makes
  // identical data compare unequal every refresh.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: { 412690: raw(fixture("dropbox-folders-412690.json")) },
      quizzes: { 412690: raw(fixture("quizzes-412690.json")) },
    },
  });

  // Assert
  assert.deepStrictEqual(
    result.data.assignments[412690].map((item) => [item.kind, item.id]),
    [
      ["assignment", 648911],
      ["quiz", 619243],
      ["quiz", 619244],
      ["quiz", 790340],
    ],
  );
});

test("gives every item exactly the five fields the contract names", async (t) => {
  // Arrange — IsHidden, GroupTypeId, ActivityId and 30 more stay out of the cache.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: { 412690: raw(fixture("dropbox-folders-with-due-date.json")) },
      quizzes: { 412690: raw(fixture("quizzes-412690.json")) },
    },
  });

  // Assert
  for (const item of result.data.assignments[412690]) {
    assert.deepStrictEqual(Object.keys(item).sort(), [...ITEM_KEYS].sort());
  }
});

test("strips the fractional seconds D2L sends off a due date", async (t) => {
  // Arrange — THE trap: Swift decodes data.json with `.iso8601`, which rejects
  // "2026-03-01T04:59:00.000Z". The daemon must hand over seconds precision.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: { 412690: raw(fixture("dropbox-folders-with-due-date.json")) },
    },
  });

  // Assert
  const dates = new Map(result.data.assignments[412690].map((item) => [item.id, item.dueDate]));
  assert.equal(dates.get(700001), "2026-03-01T04:59:00Z");
  assert.equal(dates.get(700002), "2026-09-15T23:59:00Z");
});

test("normalizes a quiz due date the same way", async (t) => {
  // Arrange
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      quizzes: { 412690: raw(fixture("quizzes-with-due-date.json")) },
    },
  });

  // Assert
  const dates = new Map(result.data.assignments[412690].map((item) => [item.id, item.dueDate]));
  assert.equal(dates.get(900101), "2026-03-01T04:59:00Z");
  assert.equal(dates.get(900102), "2026-09-15T23:59:00Z");
  for (const item of result.data.assignments[412690]) {
    if (item.dueDate !== null) assert.match(item.dueDate, ISO_SECONDS);
  }
});

test("keeps an item whose due date cannot be read, with no due date", async (t) => {
  // Arrange — fail OPEN on a date: throwing would cost every assignment in the
  // course, where this costs one line of one row.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: { 412690: raw(fixture("dropbox-folders-with-due-date.json")) },
    },
  });

  // Assert
  const broken = result.data.assignments[412690].find((item) => item.id === 700003);
  assert.equal(broken.title, "Assignment With A Broken Date");
  assert.equal(broken.dueDate, null);
});

test("records an empty list for a course that genuinely owes nothing", async (t) => {
  // Arrange — both routes answered, both empty. "No work" is data, and it must
  // be distinguishable from "we could not find out" (see the next test).
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: { 412690: raw(fixture("dropbox-folders-empty.json")) },
      quizzes: { 412690: raw(fixture("quizzes-empty.json")) },
    },
  });

  // Assert
  assert.deepStrictEqual(result.data.assignments[412690], []);
});

test("omits a course from the map when both of its routes failed", async (t) => {
  // Arrange — an ended course answers 403 on every content route, and that is
  // the steady state for last term, not an exception. Writing [] here would
  // claim the course owes nothing; leaving the key out says "unknown", which is
  // what lets the app keep whatever it already had for that course.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690, 440703]),
      dropbox: { 412690: status(403, "forbidden"), default: json([]) },
      quizzes: { 412690: status(403, "forbidden"), default: json({ Objects: [], Next: null }) },
    },
  });

  // Assert
  assert.equal(result.ok, true);
  assert.deepStrictEqual(Object.keys(result.data.assignments), ["440703"]);
});

test("one course's failure does not sink the courses that worked", async (t) => {
  // Arrange
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690, 440703]),
      dropbox: { 412690: new Error("socket hang up"), 440703: raw(fixture("dropbox-folders-440703.json")) },
      quizzes: { 412690: new Error("socket hang up") },
    },
  });

  // Assert
  assert.equal(result.ok, true);
  assert.equal(result.data.courses.length, 2);
  assert.equal(result.data.assignments[440703].length, 3);
});

test("keeps the assignments it fetched when only the quiz route failed", async (t) => {
  // Arrange — half the data beats none: a new route failing must not regress a
  // shipped one.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: { 412690: raw(fixture("dropbox-folders-412690.json")) },
      quizzes: { 412690: status(500, "server error") },
    },
  });

  // Assert
  assert.deepStrictEqual(
    result.data.assignments[412690].map((item) => item.id),
    [648911],
  );
});

test("keeps the quizzes it fetched when only the assignment route failed", async (t) => {
  // Arrange
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([440703]),
      dropbox: { 440703: raw(fixture("dropbox-folders-malformed.json")) },
      quizzes: { 440703: raw(fixture("quizzes-440703.json")) },
    },
  });

  // Assert
  assert.deepStrictEqual(
    result.data.assignments[440703].map((item) => item.kind),
    ["quiz"],
  );
});

test("refuses to read the assignment shape as zero quizzes", async (t) => {
  // Arrange — quizzes come wrapped in {"Objects": …} while dropbox folders are a
  // bare array. A decoder copy-pasted between them would report success with
  // nothing in it and quietly delete four quizzes.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: { 412690: raw(fixture("dropbox-folders-412690.json")) },
      quizzes: { 412690: raw(fixture("quizzes-bare-array.json")) },
    },
  });

  // Assert — the assignment survived; no quiz was invented from the bad shape.
  assert.deepStrictEqual(
    result.data.assignments[412690].map((item) => item.kind),
    ["assignment"],
  );
});

test("fails a course whose folder has no id rather than serving a subset", async (t) => {
  // Arrange — a missing Id makes the row unclickable; a course has a handful of
  // assignments, so silently serving the rest is indistinguishable from an
  // instructor having deleted them.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: {
        412690: json([
          { Id: 700001, Name: "Homework 3", DueDate: null },
          { Name: "No Id Here", DueDate: null },
        ]),
      },
      quizzes: { 412690: raw(fixture("quizzes-empty.json")) },
    },
  });

  // Assert — the quiz route succeeded (empty), so the key exists but carries
  // nothing from the broken route.
  assert.deepStrictEqual(result.data.assignments[412690], []);
});

test("keeps a whole run alive when one course's route shows the session stub", async (t) => {
  // Arrange — the DECISION: only the mint and the enrollments call, the two
  // whole-run steps, may report sessionExpired. A stub on one course's content
  // route is treated as that course failing. A session that has really died is
  // caught by the very next run's mint, so this self-heals in one cycle instead
  // of holding 27 courses hostage to one odd route.
  const { result } = await fetchWith(t, {
    routes: {
      enrollments: enrollmentsFor([412690, 440703]),
      dropbox: { 412690: sessionExpiredStub(), 440703: raw(fixture("dropbox-folders-440703.json")) },
      quizzes: { 412690: sessionExpiredStub() },
    },
  });

  // Assert
  assert.equal(result.ok, true);
  assert.deepStrictEqual(Object.keys(result.data.assignments), ["440703"]);
});

test("tells the log which course it could not fetch", async (t) => {
  // Arrange
  const journal = recorder();

  // Act
  await fetchWith(t, {
    log: journal.log,
    routes: {
      enrollments: enrollmentsFor([412690]),
      dropbox: { 412690: status(403, "forbidden") },
      quizzes: { 412690: status(403, "forbidden") },
    },
  });

  // Assert — a course silently missing from the cache is a bug nobody can see.
  assert.match(journal.text(), /412690/);
});

// ---------------------------------------------------------------------------
// The payload the orchestrator receives.
// ---------------------------------------------------------------------------

test("returns the payload without a fetchedAt of its own", async (t) => {
  // Arrange — the orchestrator stamps that from the injected clock; a fetcher's
  // own timestamp would override it and make the freshness untestable.
  const { result } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([412690]) } });

  // Assert
  assert.deepStrictEqual(Object.keys(result.data).sort(), ["assignments", "courses"]);
});

test("keys the assignments map by course id", async (t) => {
  // Arrange / Act
  const { result } = await fetchWith(t, { routes: { enrollments: enrollmentsFor([412690, 440703]) } });

  // Assert
  assert.deepStrictEqual(Object.keys(result.data.assignments).sort(), ["412690", "440703"]);
});

// ---------------------------------------------------------------------------
// Secrets discipline (D7) — the cookie, the CSRF token and the JWT are read
// from session.json, sent as headers, and never spoken of again.
// ---------------------------------------------------------------------------

test("never says a credential out loud on a successful run", async (t) => {
  // Arrange
  const journal = recorder();

  // Act
  await fetchWith(t, { log: journal.log, routes: { enrollments: enrollmentsFor([412690, 440703]) } });

  // Assert
  for (const secret of SECRETS) {
    assert.ok(!journal.text().includes(secret), `the log leaked ${secret.slice(0, 12)}…`);
  }
});

test("never says a credential out loud when everything fails", async (t) => {
  // Arrange — the tempting moment to dump the request that failed.
  const journal = recorder();

  // Act
  const { result } = await fetchWith(t, {
    log: journal.log,
    routes: { mint: status(500, "internal error") },
  });

  // Assert
  const spoken = `${journal.text()}\n${JSON.stringify(result)}`;
  for (const secret of SECRETS) {
    assert.ok(!spoken.includes(secret), `the failure path leaked ${secret.slice(0, 12)}…`);
  }
});

test("keeps credentials out of the payload it hands the cache writer", async (t) => {
  // Arrange — cache/ is the one directory Swift reads. Nothing from
  // session.json may cross into it.
  const { result } = await fetchWith(t);

  // Assert
  const payload = JSON.stringify(result.data);
  for (const secret of SECRETS) {
    assert.ok(!payload.includes(secret), `the payload leaked ${secret.slice(0, 12)}…`);
  }
});
