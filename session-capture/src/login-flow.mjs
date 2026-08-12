/**
 * The login mechanics BOTH capture scripts share, extracted so the silent-SSO
 * upgrade (experiment 10) is defined in exactly one place.
 *
 * The model, proven in experiment-10-entra-silent-sso: the persistent profile
 * holds the Microsoft Entra cookie (ESTSAUTHPERSISTENT, ~90-day lifetime), and
 * a dead D2L session re-mints itself against it with zero human input:
 *
 *   Entra cookie → (silent SSO) → d2lSessionVal → (page load) → XSRF → JWT
 *
 * So every capture now tries the silent path FIRST; only when it fails does a
 * script fall back to its own login mode (manual typing, or env-credential
 * autofill). The only clicks the silent path permits itself involve no secret:
 * the Brightspace campus selector and Microsoft's "Stay signed in? → Yes".
 */

/** Where the wristband lives. Shared by both scripts — one seed serves both. */
export const PROFILE_DIRNAME = "profile";

/**
 * POSITIVE auth check — never "the URL doesn't look like a login page".
 * Requires both the session cookie AND a reachable D2L JS context, because the
 * login stub also sets cookies.
 */
export async function isAuthenticated(page, context, baseUrl) {
  try {
    const cookies = await context.cookies(baseUrl);
    if (!cookies.some((c) => c.name === "d2lSessionVal" && c.value)) return false;
    return await page
      .evaluate(() => typeof window.D2L !== "undefined" && !!window.D2L.LP)
      .catch(() => false);
  } catch {
    return false;
  }
}

/** XSRF via D2L's own JS, falling back to the meta tag. Polls briefly. */
export async function extractXsrf(page) {
  for (let attempt = 0; attempt < 10; attempt++) {
    const token = await page
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
    if (token) return token;
    await page.waitForTimeout(1000);
  }
  return null;
}

/**
 * Click through the two no-secret surfaces that stand between a live Entra
 * cookie and an authenticated D2L page. Returns true if anything was clicked
 * (the caller should re-poll rather than conclude).
 */
export async function clickThroughSilentSurfaces(page, log) {
  // Brightspace's campus selector precedes the Microsoft redirect.
  if (page.url().includes("/d2l/login")) {
    const campus = page.getByText(/Purdue West Lafayette/i).first();
    if (await campus.isVisible().catch(() => false)) {
      await campus.click().catch(() => {});
      log("clicked the campus selector");
      return true;
    }
  }
  // "Stay signed in?" — answering Yes is what keeps the wristband persistent.
  if (page.url().includes("login.microsoftonline.com")) {
    const kmsiYes = page.locator("#idSIButton9");
    if (await kmsiYes.isVisible().catch(() => false)) {
      await kmsiYes.click().catch(() => {});
      log('clicked Yes on "Stay signed in?"');
      return true;
    }
  }
  return false;
}

/**
 * The silent path: navigate to /d2l/home and give the SSO chain a bounded
 * window to complete with no human. Returns true iff it landed authenticated.
 */
export async function trySilentLogin(page, context, baseUrl, log, timeoutMs = 30_000) {
  await page
    .goto(`${baseUrl}/d2l/home`, { waitUntil: "domcontentloaded", timeout: 60_000 })
    .catch((e) => log(`initial navigation: ${e.message} — continuing`));

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await isAuthenticated(page, context, baseUrl)) return true;
    await clickThroughSilentSurfaces(page, log);
    await page.waitForTimeout(1000);
  }
  return false;
}
