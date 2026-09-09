/**
 * run-lock.mjs — one refresh per root at a time.
 *
 * The collision this guards against is real and reproducible: `make start`
 * launches the app, the app's launch fetch on an empty cache spawns a daemon
 * run, and two seconds later `make start` spawns another. Two Chromiums on
 * one profile, two MFA pushes. The lock makes the second one WAIT.
 *
 * Hermetic: liveness and the sleep are injected, so a "live holder" is a
 * function that says so and waiting takes no real time.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { acquireRunLock, readHolder } from "../src/run-lock.mjs";
import { tempDir } from "./helpers.mjs";

const noSleep = () => Promise.resolve();

test("the first run takes the lock, records its pid, and release removes the file", async (t) => {
  // Arrange
  const file = path.join(tempDir(t), "nested", "refresh.lock");

  // Act
  const held = await acquireRunLock(file, { pid: 4242, sleep: noSleep });

  // Assert
  assert.ok(held, "the lock was not acquired");
  assert.equal(readHolder(file), 4242);
  held.release();
  assert.equal(existsSync(file), false);
});

test("a second run waits for a live holder and gets the lock once it is released", async (t) => {
  // Arrange — the holder is alive for the first two polls, then releases.
  const file = path.join(tempDir(t), "refresh.lock");
  const first = await acquireRunLock(file, { pid: 1, sleep: noSleep });
  let polls = 0;
  const lines = [];
  const sleep = async () => { polls += 1; if (polls === 2) first.release(); };

  // Act
  const second = await acquireRunLock(file, { pid: 2, isAlive: () => true, sleep, log: (m) => lines.push(m) });

  // Assert
  assert.ok(second, "the waiter never got the lock");
  assert.equal(readHolder(file), 2);
  assert.equal(polls, 2);
  assert.match(lines.join("\n"), /another refresh \(pid 1\) is running/);
  second.release();
});

test("a lock left by a dead process is broken and taken over at once", async (t) => {
  // Arrange — a SIGKILL mid-MFA leaves the file behind with a pid nobody has.
  const file = path.join(tempDir(t), "refresh.lock");
  writeFileSync(file, JSON.stringify({ pid: 99999, since: "2026-09-09T00:00:00.000Z" }));
  let slept = false;
  const lines = [];

  // Act
  const held = await acquireRunLock(file, { pid: 7, isAlive: () => false, sleep: async () => { slept = true; }, log: (m) => lines.push(m) });

  // Assert
  assert.ok(held);
  assert.equal(readHolder(file), 7);
  assert.equal(slept, false, "a dead holder is not something to wait for");
  assert.match(lines.join("\n"), /stale refresh lock left by pid 99999/);
  held.release();
});

test("an unreadable lock file is treated as stale, not as a live holder", async (t) => {
  // Arrange — half-written, or from a version with another shape.
  const file = path.join(tempDir(t), "refresh.lock");
  writeFileSync(file, "not json");

  // Act
  const held = await acquireRunLock(file, { pid: 8, isAlive: () => true, sleep: noSleep });

  // Assert
  assert.ok(held);
  assert.equal(readHolder(file), 8);
  held.release();
});

test("when the wait runs out the caller gets null and the holder keeps the lock", async (t) => {
  // Arrange — a live holder that never releases; a tiny budget.
  const file = path.join(tempDir(t), "refresh.lock");
  const first = await acquireRunLock(file, { pid: 1, sleep: noSleep });

  // Act
  const second = await acquireRunLock(file, { pid: 2, isAlive: () => true, waitMs: 0, sleep: noSleep });

  // Assert
  assert.equal(second, null);
  assert.equal(readHolder(file), 1);
  first.release();
});

test("release never removes a successor's lock", async (t) => {
  // Arrange — 1 holds, its lock is broken as stale, 2 takes over, then 1's
  // late release must not pull the file out from under 2.
  const file = path.join(tempDir(t), "refresh.lock");
  const first = await acquireRunLock(file, { pid: 1, sleep: noSleep });
  const second = await acquireRunLock(file, { pid: 2, isAlive: () => false, sleep: noSleep });

  // Act
  first.release();

  // Assert
  assert.equal(readHolder(file), 2);
  assert.equal(JSON.parse(readFileSync(file, "utf8")).pid, 2);
  second.release();
});
