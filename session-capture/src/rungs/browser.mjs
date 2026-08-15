/**
 * The far side of the browser seam: the two captures the real rungs drive.
 *
 *   silentCapture    — headless, no human, cron-safe. The Entra wristband in the
 *                      persistent profile re-mints a dead D2L session by itself
 *                      (experiment 10, which ran headless).
 *   fullLoginCapture — headed. Tries silent first, then autofills
 *                      BS_EMAIL/BS_PASSWORD and waits for the human to approve
 *                      the number-match on their phone (D3).
 *
 * playwright is imported LAZILY, inside the call. `refresh.mjs --help` builds
 * both rungs on the way to parsing argv, and a top-level import would make the
 * one command a human runs to read the usage text pay for a browser bundle.
 *
 * The autofill choreography below is a deliberate copy of `auto-capture.mjs`'s,
 * not an extraction: that script is a standalone CLI with its own artifacts
 * path, and rewriting it to hand its flow over would put a working capture tool
 * at risk for no gain here. The login MECHANICS both share — silent SSO, the
 * auth check, the XSRF read — are already extracted in `login-flow.mjs` and are
 * imported, not duplicated.
 *
 * Secrets discipline: the password is typed into the page and never logged;
 * cookies leave through the return value only.
 */
import { mkdirSync } from "node:fs";
import {
  clickThroughSilentSurfaces,
  extractXsrf,
  isAuthenticated,
  trySilentLogin,
} from "../login-flow.mjs";

// Entra selectors vary by tenant; try each in turn (proven in experiment 1).
const EMAIL_SELECTORS = ["input[type=email]", "input[name=loginfmt]"];
const PASSWORD_SELECTORS = ["input[type=password]", "input[name=passwd]"];
const SUBMIT_SELECTORS = ["#idSIButton9", "input[type=submit]", "button[type=submit]"];

/** Generous: a human has to find their phone and approve the number-match. */
const MFA_TIMEOUT_MS = 5 * 60 * 1000;
const POLL_MS = 2000;

/** No human, no window. Fails rather than waiting when the wristband is gone. */
export async function silentCapture({ profileDir, baseUrl, log }) {
  return withBrowser({ profileDir, headless: true }, async ({ page, context }) => {
    if (!(await trySilentLogin(page, context, baseUrl, log))) {
      return { ok: false, reason: "silent SSO did not reach an authenticated session" };
    }
    return harvest({ page, context, baseUrl, log });
  });
}

/** The headed login. Silent first — credentials are only touched once it fails. */
export async function fullLoginCapture({ profileDir, baseUrl, log }) {
  return withBrowser({ profileDir, headless: false }, async ({ page, context }) => {
    if (await trySilentLogin(page, context, baseUrl, log)) {
      log("silent SSO covered it — credentials never touched");
      return harvest({ page, context, baseUrl, log });
    }

    const email = process.env.BS_EMAIL;
    const password = process.env.BS_PASSWORD;
    if (!email || !password) {
      return { ok: false, reason: "silent SSO failed and BS_EMAIL/BS_PASSWORD are not set" };
    }

    await fillFirst(page, EMAIL_SELECTORS, email, "email", log);
    await clickFirst(page, SUBMIT_SELECTORS, "email-next", log);
    await page.waitForTimeout(POLL_MS);
    await fillFirst(page, PASSWORD_SELECTORS, password, "password (value not logged)", log);
    await clickFirst(page, SUBMIT_SELECTORS, "password-submit", log);

    log(">>> approve the number-match on your PHONE — up to 5 minutes <<<");
    const deadline = Date.now() + MFA_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (await isAuthenticated(page, context, baseUrl)) {
        return harvest({ page, context, baseUrl, log });
      }
      // "Stay signed in? → Yes" is what keeps future runs silent.
      await clickThroughSilentSurfaces(page, log);
      await page.waitForTimeout(POLL_MS);
    }
    return { ok: false, reason: "timed out waiting for the MFA approval" };
  });
}

/**
 * One persistent-profile browser, always closed. The profile directory IS the
 * credential store — the ~90-day Entra wristband lives in it — so it is created
 * on first use rather than required to exist.
 */
async function withBrowser({ profileDir, headless }, drive) {
  const { chromium } = await import("playwright");
  mkdirSync(profileDir, { recursive: true });
  const context = await chromium.launchPersistentContext(profileDir, { headless });
  try {
    const page = context.pages()[0] ?? (await context.newPage());
    return await drive({ page, context });
  } finally {
    await context.close();
  }
}

/** What an authenticated page is worth: the cookies, the XSRF token, where it landed. */
async function harvest({ page, context, baseUrl, log }) {
  const cookies = await context.cookies(baseUrl);
  const csrfToken = await extractXsrf(page);
  log(csrfToken ? "XSRF token extracted" : "XSRF token NOT found");
  return { ok: true, cookies, csrfToken, landedUrl: page.url() };
}

/** Fill the first visible selector from the list. */
async function fillFirst(page, selectors, value, label, log) {
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
async function clickFirst(page, selectors, label, log) {
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
