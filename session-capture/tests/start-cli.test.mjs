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
import { chmodSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { run, tempPaths } from "./helpers.mjs";

/** A stand-in app: exits at once. start.mjs only needs it to exist and be spawnable. */
function fakeApp(paths) {
  const app = path.join(paths.root, "fake-app");
  writeFileSync(app, `#!/bin/sh\necho app >> "${path.join(paths.root, "order.log")}"\nexit 0\n`);
  chmodSync(app, 0o755);
  return app;
}

/** A stand-in refresh.mjs: records argv and the env it was handed, exits `code`. */
function fakeRefresh(paths, code) {
  const stub = path.join(paths.root, "refresh-stub.mjs");
  writeFileSync(stub, `import { appendFileSync, writeFileSync } from "node:fs";
appendFileSync(${JSON.stringify(path.join(paths.root, "order.log"))}, "refresh\\n");
writeFileSync(process.env.STUB_OUT, JSON.stringify({
  argv: process.argv.slice(2),
  backoff: process.env.BSB_FULL_LOGIN_BACKOFF_MS ?? null,
  hasCredentials: Boolean(process.env.BS_EMAIL && process.env.BS_PASSWORD),
}));
process.exit(${code});`);
  return stub;
}

async function start(paths, args, { exit = 0 } = {}) {
  const out = path.join(paths.root, "seen.json");
  const result = await run("node", ["src/start.mjs", ...args], {
    env: {
      ...process.env,
      BSB_ROOT: paths.root,
      BSB_APP_BINARY: fakeApp(paths),
      BSB_REFRESH_CLI: fakeRefresh(paths, exit),
      STUB_OUT: out,
      BS_EMAIL: "student@example.edu",
      BS_PASSWORD: "hunter2-not-real",
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
