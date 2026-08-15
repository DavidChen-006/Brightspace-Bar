/**
 * scripts/reset.sh — the dev tool that manufactures the E2E tiers.
 *
 * Tier 1 of the tiered E2E is literally "run `reset.sh --session`, then prove
 * the daemon re-mints silently". So this script's precision IS the test plan:
 * `--session` must take the credentials and leave the Entra-independent cache,
 * `--cache` must take only the cache, and NOTHING may reach outside BSB_ROOT —
 * a script that over-deletes turns a cheap tier-1 run into an MFA prompt, and
 * one that under-deletes makes a tier pass for the wrong reason.
 *
 * Tested as a black box against a populated temp root, run through bash rather
 * than the shebang so the behavior claims stand on their own; the shebang and
 * the executable bit get their own test.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { PKG_DIR, run, tempDir, tempPaths } from "./helpers.mjs";

const SCRIPT = path.join(PKG_DIR, "scripts", "reset.sh");

/** A root that looks like a working install: profile, credentials, cache. */
function populate(paths) {
  mkdirSync(path.join(paths.profileDir, "Default"), { recursive: true });
  writeFileSync(path.join(paths.profileDir, "Default", "Cookies"), "entra wristband");
  writeFileSync(paths.sessionFile, JSON.stringify({ cookieHeader: "d2lSessionVal=abc" }));
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(paths.dataFile, JSON.stringify({ fetchedAt: "2026-08-01T00:00:00.000Z", courses: [] }));
  writeFileSync(paths.statusFile, JSON.stringify({ state: "fresh" }));
}

const reset = (root, args) =>
  run("/bin/bash", [SCRIPT, ...args], { env: { ...process.env, BSB_ROOT: root } });

/** True when the path is gone or is an empty directory — either is "deleted". */
const cleared = (target) =>
  !existsSync(target) || (statSync(target).isDirectory() && readdirSync(target).length === 0);

test("--cache clears the cache and nothing else", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  populate(paths);

  // Act
  const result = await reset(paths.root, ["--cache"]);

  // Assert
  assert.equal(result.code, 0, `stderr: ${result.stderr}`);
  assert.ok(cleared(paths.cacheDir), "cache/ should be gone");
  assert.equal(existsSync(paths.sessionFile), true, "session.json must survive --cache");
  assert.equal(existsSync(path.join(paths.profileDir, "Default", "Cookies")), true);
});

test("--session clears the credentials but keeps the cache", async (t) => {
  // Arrange — this is exactly how tier 1 is staged.
  const paths = tempPaths(t);
  populate(paths);
  const dataBefore = readFileSync(paths.dataFile);

  // Act
  const result = await reset(paths.root, ["--session"]);

  // Assert
  assert.equal(result.code, 0, `stderr: ${result.stderr}`);
  assert.equal(existsSync(paths.sessionFile), false, "session.json should be gone");
  assert.ok(cleared(paths.profileDir), "profile/ should be gone");
  assert.deepStrictEqual(readFileSync(paths.dataFile), dataBefore);
});

test("--all empties the root but leaves the root itself", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  populate(paths);

  // Act
  const result = await reset(paths.root, ["--all"]);

  // Assert
  assert.equal(result.code, 0, `stderr: ${result.stderr}`);
  assert.equal(existsSync(paths.root), true, "the root must remain for the daemon to write into");
  assert.deepStrictEqual(readdirSync(paths.root), []);
});

test("never follows a link out of the root", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  populate(paths);
  const outside = tempDir(t);
  const bystander = path.join(outside, "keep.txt");
  writeFileSync(bystander, "not yours to delete");
  symlinkSync(outside, path.join(paths.root, "escape-hatch"));

  // Act
  await reset(paths.root, ["--all"]);

  // Assert
  assert.equal(existsSync(bystander), true, "deletion escaped BSB_ROOT through a symlink");
});

test("refuses to delete anything when given no mode", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  populate(paths);

  // Act
  const result = await reset(paths.root, []);

  // Assert
  assert.notEqual(result.code, 0, "a bare reset.sh must not be a silent nuke");
  assert.equal(existsSync(paths.sessionFile), true);
  assert.equal(existsSync(paths.dataFile), true);
});

test("refuses to delete anything when given an unknown mode", async (t) => {
  // Arrange
  const paths = tempPaths(t);
  populate(paths);

  // Act
  const result = await reset(paths.root, ["--everything-please"]);

  // Assert
  assert.notEqual(result.code, 0);
  assert.equal(existsSync(paths.sessionFile), true);
  assert.equal(existsSync(paths.dataFile), true);
});

test("is executable and declares its shell", () => {
  // Arrange
  const mode = statSync(SCRIPT).mode;

  // Act
  const firstLine = readFileSync(SCRIPT, "utf8").split("\n")[0];

  // Assert
  assert.ok(mode & 0o111, "reset.sh must be chmod +x — it is run as ./scripts/reset.sh");
  assert.match(firstLine, /^#!.*sh/);
});
