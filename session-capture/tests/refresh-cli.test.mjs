/**
 * refresh.mjs — the CLI wrapper, tested THIN on purpose.
 *
 * The CLI's job is argument parsing and the exit-code handoff to Swift; the
 * ladder logic underneath it is already pinned by orchestrate.test.mjs with
 * injected fakes, and the exit-code mapping by `exitCode`. So the only thing
 * worth spawning a process for is the surface a human (and a `--help` in a
 * brief) actually reads. Driving a real refresh from here would mean a real
 * browser and a real tenant — that belongs to the phase-4 tiered E2E, not to
 * a hermetic unit suite.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync } from "node:fs";
import { run, tempPaths } from "./helpers.mjs";

test("--help exits 0 and documents the full-login permission flag", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  const result = await run("node", ["src/refresh.mjs", "--help"], {
    env: { ...process.env, BSB_ROOT: paths.root },
  });

  // Assert
  assert.equal(result.code, 0, `stderr: ${result.stderr}`);
  const output = `${result.stdout}${result.stderr}`;
  assert.match(output, /usage/i);
  assert.match(output, /--allow-full-login/);
});

test("--help touches no files", async (t) => {
  // Arrange
  const paths = tempPaths(t);

  // Act
  await run("node", ["src/refresh.mjs", "--help"], {
    env: { ...process.env, BSB_ROOT: paths.root },
  });

  // Assert
  assert.deepStrictEqual(readdirSync(paths.root), []);
});
