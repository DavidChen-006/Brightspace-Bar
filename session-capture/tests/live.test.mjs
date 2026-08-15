/**
 * Live-tenant checks — the ones no fixture can make.
 *
 * SKIPPED unless `BS_LIVE=1`, and skipped again at runtime when the real root
 * has no credentials to try. `npm test` on any machine, at any time, must stay
 * hermetic and green; this file is the manual gate the plan calls tier 0 and
 * tier 1:
 *
 *   tier 0 — a live session is in place → the real fetcher refetches. Zero human.
 *   tier 1 — the D2L session is dead but the Entra profile survives → the silent
 *            rung re-mints it. Zero human.
 *
 * Tier 2 (the headed login, one MFA) is deliberately absent: it needs David in
 * front of the screen and belongs to the phase-4 E2E script.
 *
 * What is being proved here is exactly the thing the hermetic suite cannot: that
 * the endpoints, the header names and the payload shapes pinned against recorded
 * fixtures are still what Brightspace actually answers today. Both outcomes of
 * the tier-0 fetch are accepted — courses, or `sessionExpired` — because which
 * one comes back is the tenant's call, not the code's.
 *
 * These run against the REAL BSB_ROOT and read the real session.json. They write
 * nothing the daemon would not legitimately write: the fetcher writes nothing at
 * all, and the silent rung writes the session.json it just captured.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, statSync } from "node:fs";
import { createFetcher } from "../src/fetch-engine.mjs";
import { createSilentRung } from "../src/rungs/silent.mjs";
import { resolvePaths } from "../src/paths.mjs";
import { COURSE_KEYS, ISO_SECONDS, ITEM_KEYS } from "./phase2-helpers.mjs";

const skip = process.env.BS_LIVE === "1" ? false : "set BS_LIVE=1 to run against the live tenant";

const paths = resolvePaths();
const log = (message) => console.error(`[live] ${message}`);

/**
 * One fetch, shared by every claim below. Deliberate: a fetch is ~55 requests
 * against David's real tenant, and running it once per assertion would be rude
 * to Brightspace for no extra confidence.
 */
let pending = null;
const liveFetch = () => (pending ??= createFetcher().fetch({ paths, log }));

/** Skips the test from the inside when the real root has nothing to work with. */
function requireSession(t) {
  if (!existsSync(paths.sessionFile)) {
    t.skip(`no session.json at ${paths.sessionFile} — run npm run capture first`);
    return false;
  }
  return true;
}

test("the live tenant answers with courses, or says the session is dead", { skip }, async (t) => {
  // Arrange
  if (!requireSession(t)) return;

  // Act
  const result = await liveFetch();

  // Assert — both are correct answers; what is forbidden is a third one.
  if (result.ok) {
    assert.ok(result.data.courses.length > 0, "a live session with zero courses is a parse failure");
  } else {
    assert.equal(result.reason, "sessionExpired", `unexpected failure: ${result.detail ?? ""}`);
  }
});

test("every live course matches the data.json contract", { skip }, async (t) => {
  // Arrange
  if (!requireSession(t)) return;
  const result = await liveFetch();
  if (!result.ok) return t.skip("the live session is expired");

  // Act / Assert
  for (const course of result.data.courses) {
    assert.deepStrictEqual(Object.keys(course).sort(), [...COURSE_KEYS].sort());
    assert.equal(typeof course.id, "number");
    assert.equal(typeof course.name, "string");
    assert.equal(typeof course.isActive, "boolean");
  }
});

test("every live assignment and quiz matches the data.json contract", { skip }, async (t) => {
  // Arrange
  if (!requireSession(t)) return;
  const result = await liveFetch();
  if (!result.ok) return t.skip("the live session is expired");

  // Act / Assert
  const courseIds = new Set(result.data.courses.map((course) => String(course.id)));
  for (const [courseId, items] of Object.entries(result.data.assignments)) {
    assert.ok(courseIds.has(courseId), `${courseId} is not an enrolled course`);
    for (const item of items) {
      assert.deepStrictEqual(Object.keys(item).sort(), [...ITEM_KEYS].sort());
      assert.ok(["assignment", "quiz"].includes(item.kind), `unknown kind ${item.kind}`);
      assert.match(item.url, /^https:\/\//);
      // The form Swift's `.iso8601` decoder accepts — the whole reason dates
      // are normalized rather than passed through.
      if (item.dueDate !== null) assert.match(item.dueDate, ISO_SECONDS);
    }
  }
});

test("the silent rung re-mints a session from the Entra profile", { skip }, async (t) => {
  // Arrange — tier 1. Needs the persistent profile (the ~90-day wristband);
  // without it this is tier 2 and wants a human.
  if (!existsSync(paths.profileDir)) {
    return t.skip(`no profile at ${paths.profileDir} — tier 1 needs the Entra wristband`);
  }

  // Act — the real browser, no injected capture.
  const result = await createSilentRung().attempt({ paths, log });

  // Assert
  assert.equal(result.ok, true, `silent SSO failed: ${result.reason ?? ""}`);
  const session = JSON.parse(readFileSync(paths.sessionFile, "utf8"));
  assert.ok(session.cookieHeader.includes("d2lSessionVal="), "no session cookie was captured");
  assert.equal(statSync(paths.sessionFile).mode & 0o777, 0o600);
});
