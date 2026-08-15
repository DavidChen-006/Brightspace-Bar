/**
 * paths.mjs — the test-isolation dial.
 *
 * Every file the daemon touches hangs off ONE root, so pointing BSB_ROOT at a
 * temp directory is the whole isolation story: if resolvePaths is honest, no
 * test can reach David's real credentials, and if it is not, every other test
 * in this suite is quietly lying. Hence the two claims below carry the weight:
 * the layout under a given root is fixed, and resolution is a pure function
 * (it reports paths, it never creates them).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { resolvePaths } from "../src/paths.mjs";
import { tempDir } from "./helpers.mjs";

test("lays the four daemon locations out under BSB_ROOT", () => {
  // Arrange
  const root = "/tmp/bsb-layout-check";

  // Act
  const paths = resolvePaths({ BSB_ROOT: root });

  // Assert
  assert.deepStrictEqual(paths, {
    root,
    profileDir: path.join(root, "profile"),
    sessionFile: path.join(root, "session.json"),
    cacheDir: path.join(root, "cache"),
    dataFile: path.join(root, "cache", "data.json"),
    statusFile: path.join(root, "cache", "status.json"),
  });
});

test("defaults to the Application Support directory when BSB_ROOT is unset", () => {
  // Arrange
  const env = {};

  // Act
  const paths = resolvePaths(env);

  // Assert
  assert.equal(paths.root, path.join(os.homedir(), "Library", "Application Support", "BrightspaceBar"));
});

test("treats an empty BSB_ROOT as unset rather than as the filesystem root", () => {
  // Arrange
  const env = { BSB_ROOT: "" };

  // Act
  const paths = resolvePaths(env);

  // Assert
  assert.equal(paths.root, path.join(os.homedir(), "Library", "Application Support", "BrightspaceBar"));
});

test("reads process.env when called with no argument", (t) => {
  // Arrange
  const previous = process.env.BSB_ROOT;
  process.env.BSB_ROOT = "/tmp/bsb-from-process-env";
  t.after(() => {
    if (previous === undefined) delete process.env.BSB_ROOT;
    else process.env.BSB_ROOT = previous;
  });

  // Act
  const paths = resolvePaths();

  // Assert
  assert.equal(paths.root, "/tmp/bsb-from-process-env");
});

test("returns absolute paths even when BSB_ROOT is relative", () => {
  // Arrange
  const env = { BSB_ROOT: "relative/root" };

  // Act
  const paths = resolvePaths(env);

  // Assert
  assert.ok(
    path.isAbsolute(paths.dataFile),
    `dataFile must be absolute so the daemon's cwd cannot move the cache; got ${paths.dataFile}`,
  );
});

test("creates nothing on disk", (t) => {
  // Arrange
  const parent = tempDir(t);
  const root = path.join(parent, "not-yet-created");

  // Act
  resolvePaths({ BSB_ROOT: root });

  // Assert
  assert.equal(existsSync(root), false);
  assert.deepStrictEqual(readdirSync(parent), []);
});
