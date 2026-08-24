/**
 * The one place credentials come from. The full-login rung needs BS_EMAIL and
 * BS_PASSWORD to autofill the Microsoft page, but demanding env vars on every
 * run puts the password into shell history and agent transcripts. So this
 * module adds a second source — `<BSB_ROOT>/credentials.json`, mode 0600 —
 * behind one lookup, and the priority is fixed: env when BOTH vars are set
 * (an explicit export always wins over a stale file), the file otherwise,
 * null when neither is complete.
 *
 * D7 still holds: credentials stay in the Node daemon's world. The file lives
 * beside session.json under BSB_ROOT (never in the repo), nothing here ever
 * logs a password, and the Swift app has no reader for it.
 *
 * The prompt is deliberately TTY-only and refuses otherwise: a headless spawn
 * that "prompts" is a hang, and an agent piping stdin must never be able to
 * feed a password through here by accident.
 */
import { chmodSync, readFileSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { writeJsonAtomic } from "./atomic-write.mjs";
import { resolvePaths } from "./paths.mjs";

/** @param {{BSB_ROOT?: string}} [env] @returns {string} */
export function credentialsFile(env = process.env) {
  return path.join(resolvePaths(env).root, "credentials.json");
}

/**
 * Env first (both vars or it doesn't count — half a credential is no
 * credential), then the file, then null.
 *
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {{email: string, password: string} | null}
 */
export function loadCredentials(env = process.env) {
  if (env.BS_EMAIL && env.BS_PASSWORD) {
    return { email: env.BS_EMAIL, password: env.BS_PASSWORD };
  }
  try {
    const parsed = JSON.parse(readFileSync(credentialsFile(env), "utf8"));
    if (parsed && typeof parsed.email === "string" && parsed.email
      && typeof parsed.password === "string" && parsed.password) {
      return { email: parsed.email, password: parsed.password };
    }
  } catch {
    // Missing or corrupt file means "no stored credentials", not a crash —
    // the caller decides whether to prompt or to fail with instructions.
  }
  return null;
}

/**
 * Atomic write, then chmod to 0600 — the rename lands with default perms, and
 * an already-existing file may have been created looser by an older build.
 *
 * @param {{email: string, password: string}} credentials
 * @param {NodeJS.ProcessEnv} [env]
 */
export function saveCredentials({ email, password }, env = process.env) {
  const file = credentialsFile(env);
  writeJsonAtomic(file, { email, password });
  chmodSync(file, 0o600);
  return file;
}

/**
 * Ask on the terminal: email in the clear, password with echo suppressed by
 * putting stdin in raw mode and handling the keystrokes ourselves — readline
 * alone would echo the password back onto the screen. Saves what it collected
 * and returns it.
 *
 * @returns {Promise<{email: string, password: string}>}
 */
export async function promptForCredentials(env = process.env) {
  if (!process.stdin.isTTY) {
    throw new Error(
      "cannot prompt for credentials: stdin is not a TTY — set BS_EMAIL and BS_PASSWORD instead",
    );
  }

  const rl = readline.createInterface({ input: process.stdin, output: process.stderr });
  try {
    const email = (await question(rl, "Brightspace email: ")).trim();
    const password = await readMasked("Brightspace password (input hidden): ");
    if (!email || !password) throw new Error("email and password are both required");
    const file = saveCredentials({ email, password }, env);
    console.error(`saved credentials to ${file} (mode 0600)`);
    return { email, password };
  } finally {
    rl.close();
  }
}

function question(rl, text) {
  return new Promise((resolve) => rl.question(text, resolve));
}

/** Raw-mode line read: every key handled by hand so nothing is ever echoed. */
function readMasked(promptText) {
  return new Promise((resolve, reject) => {
    const stdin = process.stdin;
    process.stderr.write(promptText);
    stdin.setRawMode(true);
    stdin.resume();
    let value = "";
    const onData = (chunk) => {
      for (const ch of chunk.toString("utf8")) {
        if (ch === "\u0003") { // ctrl-c: restore the terminal before dying
          cleanup();
          process.stderr.write("\n");
          reject(new Error("interrupted"));
          return;
        }
        if (ch === "\r" || ch === "\n") {
          cleanup();
          process.stderr.write("\n");
          resolve(value);
          return;
        }
        if (ch === "\u007f" || ch === "\b") {
          value = value.slice(0, -1);
        } else {
          value += ch;
        }
      }
    };
    const cleanup = () => {
      stdin.setRawMode(false);
      stdin.pause();
      stdin.off("data", onData);
    };
    stdin.on("data", onData);
  });
}
