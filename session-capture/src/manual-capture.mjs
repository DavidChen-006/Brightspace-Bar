/**
 * Manual-login session capture: try the SILENT path first, and only when that
 * fails, let the HUMAN sign in completely — then harvest the cookie.
 *
 * Why this exists alongside auto-capture.mjs: that script types the password
 * itself, so it needs BS_EMAIL/BS_PASSWORD in the environment. This one never
 * sees a credential at all — when a login is needed, the operator types
 * everything into the visible window, including MFA. That makes it the only
 * capture path safe to run from an agent's shell, and it is also the closer
 * analogue of the eventual in-app WKWebView login, where the user signs in and
 * we only read the resulting cookie store.
 *
 * PERSISTENT PROFILE (experiment 10): the browser runs on artifacts/profile,
 * so the Microsoft Entra cookie from your last real login survives between
 * runs. Most captures therefore finish silently in seconds — campus selector →
 * sso.purdue.edu → login.microsoftonline.com → authenticated — and you are
 * only asked to sign in when the Entra session itself has expired (~90-day
 * cookie, real cadence being measured in experiment 10's journal).
 *
 * The output contract is NOT reimplemented here: `buildCookieHeader` and
 * `buildSession` come from ./session.mjs, so session.json has one definition
 * across every capture path. The shared login mechanics (positive auth check,
 * XSRF extraction, the silent path) live in ./login-flow.mjs for the same
 * reason.
 *
 * GET-only: this drives navigation and reads cookies. It submits nothing.
 * Secrets discipline: the cookie value is never printed — length only. The
 * profile directory is a credential store and is gitignored.
 */
import { chromium } from "playwright";
import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildCookieHeader, buildSession } from "./session.mjs";
import {
  PROFILE_DIRNAME,
  extractXsrf,
  isAuthenticated,
  trySilentLogin,
} from "./login-flow.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ARTIFACTS = path.join(__dirname, "..", "artifacts");
const PROFILE_DIR = path.join(ARTIFACTS, PROFILE_DIRNAME);
const BASE_URL = process.env.BS_BASE_URL ?? "https://purdue.brightspace.com";

/** Generous: a human has to find their phone and approve a push. */
const LOGIN_TIMEOUT_MS = 6 * 60 * 1000;
const POLL_MS = 2000;

const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

const context = await chromium.launchPersistentContext(PROFILE_DIR, { headless: false });
try {
  const page = context.pages()[0] ?? (await context.newPage());

  log(`opening ${BASE_URL} on the persistent profile (artifacts/profile)`);
  let authenticated = await trySilentLogin(page, context, BASE_URL, log);

  if (authenticated) {
    log("silent SSO — the Entra session covered it, no sign-in needed");
  } else {
    console.error("");
    console.error("  ┌──────────────────────────────────────────────────────────┐");
    console.error("  │  Silent SSO did not complete — sign in in the window.    │");
    console.error("  │  Pick your campus, enter your credentials, approve MFA.  │");
    console.error("  │  Answer YES to \"Stay signed in?\" so future captures      │");
    console.error("  │  are silent. Nothing is typed for you or recorded.       │");
    console.error("  └──────────────────────────────────────────────────────────┘");
    console.error("");

    const deadline = Date.now() + LOGIN_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (await isAuthenticated(page, context, BASE_URL)) {
        authenticated = true;
        break;
      }
      await page.waitForTimeout(POLL_MS);
    }
  }

  if (!authenticated) {
    log("TIMED OUT waiting for sign-in — nothing written");
    process.exitCode = 1;
  } else {
    log("authenticated: d2lSessionVal cookie + D2L.LP JS context present");
    const cookies = await context.cookies(BASE_URL);
    const csrfToken = await extractXsrf(page);
    log(csrfToken ? "XSRF token extracted" : "XSRF token NOT found");

    const session = buildSession({
      baseUrl: BASE_URL,
      cookies,
      csrfToken,
      landedUrl: page.url(),
      capturedAt: Date.now(),
    });

    const out = path.join(ARTIFACTS, "session.json");
    writeFileSync(out, JSON.stringify(session, null, 2));
    // Length only — never the value.
    log(`wrote artifacts/session.json (cookieHeader ${buildCookieHeader(cookies).length} chars)`);
  }
} finally {
  await context.close();
}
