/**
 * `cache/mfa.json` — the MFA number on its way to the status-bar icon.
 *
 * The icon is a PURE FUNCTION of (the file exists && now - mintedAt < 60s), so
 * everything the human ends up seeing is decided by this file's lifetime and by
 * the two fields in it. That fixes the priorities:
 *
 *  1. THE FILE IS THE TRUTH, AND ONLY WHILE IT IS TRUE. It appears while a
 *     number is actually live on the login page, carries that number, and is
 *     gone by the time attempt() resolves — on success, on failure, and when the
 *     browser explodes mid-flow. A file that outlives its number is an icon
 *     telling a human to type digits that will not work.
 *  2. IT IS STATUS, NEVER A CREDENTIAL (D7). The number is display-by-design and
 *     useless without the phone; a cookie, an email or a password in this file
 *     would be a secret in a directory the Swift app watches and nothing 0600s.
 *
 * Scope: small. NO BROWSER LAUNCHES. The scrape itself lives on the far side of
 * the injected `capture` seam (proven against the live tenant in
 * experiment-10/src/prove-number.mjs: `#idRichContext_DisplaySign` is plain DOM
 * text); what is pinned here is what the RUNG does with a number the seam hands
 * it, and a temp BSB_ROOT is the only real I/O.
 *
 * ---------------------------------------------------------------------------
 * THE SEAM THIS FILE PINS — binding on the builder
 * ---------------------------------------------------------------------------
 *
 * The browser world grows one field, and the full-login rung grows a clock:
 *
 *     createFullLoginRung({ capture, baseUrl, clock })
 *         clock: () => Date          // defaults to () => new Date()
 *
 *     capture({ profileDir, baseUrl, log, onMfaNumber })
 *         onMfaNumber: (text: string) => Promise<void>
 *
 * `onMfaNumber` is how the capture says "the number is on the screen right now"
 * — it is called the moment the scrape succeeds, and again if a resend mints a
 * different number. It is AWAITABLE and the capture must await it, because the
 * whole point is that the icon is already showing the digits while the capture
 * goes back to waiting for the human. The rung owns the file: it writes it, it
 * updates it, and it deletes it. The silent rung has no MFA surface and is not
 * required to pass `onMfaNumber` at all (the fake below calls it optionally).
 *
 * The file's location is `<BSB_ROOT>/cache/mfa.json`. These tests resolve it
 * from `paths.cacheDir`, so the builder is free to add `paths.mfaFile` to
 * src/paths.mjs (the natural home — that module owns the layout) without any
 * of these tests caring either way.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { createFullLoginRung } from "../src/rungs/full-login.mjs";
import { createSilentRung } from "../src/rungs/silent.mjs";
import { FIXED_ISO, fixedClock, tempPaths } from "./helpers.mjs";
import { CAPTURED_COOKIES, CSRF_TOKEN, SECRETS, TEST_BASE } from "./phase2-helpers.mjs";

/** The number Entra put on the screen. Two digits, exactly as the DOM has it. */
const NUMBER = "20";
/** What a resend mints — deliberately different, so an update is visible. */
const RESENT = "73";

/** The one file this whole build is about. */
const mfaFileIn = (paths) => path.join(paths.cacheDir, "mfa.json");

/** The file's bytes, or null when it is not there. Never throws: absence is an answer. */
function readMfa(paths) {
  try {
    return readFileSync(mfaFileIn(paths), "utf8");
  } catch {
    return null;
  }
}

/** Everything in cache/, dotfiles included — a temp file is debris the app watches. */
function cacheEntries(paths) {
  try {
    return readdirSync(paths.cacheDir);
  } catch {
    return [];
  }
}

/** A successful capture: the cookies a real harvest brings back. */
const okCapture = () => ({
  ok: true,
  cookies: CAPTURED_COOKIES,
  csrfToken: CSRF_TOKEN,
  landedUrl: `${TEST_BASE}/d2l/home`,
});

/**
 * A browser that never launches but does present numbers.
 *
 * It announces each of `numbers` through the world's `onMfaNumber`, awaiting
 * each one, and takes a SNAPSHOT of cache/ immediately afterwards — that window
 * (the capture still running, the human still reaching for their phone) is the
 * only time the file is supposed to exist, so it is the only place most of these
 * claims can be made from. `atEntry` is the same reading taken before anything
 * is announced, which is how "a stale file is cleared at the START" is observed.
 *
 * `then` ends the capture: a verdict object, or `{ throws }` to explode the way
 * playwright does when the window is closed under it.
 */
function presentingCapture(paths, { numbers = [NUMBER], then = okCapture() } = {}) {
  const capture = async (world) => {
    capture.calls.push(world);
    capture.atEntry = readMfa(paths);
    for (const number of numbers) {
      await world.onMfaNumber?.(number);
      capture.shown.push({ file: readMfa(paths), entries: cacheEntries(paths) });
    }
    if (then?.throws) throw new Error(then.throws);
    return then;
  };
  capture.calls = [];
  capture.shown = [];
  capture.atEntry = undefined;
  return capture;
}

/** The reading taken while the first number was on the screen. */
const whileShowing = (capture, index = 0) => {
  assert.ok(capture.shown[index], "the capture never got to show a number");
  return capture.shown[index];
};

/** The file's bytes while the number was on the screen. Fails if it never was. */
const shownRaw = (capture, index = 0) => {
  const { file } = whileShowing(capture, index);
  assert.ok(file !== null, "no mfa.json existed while the number was on the screen");
  return file;
};

/** The parsed file as the icon's reader would see it, mid-flow. */
const shownJson = (capture, index = 0) => JSON.parse(shownRaw(capture, index));

/**
 * The precondition every deletion claim rests on: the file WAS published during
 * the attempt. Without this, "it is gone afterwards" is true of an
 * implementation that never wrote anything.
 */
const publishedDuring = (capture) => assert.equal(shownJson(capture).number, NUMBER);

// ---------------------------------------------------------------------------
// The file appears, saying the right thing, while the number is live.
// ---------------------------------------------------------------------------

test("the full rung publishes the number while the human is still being waited on", async (t) => {
  // Arrange — the icon has to be showing the digits DURING the wait; a file
  // written after attempt() resolves would be a number nobody can act on.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths);

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert
  assert.equal(shownJson(capture).number, NUMBER);
});

test("the published number is the digits as a string", async (t) => {
  // Arrange — Swift renders it as a title; a JSON number would drop a leading
  // zero and put "7" on the icon when the phone says "07".
  const paths = tempPaths(t);
  const capture = presentingCapture(paths, { numbers: ["07"] });

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert
  assert.strictEqual(shownJson(capture).number, "07");
});

test("mfa.json carries exactly number and mintedAt", async (t) => {
  // Arrange — the whole contract, in two fields. Anything extra is either
  // something the icon must not depend on or something that should not be here.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths);

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert
  assert.deepStrictEqual(Object.keys(shownJson(capture)).sort(), ["mintedAt", "number"]);
});

test("mintedAt is stamped from the injected clock", async (t) => {
  // Arrange — the icon's TTL is now - mintedAt, so this timestamp is the thing
  // that makes a crashed rung's number expire instead of wedging the menu bar.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths);

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert
  assert.equal(shownJson(capture).mintedAt, FIXED_ISO);
});

test("the scraped text is trimmed down to the digits", async (t) => {
  // Arrange — textContent off a DOM node arrives with the template's
  // whitespace, and " 42\n" on the icon is not a number a human can type.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths, { numbers: ["  42\n"] });

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert
  assert.strictEqual(shownJson(capture).number, "42");
});

test("a blank scrape publishes no file at all", async (t) => {
  // Arrange — an empty element is the scrape failing, not a number. An empty
  // icon is strictly worse than the logo: it looks like the app broke.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths, { numbers: ["   "] });

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert
  assert.equal(whileShowing(capture).file, null);
});

test("a resend replaces the number and the mint time", async (t) => {
  // Arrange — Entra re-mints on resend, and the old digits stop working the
  // moment it does. A clock that steps proves the TTL restarts with the number.
  const paths = tempPaths(t);
  const second = "2026-08-15T14:00:30.000Z";
  const instants = [FIXED_ISO, second];
  const clock = () => new Date(instants.shift() ?? second);
  const capture = presentingCapture(paths, { numbers: [NUMBER, RESENT] });

  // Act
  await createFullLoginRung({ capture, clock }).attempt({ paths, log: () => {} });

  // Assert
  assert.deepStrictEqual(shownJson(capture, 1), { number: RESENT, mintedAt: second });
});

test("the cache directory is created when the root has never been written to", async (t) => {
  // Arrange — the first full login on a fresh install happens before any fetch
  // has ever succeeded, so cache/ does not exist yet.
  const paths = tempPaths(t);
  assert.equal(existsSync(paths.cacheDir), false, "the fixture root was not empty");
  const capture = presentingCapture(paths);

  // Act
  const result = await createFullLoginRung({ capture, clock: fixedClock }).attempt({
    paths,
    log: () => {},
  });

  // Assert
  assert.equal(shownJson(capture).number, NUMBER);
  assert.deepStrictEqual(result, { ok: true });
});

test("the number is published atomically — no half file, no temp debris", async (t) => {
  // Arrange — the Swift watcher wakes on a directory event and re-reads
  // immediately (experiment 17: one atomic write is two events, the first a
  // lie). A partial file, or a *.tmp left behind, is a wake-up on garbage.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths);

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert — the whole file was there, and it was the only thing there.
  JSON.parse(shownRaw(capture));
  assert.deepStrictEqual(whileShowing(capture).entries, ["mfa.json"]);
});

// ---------------------------------------------------------------------------
// The file is gone on every way out.
// ---------------------------------------------------------------------------

test("the file is gone before a successful attempt resolves", async (t) => {
  // Arrange — the session is live, the number is spent; the icon must be the
  // logo again by the time the orchestrator moves on.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths);

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert
  publishedDuring(capture);
  assert.equal(readMfa(paths), null);
});

test("the file is gone when the capture reports a failure", async (t) => {
  // Arrange — the human never approved and the wait timed out. The number on
  // the screen died with it.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths, {
    then: { ok: false, reason: "timed out waiting for the MFA approval" },
  });

  // Act
  const result = await createFullLoginRung({ capture, clock: fixedClock }).attempt({
    paths,
    log: () => {},
  });

  // Assert
  publishedDuring(capture);
  assert.equal(result.ok, false);
  assert.equal(readMfa(paths), null);
});

test("the file is gone when the browser throws mid-flow", async (t) => {
  // Arrange — the window was closed under the capture after the number was
  // already up. Only a finally can clean this one up.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths, { then: { throws: "Target page closed" } });

  // Act
  const result = await createFullLoginRung({ capture, clock: fixedClock }).attempt({
    paths,
    log: () => {},
  });

  // Assert
  publishedDuring(capture);
  assert.equal(result.ok, false);
  assert.equal(readMfa(paths), null);
});

test("a stale file from a crashed run is cleared at the start of the attempt", async (t) => {
  // Arrange — the previous run was SIGKILLed with its number on the icon. The
  // TTL covers the icon, but the next attempt must not begin against a lie.
  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(mfaFileIn(paths), '{"number":"99","mintedAt":"2020-01-01T00:00:00.000Z"}\n');
  const capture = presentingCapture(paths);

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert — read by the fake at the top of the capture, before it announced.
  assert.equal(capture.atEntry, null);
});

test("nothing is left in cache/ once the attempt is over", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const capture = presentingCapture(paths);

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert — not the file, and not a temp file either.
  publishedDuring(capture);
  assert.deepStrictEqual(cacheEntries(paths), []);
});

test("the cache the app is reading survives an MFA attempt", async (t) => {
  // Arrange — mfa.json is ephemeral status sharing a directory with the course
  // data. A cleanup that took data.json with it would blank the menu.
  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(paths.dataFile, '{"courses":[]}\n');
  writeFileSync(paths.statusFile, '{"state":"fresh"}\n');
  const capture = presentingCapture(paths);

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert
  publishedDuring(capture);
  assert.equal(readFileSync(paths.dataFile, "utf8"), '{"courses":[]}\n');
  assert.equal(readFileSync(paths.statusFile, "utf8"), '{"state":"fresh"}\n');
});

test("showing a number does not cost the rung its session", async (t) => {
  // Arrange — the product of the rung is still session.json; the icon is a
  // side channel and must not become a way to fail the login.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths);

  // Act
  const result = await createFullLoginRung({ capture, clock: fixedClock }).attempt({
    paths,
    log: () => {},
  });

  // Assert
  publishedDuring(capture);
  assert.deepStrictEqual(result, { ok: true });
  assert.equal(JSON.parse(readFileSync(paths.sessionFile, "utf8")).csrfToken, CSRF_TOKEN);
});

// ---------------------------------------------------------------------------
// D7 — status, never a credential.
// ---------------------------------------------------------------------------

test("mfa.json never carries credential material", async (t) => {
  // Arrange — cache/ is the unprivileged, app-watched directory: not 0600, and
  // in phase C a human reads this file's contents out loud over chat.
  const paths = tempPaths(t);
  const previous = { email: process.env.BS_EMAIL, password: process.env.BS_PASSWORD };
  process.env.BS_EMAIL = "SECRET-email@purdue.edu";
  process.env.BS_PASSWORD = "SECRET-password-hunter2";
  t.after(() => {
    for (const [key, value] of [["BS_EMAIL", previous.email], ["BS_PASSWORD", previous.password]]) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });
  const capture = presentingCapture(paths);

  // Act
  await createFullLoginRung({ capture, clock: fixedClock }).attempt({ paths, log: () => {} });

  // Assert — every marked secret, plus the credentials the login was fed.
  const published = shownRaw(capture);
  for (const secret of [...SECRETS, process.env.BS_EMAIL, process.env.BS_PASSWORD]) {
    assert.ok(!published.includes(secret), `mfa.json leaked ${secret.slice(0, 14)}…`);
  }
});

// ---------------------------------------------------------------------------
// One writer.
// ---------------------------------------------------------------------------

test("the silent rung never publishes an MFA number", async (t) => {
  // Arrange — rung 1 is headless and unattended; there is no human to show a
  // number to. A number on the icon at 3am with nobody's phone involved is a
  // notification the app cannot honor.
  const paths = tempPaths(t);
  const capture = presentingCapture(paths);

  // Act
  await createSilentRung({ capture }).attempt({ paths, log: () => {} });

  // Assert — not during the attempt, and not after it.
  assert.equal(whileShowing(capture).file, null);
  assert.equal(readMfa(paths), null);
});
