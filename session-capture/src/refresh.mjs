/**
 * The daemon entry point: run one refresh and exit with the code the Swift app
 * reads — 0 fresh · 2 needs-login · 1 unexpected error.
 *
 * Deliberately thin. Everything worth testing lives in orchestrate.mjs behind
 * injected seams; this file only turns argv into deps and a status into an exit
 * code. `--no-full-login` is the opt-out bit: by default every spawn — the
 * app's timer, its launch, a terminal — may climb the whole ladder, full login
 * included, because the last rung is the one that makes the menu bar never go
 * stale. Pass the flag for a run that must not touch a phone: a test suite, a
 * cron on a shared machine. (The full rung is headless by default; the MFA
 * number reaches the human through the status-bar icon. `--visible` is the
 * other way round: a window opens and the human finishes the sign-in in it —
 * what `make login` runs, for the accounts the headless flow cannot read.)
 *
 * `--help` must stay free of side effects — no files, no browser import. It is
 * the one command a human runs to find out what this thing does.
 */
import { createFetcher } from "./fetch-engine.mjs";
import { DEFAULT_FULL_LOGIN_BACKOFF_MS, exitCode, runRefresh } from "./orchestrate.mjs";
import { resolvePaths } from "./paths.mjs";
import { createFullLoginRung } from "./rungs/full-login.mjs";
import { createSilentRung } from "./rungs/silent.mjs";

const USAGE = `Usage: node src/refresh.mjs [--no-full-login | --visible]

Climbs the session ladder and writes the course cache under BSB_ROOT
(default ~/Library/Application Support/BrightspaceBar).

  --no-full-login  skip the full login rung (the one that types the stored
                   credentials and puts an MFA number on the menu-bar icon).
                   By default it is allowed, so the ladder never stops one
                   rung short of a working session. Pass this for runs that
                   must never reach a phone: tests, a shared machine.
  --visible        run the full login rung in a VISIBLE Chromium window and
                   let the human finish the sign-in there — the fallback when
                   the headless flow cannot (a method chooser, a code prompt,
                   an MFA setup page, a field that never appears). Same
                   profile, same session file, same everything after. This
                   is what \`make login\` runs. Contradicts --no-full-login.
  --help           print this and exit

Environment:
  BSB_FULL_LOGIN_BACKOFF_MS
                   how long after one full-login attempt the next may begin,
                   in ms (default ${DEFAULT_FULL_LOGIN_BACKOFF_MS} = 4 hours).
                   Each attempt pushes an MFA number to a phone, and the app
                   ticks every 30 minutes; the backoff keeps a night away from
                   becoming a night of pushes. 0 disables it — what
                   \`make start\` sets, because a human is present.

Exit codes: 0 fresh cache written · 2 needs login · 1 error`;

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(USAGE);
  process.exit(0);
}

const KNOWN = new Set(["--no-full-login", "--visible"]);
const unknown = args.filter((arg) => !KNOWN.has(arg));
if (unknown.length > 0) {
  // A typo'd opt-out must not silently become a run that reaches for a phone.
  console.error(`unknown argument: ${unknown[0]}\n\n${USAGE}`);
  process.exit(1);
}
const visible = args.includes("--visible");
if (visible && args.includes("--no-full-login")) {
  // One flag asks for the rung with a window, the other forbids the rung.
  console.error(`--visible and --no-full-login contradict each other\n\n${USAGE}`);
  process.exit(1);
}

const status = await runRefresh({
  paths: resolvePaths(),
  // The ladder, cheapest rung first. The full one is climbed unless the caller
  // passed --no-full-login; the gate itself lives in orchestrate.mjs.
  rungs: [createSilentRung(), createFullLoginRung({ visible })],
  fetcher: createFetcher(),
  clock: () => new Date(),
  allowFullLogin: !args.includes("--no-full-login"),
  fullLoginBackoffMs: backoffFromEnv(process.env.BSB_FULL_LOGIN_BACKOFF_MS),
  log: (message) => console.error(message),
});

console.error(`${status.state} (rung: ${status.rungUsed})${status.error ? ` — ${status.error}` : ""}`);
process.exit(exitCode(status));

/** Unset or unparseable means the default — a typo must not disable the backoff. */
function backoffFromEnv(value) {
  if (value === undefined || value === "") return DEFAULT_FULL_LOGIN_BACKOFF_MS;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : DEFAULT_FULL_LOGIN_BACKOFF_MS;
}
