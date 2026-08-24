/**
 * The one-command start flow, MCP-server style: `make start` builds the Swift
 * app and lands here, and this script does the rest — make sure credentials
 * exist (prompting on a TTY when they don't), get the menu-bar app on screen,
 * then run one headless full refresh so the bar has data before the human
 * looks at it.
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
const APP_BINARY = path.join(REPO_ROOT, "BrightspaceBar", ".build", "debug", "BrightspaceBar");

// 1. Credentials: load, or prompt when a human is on the other end.
let credentials = loadCredentials();
if (!credentials) {
  if (process.stdin.isTTY) {
    console.error("No stored credentials — one-time setup (saved to credentials.json, mode 0600).");
    credentials = await promptForCredentials();
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
  console.error(`app binary not found at ${APP_BINARY} — run \`make start\` (it builds first)`);
  process.exit(1);
} else {
  const app = spawn(APP_BINARY, [], { detached: true, stdio: "ignore" });
  app.unref();
  console.error("launched BrightspaceBar into the menu bar");
}

// Give the app a beat to draw its icon before the refresh starts writing the
// cache it watches — cosmetic, not correctness (the writes are atomic).
await new Promise((resolve) => setTimeout(resolve, 2000));

// 3. One full refresh, human present by definition (they just ran `make start`).
console.error("");
console.error("Refreshing the session (headless). If an MFA prompt fires, the number");
console.error("appears ON THE MENU-BAR ICON — approve it on your phone.");
console.error("");

const refresh = spawn(
  process.execPath,
  [path.join(__dirname, "refresh.mjs"), "--allow-full-login"],
  {
    cwd: path.join(__dirname, ".."),
    stdio: "inherit",
    env: {
      ...process.env,
      ...(credentials ? { BS_EMAIL: credentials.email, BS_PASSWORD: credentials.password } : {}),
    },
  },
);

refresh.on("exit", (code) => {
  const verdict = code === 0
    ? "session fresh — the menu bar is live"
    : code === 2
      ? "needs login — the ladder could not restore the session"
      : "refresh errored — see the log above";
  console.error(verdict);
  process.exit(code ?? 1);
});
