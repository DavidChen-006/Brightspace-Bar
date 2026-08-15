/**
 * The two real rungs: `src/rungs/silent.mjs` (kind "silent", no human) and
 * `src/rungs/full-login.mjs` (kind "full", a human approves the MFA).
 *
 * Priorities these tests defend (everything else was culled):
 *
 *  1. THE CREDENTIAL LANDS, CORRECTLY AND PRIVATELY. A rung's return value is
 *     only a verdict — the actual product is session.json at paths.sessionFile,
 *     in the shape `buildSession` writes, readable by nobody but its owner
 *     (0600). A rung that reports ok while writing the file somewhere else
 *     sends the orchestrator into an unbreakable refetch loop.
 *  2. HONEST VERDICTS. `ok: false` with a reason, never a throw and never a
 *     false positive, because a rung that lies about success makes the ladder
 *     stop climbing at the rung that did nothing.
 *
 * Scope: small. NO BROWSER LAUNCHES HERE. The playwright choreography lives
 * behind the injected `capture` seam and is exercised by the BS_LIVE tests;
 * what is pinned here is everything the rung itself does with the seam's answer.
 *
 * Both rungs are run through the same claims: they differ in `kind` and in
 * which default capture they carry, and in nothing else this file can see.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { createSilentRung } from "../src/rungs/silent.mjs";
import { createFullLoginRung } from "../src/rungs/full-login.mjs";
import { recorder, tempPaths } from "./helpers.mjs";
import { CAPTURED_COOKIES, CSRF_TOKEN, SECRETS, TEST_BASE, fakeCapture } from "./phase2-helpers.mjs";

/** The two implementations under test, and the kind each one must declare. */
const RUNGS = [
  { name: "the silent rung", create: createSilentRung, kind: "silent" },
  { name: "the full-login rung", create: createFullLoginRung, kind: "full" },
];

const readSession = (paths) => JSON.parse(readFileSync(paths.sessionFile, "utf8"));

// ---------------------------------------------------------------------------
// The seam itself.
// ---------------------------------------------------------------------------

test("the silent rung is the cron-safe kind", () => {
  // Arrange / Act
  const rung = createSilentRung({ capture: fakeCapture() });

  // Assert — the exact string the orchestrator's permission gate compares.
  assert.equal(rung.kind, "silent");
});

test("the full-login rung is the kind that needs a present human", () => {
  // Arrange / Act
  const rung = createFullLoginRung({ capture: fakeCapture() });

  // Assert — anything but "full" and cron pops a browser at 3am.
  assert.equal(rung.kind, "full");
});

for (const { name, create, kind } of RUNGS) {
  // -------------------------------------------------------------------------
  // Success — the credential lands.
  // -------------------------------------------------------------------------

  test(`${name} reports ok when the browser came back with cookies`, async (t) => {
    // Arrange
    const paths = tempPaths(t);
    const rung = create({ capture: fakeCapture() });

    // Act
    const result = await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.deepStrictEqual(result, { ok: true });
  });

  test(`${name} writes the captured session to paths.sessionFile`, async (t) => {
    // Arrange — the file the fetcher reads next. Anywhere else and the ladder
    // climbs forever.
    const paths = tempPaths(t);
    const rung = create({ capture: fakeCapture() });

    // Act
    await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.equal(readSession(paths).csrfToken, CSRF_TOKEN);
  });

  test(`${name} writes the session in the shape buildSession defines`, async (t) => {
    // Arrange — one definition of session.json across every capture path.
    const paths = tempPaths(t);
    const rung = create({ capture: fakeCapture() });

    // Act
    await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.deepStrictEqual(
      Object.keys(readSession(paths)).sort(),
      ["baseUrl", "capturedAt", "cookieHeader", "cookies", "csrfToken", "landedUrl"],
    );
  });

  test(`${name} builds the cookie header in the canonical order`, async (t) => {
    // Arrange — the fake hands them back reversed, the way a real cookie jar
    // might. A stable order is what makes a diff of session.json mean "the
    // session changed" rather than "the jar iterated differently".
    const paths = tempPaths(t);
    const rung = create({ capture: fakeCapture({ result: okCapture(CAPTURED_COOKIES) }) });

    // Act
    await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.equal(
      readSession(paths).cookieHeader,
      "d2lSessionVal=SECRET-session-abc123; d2lSecureSessionVal=SECRET-secure-def456",
    );
  });

  test(`${name} stamps when the credential was captured`, async (t) => {
    // Arrange — capturedAt is the only honest thing to print about a
    // credential file, and refresh-session.sh reports an age from it.
    const paths = tempPaths(t);
    const before = Date.now();
    const rung = create({ capture: fakeCapture() });

    // Act
    await rung.attempt({ paths, log: () => {} });

    // Assert
    const { capturedAt } = readSession(paths);
    assert.equal(typeof capturedAt, "number");
    assert.ok(capturedAt >= before, "capturedAt predates the capture");
  });

  test(`${name} leaves the credential file readable only by its owner`, async (t) => {
    // Arrange
    const paths = tempPaths(t);
    const rung = create({ capture: fakeCapture() });

    // Act
    await rung.attempt({ paths, log: () => {} });

    // Assert — 0600. A live D2L cookie is a login.
    assert.equal(statSync(paths.sessionFile).mode & 0o777, 0o600);
  });

  test(`${name} tightens the permissions on a session file that already existed`, async (t) => {
    // Arrange — a rewrite must not inherit a loose mode from the old file.
    const paths = tempPaths(t);
    writeFileSync(paths.sessionFile, "{}", { mode: 0o644 });
    const rung = create({ capture: fakeCapture() });

    // Act
    await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.equal(statSync(paths.sessionFile).mode & 0o777, 0o600);
  });

  // -------------------------------------------------------------------------
  // The world the rung hands the browser.
  // -------------------------------------------------------------------------

  test(`${name} drives the browser on the profile under BSB_ROOT`, async (t) => {
    // Arrange — the Entra wristband lives in exactly one directory, and a rung
    // pointed at another one silently loses a 90-day session.
    const paths = tempPaths(t);
    const capture = fakeCapture();

    // Act
    await create({ capture }).attempt({ paths, log: () => {} });

    // Assert
    assert.equal(capture.calls[0].profileDir, paths.profileDir);
  });

  test(`${name} defaults to the production tenant`, async (t) => {
    // Arrange
    const paths = tempPaths(t);
    const previous = process.env.BS_BASE_URL;
    delete process.env.BS_BASE_URL;
    t.after(() => {
      if (previous === undefined) delete process.env.BS_BASE_URL;
      else process.env.BS_BASE_URL = previous;
    });
    const capture = fakeCapture();

    // Act — the default is read when the rung is built, not when it is imported.
    await create({ capture }).attempt({ paths, log: () => {} });

    // Assert
    assert.equal(capture.calls[0].baseUrl, "https://purdue.brightspace.com");
    assert.equal(readSession(paths).baseUrl, "https://purdue.brightspace.com");
  });

  test(`${name} honors an explicitly configured tenant`, async (t) => {
    // Arrange
    const paths = tempPaths(t);
    const capture = fakeCapture();

    // Act
    await create({ capture, baseUrl: TEST_BASE }).attempt({ paths, log: () => {} });

    // Assert
    assert.equal(capture.calls[0].baseUrl, TEST_BASE);
    assert.equal(readSession(paths).baseUrl, TEST_BASE);
  });

  test(`${name} hands the daemon's own log down to the browser`, async (t) => {
    // Arrange — "clicked the campus selector" has to reach the daemon's stderr,
    // or a rung that hangs is a rung nobody can debug.
    const paths = tempPaths(t);
    const journal = recorder();
    const capture = fakeCapture();

    // Act
    await create({ capture }).attempt({ paths, log: journal.log });

    // Assert
    assert.equal(typeof capture.calls[0].log, "function");
    capture.calls[0].log("clicked the campus selector");
    assert.match(journal.text(), /clicked the campus selector/);
  });

  // -------------------------------------------------------------------------
  // Failure — honest verdicts, and nothing destroyed on the way out.
  // -------------------------------------------------------------------------

  test(`${name} reports the reason the capture gave for failing`, async (t) => {
    // Arrange
    const paths = tempPaths(t);
    const rung = create({
      capture: fakeCapture({ result: { ok: false, reason: "the entra cookie has expired" } }),
    });

    // Act
    const result = await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.equal(result.ok, false);
    assert.match(result.reason, /entra cookie/);
  });

  test(`${name} reports a failure rather than throwing when the browser explodes`, async (t) => {
    // Arrange — a locked profile, a missing chromium: real, and not the
    // orchestrator's problem to interpret.
    const paths = tempPaths(t);
    const rung = create({ capture: fakeCapture({ throws: "browserType.launch: Target closed" }) });

    // Act
    const result = await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.equal(result.ok, false);
    assert.equal(typeof result.reason, "string");
    assert.ok(result.reason.length > 0, "a failed rung must say why");
  });

  test(`${name} writes no session file when the capture failed`, async (t) => {
    // Arrange
    const paths = tempPaths(t);
    const rung = create({ capture: fakeCapture({ result: { ok: false, reason: "timed out" } }) });

    // Act
    await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.throws(() => readFileSync(paths.sessionFile), { code: "ENOENT" });
  });

  test(`${name} leaves an existing session file untouched when the capture failed`, async (t) => {
    // Arrange — the ladder is climbed BECAUSE the session looked dead, but a
    // failed rung must not be the thing that destroys it.
    const paths = tempPaths(t);
    writeFileSync(paths.sessionFile, '{"cookieHeader":"yesterday"}');
    const before = readFileSync(paths.sessionFile);
    const rung = create({ capture: fakeCapture({ result: { ok: false, reason: "timed out" } }) });

    // Act
    await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.deepStrictEqual(readFileSync(paths.sessionFile), before);
  });

  test(`${name} reports a failure when the browser came back with no session cookie`, async (t) => {
    // Arrange — a login stub sets cookies too, so "some cookies" is not
    // authentication. An empty cookie header written as a success would be a
    // credential file that can never work.
    const paths = tempPaths(t);
    const rung = create({
      capture: fakeCapture({ result: okCapture([{ name: "ASP.NET_SessionId", value: "irrelevant" }]) }),
    });

    // Act
    const result = await rung.attempt({ paths, log: () => {} });

    // Assert
    assert.equal(result.ok, false);
  });

  // -------------------------------------------------------------------------
  // Secrets discipline (D7).
  // -------------------------------------------------------------------------

  test(`${name} never puts a captured credential in the log`, async (t) => {
    // Arrange — the daemon's log goes to stderr and, in phase 3, into a file
    // the Swift app spawned.
    const paths = tempPaths(t);
    const journal = recorder();

    // Act
    const result = await create({ capture: fakeCapture() }).attempt({ paths, log: journal.log });

    // Assert
    const spoken = `${journal.text()}\n${JSON.stringify(result)}`;
    for (const secret of SECRETS) {
      assert.ok(!spoken.includes(secret), `${name} leaked ${secret.slice(0, 12)}…`);
    }
  });
}

/** A successful capture carrying exactly the cookies a test wants to hand over. */
function okCapture(cookies) {
  return { ok: true, cookies, csrfToken: CSRF_TOKEN, landedUrl: `${TEST_BASE}/d2l/home` };
}
