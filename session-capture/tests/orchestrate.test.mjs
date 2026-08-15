/**
 * orchestrate.mjs — the ladder, the cache write, and the honest status.
 *
 * Priorities these tests defend (everything else was culled):
 *
 *  1. DATA INTEGRITY. A refresh that fails must leave the app exactly as well
 *     off as it was: the existing data.json survives byte-for-byte, no partial
 *     or temp file is ever left behind, and status.json says the true thing.
 *     This is the anti-pattern the plan names — the auth trapdoor that wipes
 *     the cache when login lapses. The menu must never blank.
 *  2. LADDER PERMISSION. Rungs are walked in order, and a `full` rung — the one
 *     that puts a browser in front of a human — is attempted ONLY when the
 *     caller proved a human is present. A timer spawn may climb rung 1 and
 *     nothing more; if this is wrong, cron pops browsers at 3am.
 *
 * Scope: small. The clock, the rungs and the fetcher are injected fakes; the
 * only real I/O is a temp BSB_ROOT, because atomicity is a claim about files
 * and nothing smaller than a filesystem can verify it.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { exitCode, runRefresh } from "../src/orchestrate.mjs";
import {
  FIXED_ISO,
  REFETCHED_DATA,
  SAMPLE_DATA,
  expired,
  fixedClock,
  ladder,
  ok,
  recorder,
  scriptedFetcher,
  tempPaths,
  throwingFetcher,
  transport,
} from "./helpers.mjs";

/** The deps every test starts from; each test overrides only what it is about. */
function deps(paths, overrides = {}) {
  return {
    paths,
    clock: fixedClock,
    rungs: [],
    fetcher: scriptedFetcher([ok(SAMPLE_DATA)]),
    allowFullLogin: false,
    log: () => {},
    ...overrides,
  };
}

const readJson = (file) => JSON.parse(readFileSync(file, "utf8"));

// ---------------------------------------------------------------------------
// Happy path — the fetch works on the credentials already on disk.
// ---------------------------------------------------------------------------

test("writes the fetched payload to data.json, stamped with the injected clock", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  await runRefresh(deps(paths));

  // Assert
  assert.deepStrictEqual(readJson(paths.dataFile), { fetchedAt: FIXED_ISO, ...SAMPLE_DATA });
});

test("reports state fresh with rungUsed none in status.json", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  await runRefresh(deps(paths));

  // Assert
  assert.deepStrictEqual(readJson(paths.statusFile), {
    state: "fresh",
    rungUsed: "none",
    lastAttemptAt: FIXED_ISO,
    lastSuccessAt: FIXED_ISO,
    error: null,
  });
});

test("returns the same status object it wrote to disk", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  const result = await runRefresh(deps(paths));

  // Assert
  assert.deepStrictEqual(result, readJson(paths.statusFile));
});

test("never touches a rung when the existing credentials still work", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { attempted, rung } = ladder();

  // Act
  await runRefresh(deps(paths, { rungs: [rung("silent-1"), rung("full-1", { kind: "full" })] }));

  // Assert
  assert.deepStrictEqual(attempted, []);
});

test("hands the resolved paths to the fetcher and to each rung it attempts", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { rung } = ladder();
  const climbed = rung("silent-1");
  const fetcher = scriptedFetcher([expired(), ok(SAMPLE_DATA)]);

  // Act
  await runRefresh(deps(paths, { rungs: [climbed], fetcher }));

  // Assert
  assert.equal(fetcher.calls[0].paths, paths);
  assert.equal(climbed.calls[0].paths, paths);
  assert.equal(typeof climbed.calls[0].log, "function");
});

// ---------------------------------------------------------------------------
// The ladder — order, permission, and the refetch that follows a rung.
// ---------------------------------------------------------------------------

test("walks the rungs in order and stops at the first one that succeeds", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { attempted, rung } = ladder();
  const rungs = [
    rung("first", { result: { ok: false, reason: "no entra cookie" } }),
    rung("second"),
    rung("third"),
  ];

  // Act
  await runRefresh(
    deps(paths, { rungs, fetcher: scriptedFetcher([expired(), ok(SAMPLE_DATA)]) }),
  );

  // Assert
  assert.deepStrictEqual(attempted, ["first", "second"]);
});

test("refetches after a rung succeeds and keeps the data from the retry", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { rung } = ladder();
  const fetcher = scriptedFetcher([expired(), ok(REFETCHED_DATA)]);

  // Act
  await runRefresh(deps(paths, { rungs: [rung("silent-1")], fetcher }));

  // Assert
  assert.deepStrictEqual(readJson(paths.dataFile), { fetchedAt: FIXED_ISO, ...REFETCHED_DATA });
});

test("records rungUsed silent when a silent rung restored the session", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { rung } = ladder();

  // Act
  const result = await runRefresh(
    deps(paths, {
      rungs: [rung("silent-1")],
      fetcher: scriptedFetcher([expired(), ok(SAMPLE_DATA)]),
    }),
  );

  // Assert
  assert.equal(result.rungUsed, "silent");
});

test("records rungUsed full when a full rung restored the session", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { rung } = ladder();

  // Act
  const result = await runRefresh(
    deps(paths, {
      rungs: [rung("full-1", { kind: "full" })],
      allowFullLogin: true,
      fetcher: scriptedFetcher([expired(), ok(SAMPLE_DATA)]),
    }),
  );

  // Assert
  assert.equal(result.rungUsed, "full");
});

test("skips a full rung when full login was not allowed", async (t) => {
  // Arrange — the cron case: a timer spawn may climb rung 1 and no further.
  const paths = tempPaths(t);
  const { attempted, rung } = ladder();
  const rungs = [rung("silent-1", { result: { ok: false, reason: "entra expired" } }), rung("full-1", { kind: "full" })];

  // Act
  const result = await runRefresh(
    deps(paths, { rungs, allowFullLogin: false, fetcher: scriptedFetcher([expired()]) }),
  );

  // Assert
  assert.deepStrictEqual(attempted, ["silent-1"]);
  assert.equal(result.state, "needs-login");
});

test("keeps climbing when a rung succeeds but the session is still expired", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { attempted, rung } = ladder();
  const rungs = [rung("silent-1"), rung("full-1", { kind: "full" })];
  const fetcher = scriptedFetcher([expired(), expired(), ok(SAMPLE_DATA)]);

  // Act
  const result = await runRefresh(deps(paths, { rungs, allowFullLogin: true, fetcher }));

  // Assert
  assert.deepStrictEqual(attempted, ["silent-1", "full-1"]);
  assert.equal(result.state, "fresh");
  assert.equal(result.rungUsed, "full");
});

test("treats a rung that throws as a failed rung and climbs on", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { attempted, rung } = ladder();
  const rungs = [rung("silent-1", { throws: "playwright exploded" }), rung("silent-2")];

  // Act
  const result = await runRefresh(
    deps(paths, { rungs, fetcher: scriptedFetcher([expired(), ok(SAMPLE_DATA)]) }),
  );

  // Assert
  assert.deepStrictEqual(attempted, ["silent-1", "silent-2"]);
  assert.equal(result.state, "fresh");
});

// ---------------------------------------------------------------------------
// Ladder exhausted — the state that must NOT destroy anything.
// ---------------------------------------------------------------------------

test("reports needs-login when every rung failed", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { rung } = ladder();
  const rungs = [rung("silent-1", { result: { ok: false, reason: "entra expired" } })];

  // Act
  const result = await runRefresh(deps(paths, { rungs, fetcher: scriptedFetcher([expired()]) }));

  // Assert
  assert.equal(result.state, "needs-login");
  assert.equal(result.rungUsed, "none");
  assert.equal(result.lastAttemptAt, FIXED_ISO);
  assert.equal(result.lastSuccessAt, null);
});

test("reports needs-login when there are no rungs at all", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  const result = await runRefresh(
    deps(paths, { rungs: [], fetcher: scriptedFetcher([expired()]) }),
  );

  // Assert
  assert.equal(result.state, "needs-login");
});

test("leaves an existing data.json byte-for-byte intact when the ladder is exhausted", async (t) => {
  // Arrange — the .preservedStale mirror: yesterday's courses beat no courses.
  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  const stale = JSON.stringify({ fetchedAt: "2026-08-01T00:00:00.000Z", ...SAMPLE_DATA }, null, 2);
  writeFileSync(paths.dataFile, stale);
  const before = readFileSync(paths.dataFile);

  // Act
  await runRefresh(deps(paths, { rungs: [], fetcher: scriptedFetcher([expired()]) }));

  // Assert
  assert.deepStrictEqual(readFileSync(paths.dataFile), before);
});

test("writes no data.json at all when it fails and none existed", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  await runRefresh(deps(paths, { rungs: [], fetcher: scriptedFetcher([expired()]) }));

  // Assert
  assert.deepStrictEqual(readdirSync(paths.cacheDir), ["status.json"]);
});

test("carries lastSuccessAt forward from the previous status when a run fails", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(
    paths.statusFile,
    JSON.stringify({
      state: "fresh",
      rungUsed: "none",
      lastAttemptAt: "2026-08-01T00:00:00.000Z",
      lastSuccessAt: "2026-08-01T00:00:00.000Z",
      error: null,
    }),
  );

  // Act
  const result = await runRefresh(deps(paths, { rungs: [], fetcher: scriptedFetcher([expired()]) }));

  // Assert
  assert.equal(result.lastSuccessAt, "2026-08-01T00:00:00.000Z");
  assert.equal(result.state, "needs-login");
});

test("survives a corrupt previous status.json", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(paths.statusFile, "{ this is not json");

  // Act
  const result = await runRefresh(deps(paths, { rungs: [], fetcher: scriptedFetcher([expired()]) }));

  // Assert
  assert.equal(result.state, "needs-login");
  assert.equal(result.lastSuccessAt, null);
});

// ---------------------------------------------------------------------------
// Transport failure — the network is down, the session is fine.
// ---------------------------------------------------------------------------

test("does not climb the ladder when the failure was transport, not the session", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { attempted, rung } = ladder();

  // Act
  const result = await runRefresh(
    deps(paths, { rungs: [rung("silent-1")], fetcher: scriptedFetcher([transport()]) }),
  );

  // Assert
  assert.deepStrictEqual(attempted, []);
  assert.equal(result.state, "error");
});

test("puts the transport detail in the status error", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const fetcher = scriptedFetcher([transport("getaddrinfo ENOTFOUND purdue.brightspace.com")]);

  // Act
  await runRefresh(deps(paths, { fetcher }));

  // Assert
  assert.match(readJson(paths.statusFile).error, /ENOTFOUND purdue\.brightspace\.com/);
});

test("preserves existing data.json through a transport failure", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(paths.dataFile, JSON.stringify({ fetchedAt: "2026-08-01T00:00:00.000Z", ...SAMPLE_DATA }));
  const before = readFileSync(paths.dataFile);

  // Act
  await runRefresh(deps(paths, { fetcher: scriptedFetcher([transport()]) }));

  // Assert
  assert.deepStrictEqual(readFileSync(paths.dataFile), before);
});

test("maps an unexpected throw to state error instead of rejecting", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  const result = await runRefresh(deps(paths, { fetcher: throwingFetcher("boom in the fetcher") }));

  // Assert
  assert.equal(result.state, "error");
  assert.match(result.error, /boom in the fetcher/);
});

// ---------------------------------------------------------------------------
// Atomic writes — the Swift app reads these files while the daemon writes them.
// ---------------------------------------------------------------------------

test("leaves nothing but data.json and status.json in the cache after a run", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  await runRefresh(deps(paths));

  // Assert — a temp file left behind means a reader can meet a half-written cache.
  assert.deepStrictEqual(readdirSync(paths.cacheDir).sort(), ["data.json", "status.json"]);
});

test("removes its temp file when the final rename fails", async (t) => {
  // Arrange — data.json as a directory makes the rename fail at the last step.
  const paths = tempPaths(t);
  mkdirSync(paths.dataFile, { recursive: true });

  // Act
  const result = await runRefresh(deps(paths));

  // Assert
  assert.deepStrictEqual(readdirSync(paths.cacheDir).sort(), ["data.json", "status.json"]);
  assert.equal(result.state, "error");
});

test("writes a cache the app can always parse", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  await runRefresh(deps(paths));

  // Assert
  for (const file of [paths.dataFile, paths.statusFile]) {
    assert.ok(statSync(file).size > 0, `${file} is empty`);
    JSON.parse(readFileSync(file, "utf8"));
  }
});

// ---------------------------------------------------------------------------
// Secrets discipline (D7) — credentials stay in session.json, and only there.
// ---------------------------------------------------------------------------

const SECRET = "d2lSessionVal-SUPERSECRET-cookie-value";

/** A rung that captures credentials the way a real one does: into session.json. */
function capturingRung(rung) {
  return rung("silent-1", {
    onAttempt: ({ paths }) => {
      writeFileSync(paths.sessionFile, JSON.stringify({ cookieHeader: `d2lSessionVal=${SECRET}` }));
    },
  });
}

test("never puts a captured credential into the log", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { rung } = ladder();
  const journal = recorder();

  // Act
  await runRefresh(
    deps(paths, {
      rungs: [capturingRung(rung)],
      fetcher: scriptedFetcher([expired(), ok(SAMPLE_DATA)]),
      log: journal.log,
    }),
  );

  // Assert
  assert.ok(!journal.text().includes(SECRET), `log leaked a credential:\n${journal.text()}`);
});

test("never puts a captured credential into the cache files", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const { rung } = ladder();

  // Act
  await runRefresh(
    deps(paths, {
      rungs: [capturingRung(rung)],
      fetcher: scriptedFetcher([expired(), ok(SAMPLE_DATA)]),
    }),
  );

  // Assert — cache/ is the only directory Swift reads; secrets never cross it.
  for (const file of [paths.dataFile, paths.statusFile]) {
    const contents = readFileSync(file, "utf8");
    assert.ok(!contents.includes(SECRET), `${file} leaked a credential`);
  }
});

// ---------------------------------------------------------------------------
// exitCode — the pure mapping the CLI hands to Swift.
// ---------------------------------------------------------------------------

test("maps a fresh result to exit 0", () => {
  // Arrange
  const result = { state: "fresh", rungUsed: "none", error: null };

  // Act / Assert
  assert.equal(exitCode(result), 0);
});

test("maps a needs-login result to exit 2", () => {
  // Arrange
  const result = { state: "needs-login", rungUsed: "none", error: null };

  // Act / Assert
  assert.equal(exitCode(result), 2);
});

test("maps an error result to exit 1", () => {
  // Arrange
  const result = { state: "error", rungUsed: "none", error: "transport" };

  // Act / Assert
  assert.equal(exitCode(result), 1);
});

test("maps an unrecognized state to exit 1", () => {
  // Arrange
  const result = { state: "who-knows", rungUsed: "none", error: null };

  // Act / Assert
  assert.equal(exitCode(result), 1);
});
