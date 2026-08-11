/**
 * Manual-login session capture: open a headed browser, let the HUMAN sign in
 * completely, then harvest the cookie.
 *
 * Why this exists alongside acquire-session.mjs: that script types the password
 * itself, so it needs BS_PASSWORD in the environment. This one never sees a
 * credential at all — the operator types everything into the visible window,
 * including MFA. That makes it the only capture path safe to run from an agent's
 * shell, and it is also the closer analogue of the eventual in-app WKWebView
 * login, where the user signs in and we only read the resulting cookie store.
 *
 * The output contract is NOT reimplemented here: `buildCookieHeader` and
 * `buildSession` come from ./session.mjs, so session.json has one definition
 * across every capture path.
 *
 * GET-only: this drives navigation and reads cookies. It submits nothing.
 * Secrets discipline: the cookie value is never printed — length only.
 */
import { chromium } from "playwright";
import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildCookieHeader, buildSession } from "./session.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ARTIFACTS = path.join(__dirname, "..", "artifacts");
const BASE_URL = process.env.BS_BASE_URL ?? "https://purdue.brightspace.com";

/** Generous: a human has to find their phone and approve a push. */
const LOGIN_TIMEOUT_MS = 6 * 60 * 1000;
const POLL_MS = 2000;

const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

/**
 * POSITIVE auth check — never "the URL doesn't look like a login page".
 * Requires both the session cookie AND a reachable D2L JS context, because the
 * login stub also sets cookies.
 */
async function isAuthenticated(page, context) {
  try {
    const cookies = await context.cookies(BASE_URL);
    if (!cookies.some((c) => c.name === "d2lSessionVal" && c.value)) return false;
    return await page
      .evaluate(() => typeof window.D2L !== "undefined" && !!window.D2L.LP)
      .catch(() => false);
  } catch {
    return false;
  }
}

/** XSRF via D2L's own JS, falling back to the meta tag. */
async function extractXsrf(page) {
  return page
    .evaluate(() => {
      try {
        const t = window.D2L?.LP?.Web?.Authentication?.Xsrf?.GetXsrfToken?.();
        if (t) return t;
      } catch {
        /* fall through */
      }
      return document.querySelector('meta[name="d2l-xsrf-token"]')?.getAttribute("content") ?? null;
    })
    .catch(() => null);
}

const browser = await chromium.launch({ headless: false });
try {
  const context = await browser.newContext();
  const page = await context.newPage();

  log(`opening ${BASE_URL}`);
  await page.goto(BASE_URL, { waitUntil: "domcontentloaded", timeout: 60_000 });

  console.error("");
  console.error("  ┌──────────────────────────────────────────────────────────┐");
  console.error("  │  Sign in in the browser window that just opened.         │");
  console.error("  │  Pick your campus, enter your credentials, approve MFA.   │");
  console.error("  │  Nothing is typed for you and nothing is recorded.        │");
  console.error("  └──────────────────────────────────────────────────────────┘");
  console.error("");

  const deadline = Date.now() + LOGIN_TIMEOUT_MS;
  let authenticated = false;
  while (Date.now() < deadline) {
    if (await isAuthenticated(page, context)) {
      authenticated = true;
      break;
    }
    await page.waitForTimeout(POLL_MS);
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
  await browser.close();
}
