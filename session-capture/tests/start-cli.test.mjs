/**
 * start.mjs — the one-command flow, tested with stand-ins for the two things
 * it spawns: the menu-bar app (BSB_APP_BINARY) and the daemon (BSB_REFRESH_CLI).
 *
 * What is pinned is the surface `make start` and `make login` share: the
 * flags that reach the daemon, the backoff lift, the exit-code handoff, and
 * the words a human reads when the login did not happen — because the bug
 * this exists for was a person told "the number appears on the icon" who
 * never saw a number and had no idea what to do next.
 *
 * Credentials arrive through the environment so no prompt fires (stdin is not
 * a TTY under the test runner).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { credentialsFile } from "../src/credentials.mjs";
import { run, tempPaths } from "./helpers.mjs";

/** A stand-in app: exits at once. start.mjs only needs it to exist and be spawnable. */
function fakeApp(paths) {
  const app = path.join(paths.root, "fake-app");
  writeFileSync(app, `#!/bin/sh\necho app >> "${path.join(paths.root, "order.log")}"\nexit 0\n`);
  chmodSync(app, 0o755);
  return app;
}

/**
 * A stand-in refresh.mjs: records argv and the env it was handed, exits
 * `code`. With STUB_REJECT set it does what the real daemon does when
 * Microsoft rejects the stored password: removes credentials.json.
 */
function fakeRefresh(paths, code) {
  const stub = path.join(paths.root, "refresh-stub.mjs");
  writeFileSync(stub, `import { appendFileSync, existsSync, rmSync, writeFileSync } from "node:fs";
appendFileSync(${JSON.stringify(path.join(paths.root, "order.log"))}, "refresh\\n");
const file = ${JSON.stringify(credentialsFile({ BSB_ROOT: paths.root }))};
writeFileSync(process.env.STUB_OUT, JSON.stringify({
  argv: process.argv.slice(2),
  backoff: process.env.BSB_FULL_LOGIN_BACKOFF_MS ?? null,
  hasCredentials: Boolean(process.env.BS_EMAIL && process.env.BS_PASSWORD),
  hasFile: existsSync(file),
}));
if (process.env.STUB_REJECT) rmSync(file, { force: true });
process.exit(${code});`);
  return stub;
}

async function start(paths, args, { exit = 0, stored = false, reject = false } = {}) {
  const out = path.join(paths.root, "seen.json");
  // Stored: credentials.json in the root and nothing in the environment,
  // which is every run after the first. Otherwise the env stands in.
  if (stored) writeFileSync(credentialsFile({ BSB_ROOT: paths.root }), JSON.stringify({ email: "student@example.edu", password: "hunter2-not-real" }));
  const result = await run("node", ["src/start.mjs", ...args], {
    env: {
      ...process.env,
      BSB_ROOT: paths.root,
      BSB_APP_BINARY: fakeApp(paths),
      BSB_REFRESH_CLI: fakeRefresh(paths, exit),
      STUB_OUT: out,
      ...(reject ? { STUB_REJECT: "1" } : {}),
      BS_EMAIL: stored ? "" : "student@example.edu",
      BS_PASSWORD: stored ? "" : "hunter2-not-real",
    },
  });
  return { ...result, seen: JSON.parse(readFileSync(out, "utf8")) };
}

test("make start: the daemon runs headless with the backoff lifted, and its exit code is ours", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  const result = await start(paths, []);

  // Assert
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(result.seen.argv, []);
  assert.equal(result.seen.backoff, "0");
  assert.equal(result.seen.hasCredentials, true);
  assert.match(result.stderr, /headless/);
  assert.match(result.stderr, /menu bar is live/);
});

test("make login: --visible reaches the daemon, and nothing else changes", async (t) => {
  // Arrange — the same flow, one flag through.
  const paths = tempPaths(t);

  // Act
  const result = await start(paths, ["--visible"]);

  // Assert
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(result.seen.argv, ["--visible"]);
  assert.equal(result.seen.backoff, "0");
  assert.equal(result.seen.hasCredentials, true, "the visible login stores and passes credentials like the headless one");
  assert.match(result.stderr, /VISIBLE browser/);
  assert.doesNotMatch(result.stderr, /ON THE MENU-BAR ICON/);
});

test("a headless run that needs login tells the human to run make login", async (t) => {
  // Arrange — the daemon exhausted its ladder (exit 2).
  const paths = tempPaths(t);

  // Act
  const result = await start(paths, [], { exit: 2 });

  // Assert — the exit code passes through, and the next step is named.
  assert.equal(result.code, 2);
  assert.match(result.stderr, /make login/);
});

test("the headless banner itself names make login as the fallback", async (t) => {
  // Arrange — the person who never sees a number must not need to ask.
  const paths = tempPaths(t);

  // Act
  const result = await start(paths, []);

  // Assert
  assert.match(result.stderr, /If no number appears .* run `make login`/);
});

test("an unknown flag is refused before the app or the daemon is touched", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  const out = path.join(paths.root, "seen.json");

  // Act
  const result = await run("node", ["src/start.mjs", "--headed"], {
    env: { ...process.env, BSB_ROOT: paths.root, BSB_APP_BINARY: fakeApp(paths), BSB_REFRESH_CLI: fakeRefresh(paths, 0), STUB_OUT: out },
  });

  // Assert
  assert.equal(result.code, 1);
  assert.match(result.stderr, /unknown argument: --headed/);
  assert.throws(() => readFileSync(out), "the daemon must not have run");
});

test("headless: the app comes up first, then the daemon — the icon must exist to show the number", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  await start(paths, []);

  // Assert
  const order = readFileSync(path.join(paths.root, "order.log"), "utf8").trim().split("\n");
  assert.deepEqual(order, ["app", "refresh"]);
});

test("visible: the daemon runs first, then the app — one browser, one push, no launch-fetch race", async (t) => {
  // Arrange — an app launched onto an empty cache spawns a daemon run of its
  // own; in the window the number is on screen, so the app can wait.
  const paths = tempPaths(t);

  // Act
  await start(paths, ["--visible"]);

  // Assert
  const order = readFileSync(path.join(paths.root, "order.log"), "utf8").trim().split("\n");
  assert.deepEqual(order, ["refresh", "app"]);
});

test("visible: the app is launched even when the sign-in failed, so the person has a menu to look at", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  const result = await start(paths, ["--visible"], { exit: 2 });

  // Assert
  assert.equal(result.code, 2);
  const order = readFileSync(path.join(paths.root, "order.log"), "utf8").trim().split("\n");
  assert.deepEqual(order, ["refresh", "app"]);
});

test("stored credentials stay in the file — the daemon reads them there, they are not re-exported", async (t) => {
  // Arrange — every run after the first: credentials.json, empty env. The
  // daemon must see the FILE, because a rejected file is discarded and a
  // rejected export is not; re-exporting would hide the difference.
  const paths = tempPaths(t);

  // Act
  const result = await start(paths, [], { stored: true });

  // Assert
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.seen.hasFile, true);
  assert.equal(result.seen.hasCredentials, false, "file credentials must not be copied into the daemon's env");
});

test("a rejected stored password is reported, and the next run is told it will ask again", async (t) => {
  // Arrange — the daemon removed credentials.json (Microsoft said no) and
  // the headless ladder ended on needs-login.
  const paths = tempPaths(t);

  // Act
  const result = await start(paths, [], { stored: true, reject: true, exit: 2 });

  // Assert — the file is gone, the person is told why, and what happens next.
  assert.equal(result.code, 2);
  assert.equal(existsSync(credentialsFile({ BSB_ROOT: paths.root })), false);
  assert.match(result.stderr, /stored password was rejected and removed/);
  assert.match(result.stderr, /asks for it again/);
});

test("a visible login that succeeded after a rejection wants the password that worked (no TTY: says so)", async (t) => {
  // Arrange — the human corrected the password in the window and signed in;
  // the daemon had already discarded the wrong file. Under the test runner
  // there is no TTY to prompt on, so the message stands in for the prompt.
  const paths = tempPaths(t);

  // Act
  const result = await start(paths, ["--visible"], { stored: true, reject: true, exit: 0 });

  // Assert — success is still success, and the missing file is not silent.
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stderr, /rejected and removed/);
  assert.match(result.stderr, /menu bar is live/);
});

test("a run whose credentials came from the environment says nothing about the file", async (t) => {
  // Arrange — BS_EMAIL/BS_PASSWORD exported, no file anywhere.
  const paths = tempPaths(t);

  // Act
  const result = await start(paths, [], { exit: 2 });

  // Assert
  assert.doesNotMatch(result.stderr, /rejected/);
});
