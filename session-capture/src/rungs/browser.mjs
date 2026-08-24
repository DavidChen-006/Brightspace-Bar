/**
 * The far side of the browser seam: the two captures the real rungs drive.
 *
 *   silentCapture    — headless, no human, cron-safe. The Entra wristband in the
 *                      persistent profile re-mints a dead D2L session by itself
 *                      (experiment 10, which ran headless).
 *   fullLoginCapture — also headless (D3 as amended: the status-bar icon shows
 *                      the number, so the window has nothing left to display).
 *                      Tries silent first, then autofills the stored credentials
 *                      (env BS_EMAIL/BS_PASSWORD or credentials.json, via
 *                      credentials.mjs)
 *                      and waits for the human to approve the number-match on
 *                      their phone. `BSB_FULL_HEADED=1` opens a window for a
 *                      developer who wants to watch a login go by.
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
import { loadCredentials } from "../credentials.mjs";
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

/**
 * Entra's number-match digits. Plain DOM text, no screenshot and no OCR —
 * proven against the live tenant in experiment-10/src/prove-number.mjs.
 */
const DISPLAY_SIGN_SELECTOR = "#idRichContext_DisplaySign";

/** Generous: a human has to find their phone and approve the number-match. */
const MFA_TIMEOUT_MS = 5 * 60 * 1000;
const POLL_MS = 2000;

/**
 * How long a login field gets to appear, and how often it is asked. The budget
 * is generous because a slow Entra redirect is not a failure; it is bounded
 * because a field that is never coming must not cost the human the whole MFA
 * wait to discover.
 */
export const FIELD_TIMEOUT_MS = 30 * 1000;
export const FIELD_POLL_MS = 250;

/**
 * Whether a browser window opens, as a value rather than a literal buried in a
 * playwright call. Nothing opens a window except a full login that was asked
 * for one, by exactly `BSB_FULL_HEADED=1`.
 *
 * @param {string} kind — the rung kind ("silent" | "full")
 * @param {Record<string, string|undefined>} [env]
 * @returns {{headless: boolean}}
 */
export function launchOptionsFor(kind, env = process.env) {
  const headed = kind === "full" && env.BSB_FULL_HEADED === "1";
  return { headless: !headed };
}

/** No human, no window. Fails rather than waiting when the wristband is gone. */
export async function silentCapture({ profileDir, baseUrl, log }) {
  return withBrowser({ profileDir, ...launchOptionsFor("silent") }, async ({ page, context }) => {
    if (!(await trySilentLogin(page, context, baseUrl, log))) {
      return { ok: false, reason: "silent SSO did not reach an authenticated session" };
    }
    return harvest({ page, context, baseUrl, log });
  });
}

/**
 * The full login. Silent first — credentials are only touched once it fails.
 *
 * `onMfaNumber` is optional and is how the number reaches the status-bar icon:
 * it is awaited, so by the time this capture goes back to waiting for the human
 * the icon is already showing the digits. The rung owns what happens to it.
 */
export async function fullLoginCapture({ profileDir, baseUrl, log, onMfaNumber }) {
  return withBrowser({ profileDir, ...launchOptionsFor("full") }, async ({ page, context }) => {
    if (await trySilentLogin(page, context, baseUrl, log)) {
      log("silent SSO covered it — credentials never touched");
      return harvest({ page, context, baseUrl, log });
    }

    // Env first, then the stored credentials.json — one lookup, one priority.
    const credentials = loadCredentials();
    if (!credentials) {
      return {
        ok: false,
        reason:
          "silent SSO failed and no credentials found — run `make start` (it prompts and stores them) or set BS_EMAIL/BS_PASSWORD",
      };
    }
    const { email, password } = credentials;

    if (!(await autofillCredentials(page, { email, password, log }))) {
      // A step that never found its field means the login was never submitted,
      // so no number-match is coming. Falling through to the MFA wait would
      // spend five minutes on a prompt nobody's phone will ever show.
      return {
        ok: false,
        reason: "a sign-in field never appeared — the autofill did not complete",
      };
    }

    log(">>> approve the number-match on your PHONE — up to 5 minutes <<<");
    const deadline = Date.now() + MFA_TIMEOUT_MS;
    let announced = null;
    while (Date.now() < deadline) {
      // Read the number BEFORE the auth check: the digits are on the screen
      // while the page is still unauthenticated, and the check costs a round
      // trip the human should not be waiting behind.
      const number = await readDisplaySign(page);
      if (number && number !== announced) {
        // Only on a CHANGE — Entra re-mints on resend, and re-announcing the
        // same digits every 2s would restart the icon's TTL forever.
        announced = number;
        log(`number-match code on screen: ${number} — type it into your phone`);
        await onMfaNumber?.(number);
      }
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

/**
 * The number-match digits, or null when Entra is not showing any.
 *
 * Non-retrying on purpose: `isVisible` answers immediately rather than waiting
 * out a timeout, so the runs where this element NEVER appears — a password-only
 * tenant, or a silent SSO that already succeeded — pay one cheap DOM query per
 * poll and the MFA wait keeps its 2s rhythm.
 */
async function readDisplaySign(page) {
  const sign = page.locator(DISPLAY_SIGN_SELECTOR).first();
  if (!(await sign.isVisible().catch(() => false))) return null;
  const text = await sign.textContent().catch(() => null);
  return text?.trim() || null;
}

/**
 * Fill the first selector from the list to become visible, or false once the
 * budget runs out. The value is typed, never logged (D7).
 *
 * @param {object} page
 * @param {string[]} selectors
 * @param {string} value
 * @param {{label?: string, log?: (m: string) => void, timeoutMs?: number, pollMs?: number}} [options]
 * @returns {Promise<boolean>}
 */
export async function fillWhenReady(page, selectors, value, options = {}) {
  return actWhenReady(page, selectors, options, "filled", (field) => field.fill(value));
}

/**
 * Click the first selector from the list to become visible, or false once the
 * budget runs out.
 *
 * @param {object} page
 * @param {string[]} selectors
 * @param {{label?: string, log?: (m: string) => void, timeoutMs?: number, pollMs?: number}} [options]
 * @returns {Promise<boolean>}
 */
export async function clickWhenReady(page, selectors, options = {}) {
  // The click that submits navigates, which can detach the element out from
  // under playwright after the press already landed. The press happened; a
  // detached element afterwards is not information this caller can act on.
  return actWhenReady(page, selectors, options, "clicked", (button) =>
    button.click().catch(() => {}),
  );
}

/**
 * Poll the whole selector list on a cadence and act on the first candidate that
 * reports itself visible.
 *
 * Polling rather than `locator.waitFor()`: the lists exist because the field's
 * name varies by tenant, and waiting on each candidate in turn would serialize
 * their timeouts — the last name in the list would only get looked at after the
 * first had spent the entire budget.
 */
async function actWhenReady(page, selectors, options, verb, act) {
  const {
    label = selectors[0],
    log = () => {},
    timeoutMs = FIELD_TIMEOUT_MS,
    pollMs = FIELD_POLL_MS,
  } = options;
  const deadline = Date.now() + timeoutMs;
  do {
    for (const selector of selectors) {
      const target = page.locator(selector).first();
      if (await target.isVisible().catch(() => false)) {
        await act(target);
        log(`${verb} ${label}`);
        return true;
      }
    }
    await page.waitForTimeout(pollMs);
  } while (Date.now() < deadline);
  log(`no visible element for ${label} after ${timeoutMs}ms`);
  return false;
}

/**
 * The four-step choreography: email, next, password, submit. Each step happens
 * because the previous one did and because its field reported itself there, so
 * a page that went somewhere unexpected ends here with a `false` instead of a
 * password typed into whatever was on screen.
 *
 * @param {object} page
 * @param {{email: string, password: string, log?: (m: string) => void,
 *          timeoutMs?: number, pollMs?: number}} credentials
 * @returns {Promise<boolean>} true only when all four steps ran
 */
export async function autofillCredentials(page, { email, password, log, timeoutMs, pollMs }) {
  const budget = { log, timeoutMs, pollMs };
  const secret = { ...budget, label: "password (value not logged)" };
  if (!(await fillWhenReady(page, EMAIL_SELECTORS, email, { ...budget, label: "email" }))) return false;
  if (!(await clickWhenReady(page, SUBMIT_SELECTORS, { ...budget, label: "email-next" }))) return false;
  if (!(await fillWhenReady(page, PASSWORD_SELECTORS, password, secret))) return false;
  return clickWhenReady(page, SUBMIT_SELECTORS, { ...budget, label: "password-submit" });
}
