/**
 * The one-command start flow, MCP-server style: `make start` builds the Swift
 * app and lands here, and this script does the rest — make sure credentials
 * exist (prompting on a TTY when they don't), get the menu-bar app on screen,
 * then run one full refresh so the bar has data before the human looks at it.
 *
 * `--visible` is `make login`: the same flow, but the refresh's full-login
 * rung opens a Chromium window and the human finishes the sign-in there. It
 * exists for every account the headless flow cannot read — a method chooser,
 * a code prompt, an MFA setup page — and it stores the same credentials and
 * writes the same profile and session file, so the silent refresh and the
 * next headless full login work exactly as they would have.
 *
 * The app is spawned detached with its stdio ignored and unref'd: it must
 * outlive this script, which exits as soon as the refresh reports. The refresh
 * child, by contrast, INHERITS stdio — its ladder log is the start command's
 * output, and its exit code (0 fresh · 2 needs-login · 1 error) becomes ours.
 *
 * Credentials ride into the refresh child as BS_EMAIL/BS_PASSWORD in the child
 * env only — never on the command line, where `ps` would show them to every
 * process on the machine.
 */
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadCredentials, promptForCredentials } from "./credentials.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.join(__dirname, "..", "..");
const APP = path.join(REPO_ROOT, "BrightspaceBar", ".build", "debug", "BrightspaceBar.app");
// Both overridable so a test can stand in a script for the app and the daemon.
const APP_BINARY = process.env.BSB_APP_BINARY ?? path.join(APP, "Contents", "MacOS", "BrightspaceBar");
const REFRESH_CLI = process.env.BSB_REFRESH_CLI ?? path.join(__dirname, "refresh.mjs");

const USAGE = "Usage: node src/start.mjs [--visible]";
const args = process.argv.slice(2);
const unknown = args.filter((arg) => arg !== "--visible");
if (unknown.length > 0) {
  console.error(`unknown argument: ${unknown[0]}\n${USAGE}`);
  process.exit(1);
}
const visible = args.includes("--visible");

// 1. Credentials: load, or prompt when a human is on the other end. The
//    visible login prompts too: it is not a way around storing them — the
//    stored credentials are what lets the next FULL login run headless, and
//    the window only exists for the sign-in the autofill cannot finish alone.
let credentials = loadCredentials();
if (!credentials) {
  if (process.stdin.isTTY) {
    console.error("No stored credentials — one-time setup (saved to credentials.json, mode 0600).");
    if (visible) {
      console.error("They are typed into Microsoft's sign-in page for you; you finish MFA in the window.");
    }
    credentials = await promptForCredentials();
  } else if (visible) {
    console.error("no stored credentials and no TTY to prompt on — you will sign in fully in the window.");
  } else {
    console.error(
      "warning: no credentials (env or credentials.json) and no TTY to prompt on — "
        + "the full-login rung will fail if the silent session is dead.",
    );
  }
}

// 2. The menu-bar app. One instance only — the icon is a singleton by meaning
// even if not by mechanism, and two writers on the cache help nobody. The
// pattern is the BINARY PATH, not the bare name: `pgrep -f BrightspaceBar`
// also matches the view Chromium, whose command line carries the profile dir
// `.../Application Support/BrightspaceBar/profile` — a browser tab left open
// then silently suppressed the app launch (live bug, 2026-08-24).
const running = spawnSync("pgrep", ["-f", APP_BINARY]).status === 0;
if (running) {
  console.error("BrightspaceBar is already running — not launching a second copy.");
} else if (!existsSync(APP_BINARY)) {
  console.error(`app bundle not found at ${APP}: run \`make start\` (it builds it first)`);
  process.exit(1);
} else {
  // The executable INSIDE the bundle, spawned directly — not `open -n`.
  // LaunchServices does not pass the caller's environment through, so a
  // BSB_ROOT set for `make start` would be dropped and the app would read
  // the production root. Spawning the binary keeps the environment, and
  // Bundle.main still resolves to the .app because that is where the
  // executable lives, so MotionP.pdf loads either way.
  const app = spawn(APP_BINARY, [], { detached: true, stdio: "ignore" });
  app.unref();
  console.error("launched BrightspaceBar into the menu bar");
}

// Give the app a beat to draw its icon before the refresh starts writing the
// cache it watches — cosmetic, not correctness (the writes are atomic).
await new Promise((resolve) => setTimeout(resolve, 2000));

// 3. One refresh. The full rung is on by default (no flag needed), and its
//    backoff is lifted: a human is present by definition — they just ran
//    `make start` — so a timer tick's earlier attempt must not delay them.
console.error("");
if (visible) {
  console.error("Refreshing the session with a VISIBLE browser. If a sign-in is needed, a Chromium");
  console.error("window opens: your stored credentials are typed in for you, then you finish");
  console.error("whatever Microsoft asks — MFA, a method choice, a setup step — in that window.");
} else {
  console.error("Refreshing the session (headless). If an MFA prompt fires, the number");
  console.error("appears ON THE MENU-BAR ICON — approve it on your phone.");
  console.error("If no number appears and the menu stays empty, run `make login`.");
}
console.error("");

const refresh = spawn(
  process.execPath,
  [REFRESH_CLI, ...(visible ? ["--visible"] : [])],
  {
    cwd: path.join(__dirname, ".."),
    stdio: "inherit",
    env: {
      ...process.env,
      BSB_FULL_LOGIN_BACKOFF_MS: "0",
      ...(credentials ? { BS_EMAIL: credentials.email, BS_PASSWORD: credentials.password } : {}),
    },
  },
);

refresh.on("exit", (code) => {
  const verdict = code === 0
    ? "session fresh — the menu bar is live"
    : code === 2
      ? visible
        ? "needs login — the sign-in did not finish; read the log above and run `make login` again"
        : "needs login — the ladder could not restore the session. Run `make login` to finish the sign-in in a browser window."
      : "refresh errored — see the log above";
  console.error(verdict);
  process.exit(code ?? 1);
});
