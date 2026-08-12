/**
 * Credential-autofill session capture: try the SILENT path first, and only
 * when that fails, type BS_EMAIL/BS_PASSWORD into the Microsoft login and
 * wait for the human's MFA approval — then harvest the cookie.
 *
 * Provenance: the autofill flow originates in
 * `experiment-1-fresh-cookie/src/acquire-session.mjs`, where it was written
 * and proven. That folder is a frozen experiment record; this is the live
 * port, upgraded with the persistent profile + silent SSO from experiment 10.
 *
 * Why this exists alongside manual-capture.mjs: this one types the password
 * for you, so the only human act left on a full login is the MFA number-match
 * on your phone. The cost is that it needs credentials in the environment —
 * which puts the password into shell history and into the transcript of any
 * agent that runs it. Prefer manual-capture from an agent's shell.
 *
 * PERSISTENT PROFILE (experiment 10): both scripts share artifacts/profile,
 * so a live Entra session makes this script finish silently WITHOUT touching
 * credentials — BS_EMAIL/BS_PASSWORD are only required once the silent path
 * has actually failed. A cron can therefore run it with no environment at
 * all, and it only errors on the rare day a real login is due.
 *
 * Secrets discipline: the password is typed into the page and never logged;
 * cookie values are printed as lengths only; the profile directory is a
 * credential store and is gitignored.
 */
import { chromium } from "playwright";
import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildCookieHeader, buildSession } from "./session.mjs";
import {
  PROFILE_DIRNAME,
  clickThroughSilentSurfaces,
  extractXsrf,
  isAuthenticated,
  trySilentLogin,
} from "./login-flow.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ARTIFACTS = path.join(__dirname, "..", "artifacts");
const PROFILE_DIR = path.join(ARTIFACTS, PROFILE_DIRNAME);
const BASE_URL = process.env.BS_BASE_URL ?? "https://purdue.brightspace.com";

// Entra selectors vary by tenant; try each in turn (proven in experiment 1).
const EMAIL_SELECTORS = ["input[type=email]", "input[name=loginfmt]"];
const PASSWORD_SELECTORS = ["input[type=password]", "input[name=passwd]"];
const SUBMIT_SELECTORS = ["#idSIButton9", "input[type=submit]", "button[type=submit]"];

/** Generous: a human has to find their phone and approve the number-match. */
const MFA_TIMEOUT_MS = 5 * 60 * 1000;
const POLL_MS = 2000;

const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

/** Fill the first visible selector from the list. Returns true on success. */
async function fillFirst(page, selectors, value, label) {
  for (const selector of selectors) {
    const field = page.locator(selector).first();
    if (await field.isVisible().catch(() => false)) {
      await field.fill(value);
      log(`filled ${label}`);
      return true;
    }
  }
  log(`no visible field for ${label}`);
  return false;
}

/** Click the first visible selector from the list. */
async function clickFirst(page, selectors, label) {
  for (const selector of selectors) {
    const button = page.locator(selector).first();
    if (await button.isVisible().catch(() => false)) {
      await button.click().catch(() => {});
      log(`clicked ${label}`);
      return true;
    }
  }
  return false;
}

const context = await chromium.launchPersistentContext(PROFILE_DIR, { headless: false });
try {
  const page = context.pages()[0] ?? (await context.newPage());

  log(`opening ${BASE_URL} on the persistent profile (artifacts/profile)`);
  let authenticated = await trySilentLogin(page, context, BASE_URL, log);

  if (authenticated) {
    log("silent SSO — the Entra session covered it, credentials never touched");
  } else {
    // Only NOW are credentials required — the silent path has really failed.
    const email = process.env.BS_EMAIL;
    const password = process.env.BS_PASSWORD;
    if (!email || !password) {
      log("silent SSO failed and BS_EMAIL/BS_PASSWORD are not set — cannot log in.");
      log("Either export credentials, or run `npm run capture` and sign in yourself.");
      process.exitCode = 1;
    } else {
      if (!page.url().includes("login.microsoftonline.com")) {
        log(`not on the Microsoft login (at ${page.url()}) — waiting for it`);
      }
      await fillFirst(page, EMAIL_SELECTORS, email, "email");
      await clickFirst(page, SUBMIT_SELECTORS, "email-next");
      await page.waitForTimeout(POLL_MS);
      await fillFirst(page, PASSWORD_SELECTORS, password, "password (value not logged)");
      await clickFirst(page, SUBMIT_SELECTORS, "password-submit");

      log("==============================================================");
      log(">>> approve the number-match on your PHONE — up to 5 minutes <<<");
      log("==============================================================");
      const deadline = Date.now() + MFA_TIMEOUT_MS;
      while (Date.now() < deadline) {
        if (await isAuthenticated(page, context, BASE_URL)) {
          authenticated = true;
          break;
        }
        // "Stay signed in? → Yes" keeps future runs silent.
        await clickThroughSilentSurfaces(page, log);
        await page.waitForTimeout(POLL_MS);
      }
    }
  }

  if (!authenticated) {
    if (process.exitCode !== 1) {
      log("TIMED OUT waiting for MFA approval — nothing written");
      process.exitCode = 1;
    }
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
