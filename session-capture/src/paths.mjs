/**
 * Every file the daemon touches hangs off ONE root, so pointing `BSB_ROOT` at a
 * temp directory is the whole test-isolation story. That only holds if this
 * module is the single place the layout is decided — nothing else in the daemon
 * may join a path onto the root by hand.
 *
 * Resolution is pure: it reports where things go, it never creates them. The
 * writers create what they need, so a `--help` (or any read-only path) can
 * resolve paths without leaving a directory behind in David's Library.
 */
import os from "node:os";
import path from "node:path";

/** Where the real install lives when BSB_ROOT is unset. Mirrored in scripts/reset.sh. */
const DEFAULT_ROOT = ["Library", "Application Support", "BrightspaceBar"];

/**
 * @param {{BSB_ROOT?: string}} [env] defaults to the process environment
 * @returns {{root: string, profileDir: string, sessionFile: string,
 *            cacheDir: string, dataFile: string, statusFile: string}}
 */
export function resolvePaths(env = process.env) {
  // An empty BSB_ROOT (`BSB_ROOT= node …`) means "unset", never "/" — the
  // difference between a default install and a root-directory reset.
  const root = env.BSB_ROOT
    ? path.resolve(env.BSB_ROOT)
    : path.join(os.homedir(), ...DEFAULT_ROOT);
  const cacheDir = path.join(root, "cache");
  return {
    root,
    profileDir: path.join(root, "profile"),
    sessionFile: path.join(root, "session.json"),
    cacheDir,
    dataFile: path.join(cacheDir, "data.json"),
    statusFile: path.join(cacheDir, "status.json"),
  };
}
