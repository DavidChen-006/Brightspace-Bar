/**
 * The ladder: fetch with the credentials already on disk, and only if the
 * SESSION is what failed, climb the rungs — silent first, and the `full` rung
 * (the one that puts a browser in front of a human) only when the caller proved
 * a human is present. A timer spawn may climb rung 1 and no further; otherwise
 * cron pops a login window at 3am.
 *
 * Two invariants outrank freshness, because the menu bar is read by a human who
 * cannot tell "loading" from "gone":
 *
 *  1. A failed run leaves the app exactly as well off as it was — the existing
 *     data.json survives untouched (the `.preservedStale` mirror), and no
 *     half-written file is ever visible to the Swift reader.
 *  2. status.json says the true thing about what just happened, including
 *     carrying forward when the last SUCCESS was.
 *
 * Shape: `runRefresh` is the shell (clock, files, rungs, fetcher — all
 * injected); `statusFrom` and `exitCode` are the pure core. The world arrives
 * as deps so every ladder behavior is testable with plain values and a temp dir.
 *
 * D7: credentials live in session.json and stop there. Nothing here reads that
 * file, and every log line is composed from names and reasons this module owns
 * — never from a fetched or captured value.
 */
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";

/**
 * A rung: takes the world, tries to produce live credentials, reports honestly.
 * `kind` is "silent" (no human, cron-safe) or "full" (needs a present human).
 * Success is a side effect on session.json; the return value is only a verdict.
 *
 * @typedef {{kind: "silent"|"full",
 *            attempt: (world: {paths: object, log: (m: string) => void})
 *                       => Promise<{ok: true} | {ok: false, reason?: string}>}} Rung
 */

/**
 * Run one refresh to completion. NEVER throws and never rejects: the caller is
 * a CLI whose contract with Swift is an exit code, so every failure has to come
 * back as a status. Returns exactly the status object it wrote to disk.
 *
 * @param {{paths: object, fetcher: {fetch: Function}, clock: () => Date,
 *          rungs?: Rung[], allowFullLogin?: boolean, log?: (m: string) => void}} deps
 */
export async function runRefresh({
  paths,
  fetcher,
  clock,
  rungs = [],
  allowFullLogin = false,
  log = () => {},
}) {
  const now = clock().toISOString();
  const lastSuccessAt = readLastSuccessAt(paths.statusFile);

  let outcome;
  try {
    outcome = await climb({ paths, fetcher, rungs, allowFullLogin, log });
    // Inside the try: a cache we cannot write is a failed run, not a fresh one.
    if (outcome.ok) writeJsonAtomic(paths.dataFile, { fetchedAt: now, ...outcome.data });
  } catch (error) {
    outcome = { ok: false, state: "error", rungUsed: "none", error: describe(error) };
  }

  const status = statusFrom(outcome, { now, lastSuccessAt });
  try {
    writeJsonAtomic(paths.statusFile, status);
  } catch (error) {
    // The status file is the report, not the work. Losing it must not turn a
    // successful refresh into a rejected promise.
    log(`could not write status.json: ${describe(error)}`);
  }
  return status;
}

/**
 * The daemon's contract with the Swift app: 0 fresh · 2 needs-login · 1 anything
 * else. Unrecognized states map to 1 so a future state is never silently read
 * as success.
 */
export function exitCode(result) {
  if (result?.state === "fresh") return 0;
  if (result?.state === "needs-login") return 2;
  return 1;
}

/**
 * Fetch, and on an expired session walk the rungs until one restores it. Pure
 * control flow over two injected effects; returns a plain outcome.
 */
async function climb({ paths, fetcher, rungs, allowFullLogin, log }) {
  const world = { paths, log };
  let attempt = await fetcher.fetch(world);
  if (attempt.ok) return { ok: true, data: attempt.data, rungUsed: "none" };
  if (attempt.reason !== "sessionExpired") return failedFetch(attempt, "none");

  for (const [index, rung] of rungs.entries()) {
    const name = `rung ${index + 1} (${rung.kind})`;
    if (rung.kind === "full" && !allowFullLogin) {
      log(`skipping ${name}: full login needs a present human`);
      continue;
    }
    if (!(await climbed(rung, world, name, log))) continue;

    attempt = await fetcher.fetch(world);
    if (attempt.ok) return { ok: true, data: attempt.data, rungUsed: rung.kind };
    // Still expired after a rung claimed success: keep climbing.
    if (attempt.reason !== "sessionExpired") return failedFetch(attempt, rung.kind);
  }

  return {
    ok: false,
    state: "needs-login",
    rungUsed: "none",
    error: "the session is expired and no rung could restore it",
  };
}

/** One rung attempt. A rung that throws is a rung that failed — the ladder goes on. */
async function climbed(rung, world, name, log) {
  try {
    const result = await rung.attempt(world);
    if (result?.ok) {
      log(`${name} restored the session`);
      return true;
    }
    log(`${name} failed: ${result?.reason ?? "no reason given"}`);
  } catch (error) {
    log(`${name} threw: ${describe(error)}`);
  }
  return false;
}

/** A fetch that failed for a non-session reason — the network, not the login. */
function failedFetch(attempt, rungUsed) {
  const detail = attempt.detail ? `: ${attempt.detail}` : "";
  return { ok: false, state: "error", rungUsed, error: `${attempt.reason}${detail}` };
}

/** The pure core: an outcome plus two timestamps becomes the status contract. */
function statusFrom(outcome, { now, lastSuccessAt }) {
  return {
    state: outcome.ok ? "fresh" : outcome.state,
    rungUsed: outcome.rungUsed,
    lastAttemptAt: now,
    lastSuccessAt: outcome.ok ? now : lastSuccessAt,
    error: outcome.ok ? null : outcome.error,
  };
}

/**
 * When the last success was, per the status we wrote last time. A missing or
 * corrupt file means "we don't know", not a crash — the reader is the daemon's
 * own past self and its disk can be anything.
 */
function readLastSuccessAt(statusFile) {
  try {
    const previous = JSON.parse(readFileSync(statusFile, "utf8"));
    return typeof previous.lastSuccessAt === "string" ? previous.lastSuccessAt : null;
  } catch {
    return null;
  }
}

/**
 * Write via a temp file in the SAME directory then rename, so a reader in the
 * Swift app only ever sees a whole file (rename is atomic within a filesystem).
 * The temp file never outlives the call: a failed rename cleans up after itself
 * rather than leaving debris in the directory the app watches.
 */
function writeJsonAtomic(file, value) {
  const dir = path.dirname(file);
  mkdirSync(dir, { recursive: true });
  const temp = path.join(dir, `.${path.basename(file)}.${process.pid}.tmp`);
  try {
    writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`);
    renameSync(temp, file);
  } catch (error) {
    rmSync(temp, { force: true });
    throw error;
  }
}

const describe = (error) => String(error?.message ?? error);
