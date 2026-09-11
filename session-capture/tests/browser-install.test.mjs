/**
 * browser-install.mjs — the check that Playwright's Chromium really landed,
 * and the rewrite of Playwright's launch error into the fix.
 *
 * The bug this exists for: a new user whose browser download was skipped saw
 * the ladder fail twice with Playwright's banner, ran the command it named
 * from the wrong directory, got a different browser build, and hit the same
 * error again. Every claim here is about which words the person reads.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { INSTALL_FIX, browserDirs, explainLaunchError, installProblem, missingBrowsers } from "../src/browser-install.mjs";
import { tempDir } from "./helpers.mjs";

/** The shape `chromium.executablePath()` has on an Apple-silicon Mac. */
const executable = (root, revision = "1208") =>
  path.join(root, `chromium-${revision}`, "chrome-mac-arm64", "Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing");

/** What a finished `playwright install` leaves behind: the marker in each directory. */
function installed(root, names, revision = "1208") {
  for (const name of names) {
    const dir = path.join(root, `${name}-${revision}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "INSTALLATION_COMPLETE"), "");
  }
}

test("browserDirs reads the cache root and the build number off the executable path", (t) => {
  // Arrange
  const root = tempDir(t);

  // Act
  const layout = browserDirs(executable(root, "1208"));

  // Assert — the headless shell is the SIBLING directory with the underscore name.
  assert.equal(layout.cacheRoot, root);
  assert.equal(layout.revision, "1208");
  assert.equal(layout.dirs.chromium, path.join(root, "chromium-1208"));
  assert.equal(layout.dirs["chromium-headless-shell"], path.join(root, "chromium_headless_shell-1208"));
});

test("a path that is not Playwright's layout is reported as nothing installed, not as fine", () => {
  assert.equal(browserDirs("/usr/bin/chromium"), null);
  assert.deepEqual(missingBrowsers("/usr/bin/chromium", { exists: () => true }), ["chromium", "chromium-headless-shell"]);
});

test("both builds present: no problem", (t) => {
  // Arrange
  const root = tempDir(t);
  installed(root, ["chromium", "chromium_headless_shell"]);

  // Act / Assert
  assert.deepEqual(missingBrowsers(executable(root)), []);
  assert.equal(installProblem(executable(root)), null);
});

test("the headless shell missing — the reporter's exact case — is named, with the fix and where it looked", (t) => {
  // Arrange — the full browser landed, the headless shell did not. `make start`
  // needs the shell; the ladder would fail twice.
  const root = tempDir(t);
  installed(root, ["chromium"]);

  // Act
  const problem = installProblem(executable(root));

  // Assert
  assert.deepEqual(missingBrowsers(executable(root)), ["chromium-headless-shell"]);
  assert.match(problem, /missing chromium-headless-shell/);
  assert.ok(problem.includes(INSTALL_FIX), "the fix is spelled out verbatim");
  assert.match(problem, /session-capture/, "and the directory it must run in is the point");
  assert.ok(problem.includes(root), "says where it looked");
  assert.match(problem, /build 1208/);
});

test("a directory without the completion marker counts as missing — an interrupted download", (t) => {
  // Arrange — the directory exists, the download died half-way.
  const root = tempDir(t);
  installed(root, ["chromium"]);
  mkdirSync(path.join(root, "chromium_headless_shell-1208"), { recursive: true });

  // Act / Assert
  assert.deepEqual(missingBrowsers(executable(root)), ["chromium-headless-shell"]);
});

test("explainLaunchError turns Playwright's banner into the one command, keeping the path it looked for", () => {
  // Arrange — Playwright's message verbatim, banner and all.
  const message = [
    "browserType.launchPersistentContext: Executable doesn't exist at /Users/x/Library/Caches/ms-playwright/chromium_headless_shell-1208/chrome-headless-shell-mac-arm64/chrome-headless-shell",
    "╔═════════════════════════════════════════════════════════════════════════╗",
    "║ Looks like Playwright Test or Playwright was just installed or updated. ║",
    "║ Please run the following command to download new browsers:              ║",
    "║     npx playwright install                                              ║",
    "╚═════════════════════════════════════════════════════════════════════════╝",
  ].join("\n");

  // Act
  const reason = explainLaunchError(message);

  // Assert — one line, the fix, the path; the banner and its wrong command gone.
  assert.ok(!reason.includes("\n"));
  assert.ok(reason.includes(INSTALL_FIX));
  assert.match(reason, /chromium_headless_shell-1208/);
  assert.ok(!reason.includes("╔"));
  assert.ok(!/npx playwright install\s*$/.test(reason), "the bare command without the directory is what misled the reporter");
});

test("explainLaunchError leaves every other message alone", () => {
  for (const message of ["browserType.launch: Target closed", "profile is locked", ""]) {
    assert.equal(explainLaunchError(message), message);
  }
});
