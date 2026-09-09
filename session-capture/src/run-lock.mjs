/**
 * One refresh at a time per root.
 *
 * Two daemon runs on the same root are not just wasteful, they break the
 * login: the profile directory is a Chromium user-data-dir, and a second
 * browser on it fails or corrupts it, and each run would push its own MFA
 * number. The runs that collide are real — `make start` launches the app and
 * then runs a refresh, and the app's own launch fetch (an empty cache is
 * infinitely stale) spawns a daemon run of its own two seconds earlier.
 *
 * So a run takes the lock before it does anything and the next run WAITS
 * rather than fails: by the time the lock frees, the session the first run
 * won is on disk, and the waiter's own climb costs nothing. A lock left by a
 * process that died holding it (SIGKILL mid-MFA) is recognised by its dead
 * pid and taken over. The file lives in the root, not in cache/, so a cache
 * reset cannot pretend a running login is not running.
 *
 * Pure enough to test without processes: liveness, the clock and the sleep
 * are injectable; only the file system is real.
 */
import { closeSync, mkdirSync, openSync, readFileSync, unlinkSync, writeSync } from "node:fs";
import path from "node:path";

/** How long a run waits for the previous one before giving up (a visible login may take 10 minutes). */
export const DEFAULT_LOCK_WAIT_MS = 12 * 60 * 1000;
export const LOCK_POLL_MS = 1000;

/** Whether `pid` is a live process. EPERM means alive-but-not-ours, which still counts. */
export function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

/**
 * Take the lock at `file`, waiting for a live holder and breaking a dead one.
 *
 * @param {string} file
 * @param {{pid?: number, isAlive?: (pid: number) => boolean, waitMs?: number,
 *          pollMs?: number, sleep?: (ms: number) => Promise<void>,
 *          log?: (m: string) => void}} [options]
 * @returns {Promise<{release: () => void}|null>} null when the wait ran out
 */
export async function acquireRunLock(file, {
  pid = process.pid,
  isAlive = processIsAlive,
  waitMs = DEFAULT_LOCK_WAIT_MS,
  pollMs = LOCK_POLL_MS,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  log = () => {},
} = {}) {
  mkdirSync(path.dirname(file), { recursive: true });
  const deadline = Date.now() + waitMs;
  let announced = false;
  for (;;) {
    // `wx`: create only if absent — the one atomic step the whole lock rests on.
    try {
      const fd = openSync(file, "wx");
      writeSync(fd, `${JSON.stringify({ pid, since: new Date().toISOString() })}\n`);
      closeSync(fd);
      return { release: () => releaseRunLock(file, pid) };
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }

    const holder = readHolder(file);
    if (holder === null || !isAlive(holder)) {
      // Dead holder (or an unreadable file nobody can own): take over.
      log(`breaking a stale refresh lock${holder === null ? "" : ` left by pid ${holder}`}`);
      try { unlinkSync(file); } catch { /* raced with another breaker — the retry decides */ }
      continue;
    }
    if (Date.now() >= deadline) return null;
    if (!announced) {
      log(`another refresh (pid ${holder}) is running on this root — waiting for it to finish`);
      announced = true;
    }
    await sleep(pollMs);
  }
}

/** Remove the lock, but only if it is still ours — never a successor's. */
function releaseRunLock(file, pid) {
  if (readHolder(file) !== pid) return;
  try { unlinkSync(file); } catch { /* already gone */ }
}

/** The pid in the lock file, or null when the file is missing or not ours to read. */
export function readHolder(file) {
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8"));
    return Number.isInteger(parsed?.pid) ? parsed.pid : null;
  } catch {
    return null;
  }
}
