/**
 * Shared test scaffolding for the phase-1 orchestrator spine.
 *
 * Two rules shape everything here:
 *
 *  1. HERMETIC. Every test gets its own BSB_ROOT under os.tmpdir(), removed
 *     when the test ends. No test may touch the real
 *     `~/Library/Application Support/BrightspaceBar`, the network, or a
 *     browser — the daemon's real credentials are production data.
 *  2. THE WORLD IS INJECTED. Rungs, the fetcher and the clock are the three
 *     seams `runRefresh` takes as deps. The fakes below script their answers,
 *     record their calls, and never do I/O of their own, so every ladder
 *     behavior is a small (Google-small) test with no wall-clock dependence.
 */
import { execFile } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { resolvePaths } from "../src/paths.mjs";

/** The session-capture package root — tests spawn CLIs relative to it. */
export const PKG_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/**
 * A fresh empty BSB_ROOT plus its resolved subpaths, torn down after the test.
 * Note it is EMPTY: `cache/` does not exist yet, so the happy path also proves
 * the orchestrator creates what it needs.
 */
export function tempPaths(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), "bsb-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return resolvePaths({ BSB_ROOT: root });
}

/** A bare temp directory (for reset.sh's "never reaches outside the root" test). */
export function tempDir(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), "bsb-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

/** The one instant the whole suite happens at. Never Date.now(). */
export const FIXED_ISO = "2026-08-15T14:00:00.000Z";
export const fixedClock = () => new Date(FIXED_ISO);

/** A data.json payload minus fetchedAt — exactly what the fetcher returns. */
export const SAMPLE_DATA = {
  courses: [
    {
      id: 412690,
      name: "Multivariate Calculus",
      code: "MA 26100",
      role: "Student",
      isActive: true,
      homeUrl: null,
      startDate: null,
      endDate: null,
    },
  ],
  assignments: {
    412690: [
      {
        id: 1,
        title: "HW 3",
        dueDate: "2026-08-20T04:59:00Z",
        url: "https://purdue.brightspace.com/d2l/le/412690/hw3",
        kind: "assignment",
      },
    ],
  },
};

/** A second, distinguishable payload — proves a refetch's data is the one kept. */
export const REFETCHED_DATA = {
  courses: [{ ...SAMPLE_DATA.courses[0], id: 999001, name: "After The Rung", code: "CS 18000" }],
  assignments: {},
};

export const ok = (data) => ({ ok: true, data });
export const expired = () => ({ ok: false, reason: "sessionExpired" });
export const transport = (detail = "connect ECONNREFUSED") => ({
  ok: false,
  reason: "transport",
  detail,
});

/**
 * A fetcher that answers from a script, one entry per call, and records the
 * arguments it was handed. Past the end of the script it reports a transport
 * failure rather than throwing, so an over-eager implementation fails a
 * call-count assertion instead of being disguised as an unexpected error.
 */
export function scriptedFetcher(script) {
  const calls = [];
  return {
    calls,
    async fetch(args) {
      calls.push(args);
      return script[calls.length - 1] ?? transport("fetcher script exhausted");
    },
  };
}

/** A fetcher that blows up — the unexpected-error path the CLI maps to exit 1. */
export function throwingFetcher(message) {
  const calls = [];
  return {
    calls,
    async fetch(args) {
      calls.push(args);
      throw new Error(message);
    },
  };
}

/**
 * A ladder of fake rungs sharing one `attempted` trace, so rung ORDER and rung
 * SKIPPING are both readable off a single array.
 *
 * spec: { kind, result, throws, onAttempt } — `result` is the rung's return
 * value, `throws` makes attempt() reject, `onAttempt` runs a side effect (used
 * to simulate a rung writing credentials to session.json).
 */
export function ladder() {
  const attempted = [];
  const rung = (name, spec = {}) => {
    const { kind = "silent", result = { ok: true }, throws = null, onAttempt = null } = spec;
    const calls = [];
    return {
      name,
      kind,
      calls,
      async attempt(args) {
        attempted.push(name);
        calls.push(args);
        if (onAttempt) await onAttempt(args);
        if (throws) throw new Error(throws);
        return result;
      },
    };
  };
  return { attempted, rung };
}

/** Collects log lines so a test can assert what was NEVER said. */
export function recorder() {
  const lines = [];
  return {
    lines,
    log: (message) => lines.push(String(message)),
    text: () => lines.join("\n"),
  };
}

/**
 * Run a child process and resolve — never reject — with its exit code and
 * output, so a missing script fails the assertion it belongs to instead of
 * exploding the test file.
 */
export function run(command, args, options = {}) {
  return new Promise((resolve) => {
    execFile(command, args, { cwd: PKG_DIR, ...options }, (error, stdout, stderr) => {
      if (!error) return resolve({ code: 0, stdout, stderr });
      const code = typeof error.code === "number" ? error.code : -1;
      resolve({ code, stdout, stderr: stderr || error.message });
    });
  });
}
