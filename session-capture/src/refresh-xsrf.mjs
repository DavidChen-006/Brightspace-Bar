/**
 * Re-derive the XSRF token for an ALREADY-CAPTURED, still-live cookie.
 *
 * The token mint (`POST /d2l/lp/auth/oauth2/token`) answers `403 Not
 * authenticated` when the `x-csrf-token` header is missing, even with a perfectly
 * good session cookie — measured. So a capture without the token is unusable, and
 * the token is not always readable on whatever page a login happens to land on.
 *
 * This does the cheap fix: inject the saved cookies into a fresh browser context,
 * navigate to a real D2L page where the JS context is fully initialised, read the
 * token, and merge it back into session.json. No re-login, no MFA, no password.
 *
 * Read-only apart from rewriting the token field. The cookie value is never
 * printed — lengths only.
 */
import { chromium } from "playwright";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SESSION_PATH = process.env.SESSION_JSON
  ?? path.join(__dirname, "..", "artifacts", "session.json");

const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

const session = JSON.parse(readFileSync(SESSION_PATH, "utf8"));
const baseUrl = session.baseUrl;
const host = new URL(baseUrl).hostname;

const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext();
  // Re-attach the captured session. `domain`/`path` must be set explicitly:
  // Playwright rejects cookies that name neither.
  await context.addCookies(
    session.cookies.map((c) => ({ name: c.name, value: c.value, domain: host, path: "/" }))
  );
  const page = await context.newPage();

  // `/d2l/home` is a genuine D2L page, so `window.D2L.LP` is initialised there —
  // unlike the post-SSO redirect page a login may finish on.
  log("navigating to /d2l/home with the saved cookie");
  await page.goto(`${baseUrl}/d2l/home`, { waitUntil: "domcontentloaded", timeout: 60_000 });

  // The JS bundle may still be attaching; poll briefly rather than assuming.
  let token = null;
  for (let attempt = 0; attempt < 10 && !token; attempt++) {
    token = await page
      .evaluate(() => {
        try {
          const t = window.D2L?.LP?.Web?.Authentication?.Xsrf?.GetXsrfToken?.();
          if (t) return t;
        } catch {
          /* fall through to the meta tag */
        }
        return document.querySelector('meta[name="d2l-xsrf-token"]')?.getAttribute("content") ?? null;
      })
      .catch(() => null);
    if (!token) await page.waitForTimeout(1000);
  }

  if (!token) {
    log("XSRF token NOT found — the cookie may have died, or D2L changed where it lives");
    process.exitCode = 1;
  } else {
    session.csrfToken = token;
    writeFileSync(SESSION_PATH, JSON.stringify(session, null, 2));
    log(`XSRF token extracted (${token.length} chars) and merged into session.json`);
  }
} finally {
  await browser.close();
}
