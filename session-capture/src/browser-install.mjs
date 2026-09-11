/**
 * Is the daemon's Chromium actually on disk? — and what to say when it is not.
 *
 * Playwright downloads its browsers in this package's `postinstall`, into
 * `~/Library/Caches/ms-playwright` (or `$PLAYWRIGHT_BROWSERS_PATH`). That
 * download can be skipped or interrupted without `npm install` failing, and
 * the first sign is then the ladder: every rung throws
 *
 *     browserType.launchPersistentContext: Executable doesn't exist at …
 *
 * followed by Playwright's banner telling the person to run
 * `npx playwright install`. That advice is wrong for this repo in a way that
 * cost a real user an evening: run outside `session-capture/`, `npx` fetches
 * the NEWEST Playwright and installs the build THAT version wants, which is
 * not the build the pinned version here looks for. Nothing changes, the same
 * error comes back.
 *
 * Two things here: a pure check of the install (which `make setup` and
 * `make start` run before anything else), and a rewrite of Playwright's
 * launch error into the one command that fixes it, from the one directory
 * it works in.
 *
 * Both Chromium flavours are checked. Playwright ≥1.49 launches the
 * `chromium-headless-shell` build for a headless run and the full `chromium`
 * build for a headed one; `make start` needs the first, `make login` the
 * second, and `playwright install chromium` fetches both.
 */
import { existsSync } from "node:fs";
import path from "node:path";

/** The fix. From the directory whose pinned Playwright decides the build number. */
export const INSTALL_FIX = "cd session-capture && npx playwright install chromium";

/** Playwright's own words when the browser binary is not there. */
const MISSING_EXECUTABLE = /Executable doesn't exist at (.+)/;

/**
 * The directories Playwright's `install chromium` fills, derived from where
 * it says the full browser lives. The executable path is
 * `<cache>/chromium-<rev>/<platform>/…`; the headless shell is the sibling
 * `<cache>/chromium_headless_shell-<rev>/`. Playwright writes an
 * `INSTALLATION_COMPLETE` marker into each once the download finished — a
 * directory without it is a download that was interrupted.
 *
 * @param {string} executablePath what `chromium.executablePath()` returned
 * @returns {{cacheRoot: string, revision: string, dirs: Record<string, string>} | null}
 *   null when the path is not in the shape Playwright uses
 */
export function browserDirs(executablePath) {
  const segments = path.resolve(executablePath).split(path.sep);
  const index = segments.findIndex((segment) => /^chromium-\d+$/.test(segment));
  if (index < 0) return null;
  const revision = segments[index].slice("chromium-".length);
  const cacheRoot = segments.slice(0, index).join(path.sep) || path.sep;
  return {
    cacheRoot,
    revision,
    dirs: {
      chromium: path.join(cacheRoot, `chromium-${revision}`),
      "chromium-headless-shell": path.join(cacheRoot, `chromium_headless_shell-${revision}`),
    },
  };
}

/**
 * Which of the two builds are not completely installed.
 *
 * @param {string} executablePath
 * @param {{exists?: (p: string) => boolean}} [deps]
 * @returns {string[]} names, empty when both are present
 */
export function missingBrowsers(executablePath, { exists = existsSync } = {}) {
  const layout = browserDirs(executablePath);
  if (!layout) return ["chromium", "chromium-headless-shell"];
  return Object.entries(layout.dirs)
    .filter(([, dir]) => !exists(path.join(dir, "INSTALLATION_COMPLETE")))
    .map(([name]) => name);
}

/**
 * The message `make setup` and `make start` print when the check fails, or
 * null when the install is complete.
 *
 * @param {string} executablePath
 * @param {{exists?: (p: string) => boolean}} [deps]
 * @returns {string | null}
 */
export function installProblem(executablePath, deps = {}) {
  const missing = missingBrowsers(executablePath, deps);
  if (missing.length === 0) return null;
  const layout = browserDirs(executablePath);
  const where = layout ? ` (looked in ${layout.cacheRoot} for build ${layout.revision})` : "";
  return [
    `the daemon's Chromium is not installed: missing ${missing.join(" and ")}${where}.`,
    `The download runs during npm install and can be skipped or interrupted silently. Fix:`,
    ``,
    `    ${INSTALL_FIX}`,
    ``,
    `Run it from the repo root, in that directory: npx there uses the pinned Playwright, so it`,
    `fetches the build this daemon looks for. Run anywhere else it fetches a different one.`,
  ].join("\n");
}

/**
 * Playwright's launch error, rewritten so the rung's reason is the fix rather
 * than a banner that sends the person to the wrong directory. Any other
 * message passes through untouched.
 *
 * @param {string} message
 * @returns {string}
 */
export function explainLaunchError(message) {
  const match = MISSING_EXECUTABLE.exec(message);
  if (!match) return message;
  const executable = match[1].split("\n")[0].trim();
  return `the daemon's Chromium is not installed (Playwright looked for ${executable}). Fix: ${INSTALL_FIX}`;
}
