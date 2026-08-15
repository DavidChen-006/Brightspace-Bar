/**
 * The daemon entry point: run one refresh and exit with the code the Swift app
 * reads — 0 fresh · 2 needs-login · 1 unexpected error.
 *
 * Deliberately thin. Everything worth testing lives in orchestrate.mjs behind
 * injected seams; this file only turns argv into deps and a status into an exit
 * code. `--allow-full-login` is the permission bit: the timer spawn omits it
 * (cron may only ever climb the silent rung), the manual Refresh click passes
 * it, because the click is the proof that a human is present for the MFA.
 *
 * `--help` must stay free of side effects — no files, no browser import. It is
 * the one command a human runs to find out what this thing does.
 */
import { createFetcher } from "./fetch-engine.mjs";
import { exitCode, runRefresh } from "./orchestrate.mjs";
import { resolvePaths } from "./paths.mjs";
import { createFullLoginRung } from "./rungs/full-login.mjs";
import { createSilentRung } from "./rungs/silent.mjs";

const USAGE = `Usage: node src/refresh.mjs [--allow-full-login]

Climbs the session ladder and writes the course cache under BSB_ROOT
(default ~/Library/Application Support/BrightspaceBar).

  --allow-full-login  permit the headed login rung, which needs a human
                      present to approve the MFA prompt. Omit it for
                      unattended runs (timer, launch).
  --help              print this and exit

Exit codes: 0 fresh cache written · 2 needs login · 1 error`;

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(USAGE);
  process.exit(0);
}

const unknown = args.filter((arg) => arg !== "--allow-full-login");
if (unknown.length > 0) {
  // A typo'd permission flag must not silently become an unattended run.
  console.error(`unknown argument: ${unknown[0]}\n\n${USAGE}`);
  process.exit(1);
}

const status = await runRefresh({
  paths: resolvePaths(),
  // The ladder, cheapest rung first. The full one is skipped unless the caller
  // passed --allow-full-login; the gate itself lives in orchestrate.mjs.
  rungs: [createSilentRung(), createFullLoginRung()],
  fetcher: createFetcher(),
  clock: () => new Date(),
  allowFullLogin: args.includes("--allow-full-login"),
  log: (message) => console.error(message),
});

console.error(`${status.state} (rung: ${status.rungUsed})${status.error ? ` — ${status.error}` : ""}`);
process.exit(exitCode(status));
