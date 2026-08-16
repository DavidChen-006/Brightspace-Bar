/**
 * The deep-link wrap that makes a click land authenticated.
 *
 * Only the pure builder is tested here: the profile-open side is a headed
 * browser on a live tenant, which is the app's manual experiment (experiment
 * 19), not a unit under test. What CAN silently rot is the URL shape — the
 * endpoint path, the parameter names, the encoding — and that is what a mistyped
 * production click would get wrong, so that is what is pinned.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { initiateLoginTarget, SAML_ENTITY_ID } from "../src/browser-open.mjs";

const DEEP_LINK =
  "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=648911&grpid=0&ou=412690";

test("wraps a deep link in the SAML initiate-login endpoint on its own origin", () => {
  const wrapped = new URL(initiateLoginTarget(DEEP_LINK));
  assert.equal(wrapped.origin, "https://purdue.brightspace.com");
  assert.equal(wrapped.pathname, "/d2l/lp/auth/saml/initiate-login");
});

test("carries the entityId and the deep link's path+query as `target`", () => {
  const wrapped = new URL(initiateLoginTarget(DEEP_LINK));
  // Read back through URLSearchParams so the assertion is about the decoded
  // values, and the encoding is proven by the round trip rather than by
  // matching a hand-encoded string.
  assert.equal(wrapped.searchParams.get("entityId"), SAML_ENTITY_ID);
  assert.equal(
    wrapped.searchParams.get("target"),
    "/d2l/lms/dropbox/user/folder_submit_files.d2l?db=648911&grpid=0&ou=412690",
  );
});

test("drops the origin from `target` — only path+query cross the round trip", () => {
  const target = new URL(initiateLoginTarget(DEEP_LINK)).searchParams.get("target");
  assert.ok(!target.includes("purdue.brightspace.com"), "target must not carry the host");
  assert.ok(target.startsWith("/"), "target is an absolute path");
});

test("builds the initiate-login URL on whatever D2L host the link names", () => {
  const other = initiateLoginTarget("https://example.brightspace.com/d2l/home/42");
  assert.equal(new URL(other).origin, "https://example.brightspace.com");
});

test("encodes a quiz link's parameters so they survive as one `target`", () => {
  const quiz = "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=555&ou=412690";
  const target = new URL(initiateLoginTarget(quiz)).searchParams.get("target");
  assert.equal(target, "/d2l/lms/quizzing/user/quiz_summary.d2l?qi=555&ou=412690");
});
