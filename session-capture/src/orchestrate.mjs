/**
 * The ladder: fetch with the credentials already on disk, and only if the
 * SESSION is what failed, climb the rungs — silent first, then the `full` rung
 * (the one that types the stored credentials and puts an MFA number on the
 * status-bar icon). Every rung is allowed by default: the app's timer spawns
 * this with no arguments, and the last rung is what keeps the menu bar from
 * ever going stale. A caller that must not reach a phone — a test suite, a
 * shared machine — opts out with `allowFullLogin: false` (`--no-full-login`).
 *
 * The full rung is rate-limited, because it is the one rung with a cost outside
 * the machine: every attempt pushes a number-match to a phone. The app ticks
 * every 30 minutes, and a wristband that dies overnight would otherwise become
 * a night of MFA pushes and, eventually, a throttled Entra account. So the run
 * that attempts the full rung stamps `lastFullLoginAttemptAt` into status.json,
 * and later runs skip that rung until `fullLoginBackoffMs` has passed. One
 * approval fixes the wristband for ~90 days, so the backoff only ever costs a
 * few hours on the nights nobody was there. A present human (`make start`)
 * sets the backoff to zero via `BSB_FULL_LOGIN_BACKOFF_MS`.
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
import { readFileSync } from "node:fs";
import { writeJsonAtomic } from "./atomic-write.mjs";

/**
 * How long after a full-login attempt the next one may begin. Four hours: long
 * enough that a night away costs two or three pushes rather than sixteen,
 * short enough that a wristband dead at breakfast is healed by lunch.
 */
export const DEFAULT_FULL_LOGIN_BACKOFF_MS = 4 * 60 * 60 * 1000;

/**
 * A rung: takes the world, tries to produce live credentials, reports honestly.
 * `kind` is "silent" (no human involved) or "full" (a phone must approve it).
 * Success is a side effect on session.json; the return value is only a verdict.
 *
 * @typedef {{kind: "silent"|"full",
 *            attempt: (world: {paths: object, log: (m: string) => void})
 *                       => Promise<{ok: true} | {ok: false, reason?: string}>}} Rung
 */

/**
 * The fetcher seam. It reads the credentials itself (session.json, via paths)
 * and reports a classified failure — `sessionExpired` is the ONLY reason that
 * makes the ladder climb, so a fetch engine that returns a dead session under
 * any other reason turns a re-mintable lapse into a permanent error state.
 *
 * `data` is the payload MINUS fetchedAt: the orchestrator stamps that from the
 * injected clock, and a fetchedAt of the fetcher's own would override it.
 *
 * @typedef {{fetch: (world: {paths: object, log: (m: string) => void}) => Promise<
 *             {ok: true, data: {courses: object[], assignments: object,
 *                               announcements: object}}
 *           | {ok: false, reason: "sessionExpired"}
 *           | {ok: false, reason: string, detail?: string}>}} Fetcher
 */

/**
 * Run one refresh to completion. NEVER throws and never rejects: the caller is
 * a CLI whose contract with Swift is an exit code, so every failure has to come
 * back as a status. Returns exactly the status object it wrote to disk.
 *
 * @param {{paths: object, fetcher: {fetch: Function}, clock: () => Date,
 *          rungs?: Rung[], allowFullLogin?: boolean, fullLoginBackoffMs?: number,
 *          log?: (m: string) => void}} deps
 */
export async function runRefresh({
  paths,
  fetcher,
  clock,
  rungs = [],
  allowFullLogin = true,
  fullLoginBackoffMs = DEFAULT_FULL_LOGIN_BACKOFF_MS,
  log = () => {},
}) {
  const now = clock().toISOString();
  const previous = readPreviousStatus(paths.statusFile);

  let outcome;
  try {
    outcome = await climb({
      paths, fetcher, rungs, allowFullLogin, log,
      now,
      fullLoginBackoffMs,
      lastFullLoginAttemptAt: previous.lastFullLoginAttemptAt,
    });
    // Inside the try: a cache we cannot write is a failed run, not a fresh one.
    if (outcome.ok) writeJsonAtomic(paths.dataFile, { fetchedAt: now, ...outcome.data });
  } catch (error) {
    outcome = { ok: false, state: "error", rungUsed: "none", error: describe(error) };
  }

  const status = statusFrom(outcome, { now, previous });
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
 *
 * The outcome carries `fullLoginAttemptedAt` — the run's own `now` when a full
 * rung was entered, else undefined — so the status can stamp the attempt
 * whether the rung then succeeded, failed, or threw. Stamped BEFORE the attempt
 * on purpose: an attempt that is SIGKILLed mid-MFA still pushed to the phone.
 */
async function climb({
  paths, fetcher, rungs, allowFullLogin, log, now, fullLoginBackoffMs, lastFullLoginAttemptAt,
}) {
  const world = { paths, log };
  let attempt = await fetcher.fetch(world);
  if (attempt.ok) return { ok: true, data: attempt.data, rungUsed: "none" };
  if (attempt.reason !== "sessionExpired") return failedFetch(attempt, "none");

  let fullLoginAttemptedAt;
  let backedOffUntil = null;
  for (const [index, rung] of rungs.entries()) {
    const name = `rung ${index + 1} (${rung.kind})`;
    if (rung.kind === "full") {
      if (!allowFullLogin) {
        log(`skipping ${name}: full login opted out (--no-full-login)`);
        continue;
      }
      const until = backoffEnds(lastFullLoginAttemptAt, fullLoginBackoffMs);
      if (until && Date.parse(now) < until) {
        backedOffUntil = new Date(until).toISOString();
        log(`skipping ${name}: a full login was attempted at ${lastFullLoginAttemptAt}; next one after ${backedOffUntil}`);
        continue;
      }
      fullLoginAttemptedAt = now;
    }
    if (!(await climbed(rung, world, name, log))) continue;

    attempt = await fetcher.fetch(world);
    if (attempt.ok) return { ok: true, data: attempt.data, rungUsed: rung.kind, fullLoginAttemptedAt };
    // Still expired after a rung claimed success: keep climbing.
    if (attempt.reason !== "sessionExpired") return { ...failedFetch(attempt, rung.kind), fullLoginAttemptedAt };
  }

  return {
    ok: false,
    state: "needs-login",
    rungUsed: "none",
    fullLoginAttemptedAt,
    error: backedOffUntil
      ? `the session is expired and no rung could restore it; full login backed off until ${backedOffUntil}`
      : "the session is expired and no rung could restore it",
  };
}

/**
 * When the backoff window closes, as epoch ms — or null when there is nothing
 * to back off from: no previous attempt, an unparseable stamp (treated as
 * "never", since the alternative is a rung that can never run again), or a
 * backoff of zero (a present human asked for the login now).
 */
function backoffEnds(lastFullLoginAttemptAt, fullLoginBackoffMs) {
  if (!(fullLoginBackoffMs > 0)) return null;
  const last = Date.parse(lastFullLoginAttemptAt ?? "");
  return Number.isNaN(last) ? null : last + fullLoginBackoffMs;
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

/** The pure core: an outcome, the run's instant and the previous status become the status contract. */
function statusFrom(outcome, { now, previous }) {
  return {
    state: outcome.ok ? "fresh" : outcome.state,
    rungUsed: outcome.rungUsed,
    lastAttemptAt: now,
    lastSuccessAt: outcome.ok ? now : previous.lastSuccessAt,
    // Carried forward across runs that never reached the full rung: the
    // backoff is measured from the last attempt, whenever that was.
    lastFullLoginAttemptAt: outcome.fullLoginAttemptedAt ?? previous.lastFullLoginAttemptAt,
    error: outcome.ok ? null : outcome.error,
  };
}

/**
 * The two stamps carried forward from the status we wrote last time. A missing
 * or corrupt file means "we don't know", not a crash — the reader is the
 * daemon's own past self and its disk can be anything — and a status written
 * before a stamp existed simply lacks it.
 */
function readPreviousStatus(statusFile) {
  let previous = {};
  try {
    previous = JSON.parse(readFileSync(statusFile, "utf8")) ?? {};
  } catch {
    // Fall through with nothing known.
  }
  const stamp = (value) => (typeof value === "string" ? value : null);
  return {
    lastSuccessAt: stamp(previous.lastSuccessAt),
    lastFullLoginAttemptAt: stamp(previous.lastFullLoginAttemptAt),
  };
}

const describe = (error) => String(error?.message ?? error);
