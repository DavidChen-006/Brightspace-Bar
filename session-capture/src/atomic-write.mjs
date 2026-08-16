/**
 * The one way this daemon puts JSON in a directory the Swift app watches.
 *
 * Two readers make this non-negotiable: the app polls `cache/data.json`, and the
 * icon watcher wakes on a `cache/` directory event and re-reads immediately
 * (experiment 17 measured one atomic write as TWO events, the first of them a
 * lie). A partially written file is a reader parsing garbage, and a leftover
 * temp file is a reader waking up for debris.
 */
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";

/**
 * Write via a temp file in the SAME directory then rename, so a reader only ever
 * sees a whole file (rename is atomic within a filesystem). The temp file never
 * outlives the call: a failed rename cleans up after itself rather than leaving
 * debris in the directory the app watches.
 *
 * @param {string} file
 * @param {unknown} value
 */
export function writeJsonAtomic(file, value) {
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
