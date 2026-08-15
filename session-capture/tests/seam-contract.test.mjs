/**
 * The seam contract: every rung and every fetcher — the fakes the orchestrator
 * suite is built on AND the real implementations phase 2 adds — answering the
 * same questions.
 *
 * Priority this file defends: THE FAKES CANNOT DRIFT. Phase 1's 46 tests prove
 * the ladder is correct against scripted fakes. That proof is worth exactly as
 * much as the claim that the real rung and the real fetcher answer in the same
 * vocabulary — the same `kind` strings, the same `ok` shape, the same
 * `sessionExpired` spelling. Nothing else in the suite compares the two, so a
 * real fetcher reporting `session_expired`, or a real rung whose kind is
 * "silent-sso", would pass every other test in the package and strand the
 * ladder in production.
 *
 * Behavior axis: invariants only. The interesting per-implementation cases live
 * in fetch-engine.test.mjs and rungs.test.mjs; what is checked here is the
 * handful of properties that must hold for EVERY implementation of the seam.
 *
 * Scope: small. Both seams are exercised with their I/O injected.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { createFetcher } from "../src/fetch-engine.mjs";
import { createSilentRung } from "../src/rungs/silent.mjs";
import { createFullLoginRung } from "../src/rungs/full-login.mjs";
import { SAMPLE_DATA, expired, ladder, ok, scriptedFetcher, tempPaths } from "./helpers.mjs";
import { enrollmentsFor, fakeCapture, fakeHttp, writeSessionFile } from "./phase2-helpers.mjs";

/** Every rung implementation, in the two states the orchestrator reacts to. */
function rungCases() {
  const { rung } = ladder();
  const failing = { ok: false, reason: "the entra cookie has expired" };
  return [
    {
      name: "the scripted fake",
      succeeding: rung("fake-silent"),
      failing: rung("fake-silent-failing", { result: failing }),
    },
    {
      name: "the silent rung",
      succeeding: createSilentRung({ capture: fakeCapture() }),
      failing: createSilentRung({ capture: fakeCapture({ result: failing }) }),
    },
    {
      name: "the full-login rung",
      succeeding: createFullLoginRung({ capture: fakeCapture() }),
      failing: createFullLoginRung({ capture: fakeCapture({ result: failing }) }),
    },
  ];
}

/**
 * Every fetcher implementation, in the three states the ladder branches on.
 * The real one is driven into each state through its HTTP seam and its
 * credentials: an empty root is a dead session, a refused socket is transport.
 */
function fetcherCases() {
  const real = (routes) => createFetcher({ http: fakeHttp(routes) });
  return [
    {
      name: "the scripted fake",
      succeeding: scriptedFetcher([ok(SAMPLE_DATA)]),
      expiring: scriptedFetcher([expired()]),
      failing: scriptedFetcher([{ ok: false, reason: "transport", detail: "ECONNREFUSED" }]),
      credentials: false,
    },
    {
      name: "the real fetcher",
      succeeding: real({ enrollments: enrollmentsFor([412690, 440703]) }),
      expiring: real({}),
      failing: real({ enrollments: new Error("ECONNREFUSED") }),
      credentials: true,
    },
  ];
}

for (const { name, succeeding, failing } of rungCases()) {
  test(`${name} declares a kind the permission gate recognizes`, () => {
    // Arrange / Act / Assert — "silent" or "full", exactly; the orchestrator
    // compares these strings to decide whether cron may climb.
    assert.ok(
      ["silent", "full"].includes(succeeding.kind),
      `kind was ${JSON.stringify(succeeding.kind)}`,
    );
  });

  test(`${name} takes the world as one argument and answers with a verdict`, async (t) => {
    // Arrange
    const paths = tempPaths(t);

    // Act
    const result = await succeeding.attempt({ paths, log: () => {} });

    // Assert
    assert.equal(typeof succeeding.attempt, "function");
    assert.equal(typeof result.ok, "boolean");
  });

  test(`${name} says why when it fails`, async (t) => {
    // Arrange — the orchestrator logs this reason and keeps climbing; an
    // undefined one turns a diagnosable failure into "no reason given".
    const paths = tempPaths(t);

    // Act
    const result = await failing.attempt({ paths, log: () => {} });

    // Assert
    assert.equal(result.ok, false);
    assert.equal(typeof result.reason, "string");
    assert.ok(result.reason.length > 0);
  });
}

for (const { name, succeeding, expiring, failing, credentials } of fetcherCases()) {
  /** The real fetcher needs credentials on disk; the fake ignores them. */
  const world = (t, { withSession }) => {
    const paths = tempPaths(t);
    if (credentials && withSession) writeSessionFile(paths);
    return { paths, log: () => {} };
  };

  test(`${name} returns the payload without stamping its own fetchedAt`, async (t) => {
    // Arrange / Act
    const result = await succeeding.fetch(world(t, { withSession: true }));

    // Assert — the orchestrator owns that timestamp.
    assert.equal(result.ok, true);
    assert.ok(Array.isArray(result.data.courses));
    assert.equal(typeof result.data.assignments, "object");
    assert.equal(result.data.fetchedAt, undefined);
  });

  test(`${name} spells an expired session exactly sessionExpired`, async (t) => {
    // Arrange — the ONE reason that climbs the ladder. Any other spelling and
    // a re-mintable lapse becomes a permanent error state.
    const result = await expiring.fetch(world(t, { withSession: false }));

    // Assert
    assert.deepStrictEqual(result, { ok: false, reason: "sessionExpired" });
  });

  test(`${name} reports a non-session failure under a different reason`, async (t) => {
    // Arrange — anything but sessionExpired here, or the daemon logs a human in
    // to fix a network outage.
    const result = await failing.fetch(world(t, { withSession: true }));

    // Assert
    assert.equal(result.ok, false);
    assert.equal(typeof result.reason, "string");
    assert.notEqual(result.reason, "sessionExpired");
  });
}
