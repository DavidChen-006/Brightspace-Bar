/**
 * Drive a headed, NON-PERSISTENT Chromium (chromium.launch() + browser.newContext(),
 * no userDataDir) through Purdue's Entra ID login, wait for the human to approve MFA,
 * and write artifacts/session.json per SPEC.md's output contract.
 *
 * The exported function is the imperative shell: it owns all browser driving and
 * observability. The two small pure helpers below (buildCookieHeader, buildSession)
 * are the functional core — they turn captured facts into the output contract with no
 * side effects, so the shape of session.json is decided in one testable place.
 *
 * @param {object} opts
 * @param {string} opts.email        BS_EMAIL — typed into the Microsoft login form
 * @param {string} opts.password     BS_PASSWORD — typed, never logged
 * @param {string} opts.baseUrl      e.g. "https://purdue.brightspace.com"
 * @param {string} opts.artifactsDir absolute path; session.json, screenshots, run.log go here
 * @param {(msg: string) => void} opts.log timestamped stderr logger
 * @returns {Promise<void>} resolves after artifacts/session.json is written
 */
import { chromium } from "playwright";
import { appendFileSync, writeFileSync } from "node:fs";
import path from "node:path";

// A human approves MFA on their phone; allow generous time before giving up.
const MFA_TIMEOUT_MS = 5 * 60 * 1000; // 5 minutes
const NAV_TIMEOUT_MS = 30_000;
const SETTLE_POLL_MS = 2_000;

// Entra selectors vary by tenant; we try each in turn and never hard-fail on a
// missing one — the visible window lets the human finish manually.
const EMAIL_SELECTORS = ["input[type=email]", "input[name=loginfmt]"];
const PASSWORD_SELECTORS = ["input[type=password]", "input[name=passwd]"];
const SUBMIT_SELECTORS = ["#idSIButton0", "input[type=submit]", "button[type=submit]"];

// Purdue's /d2l/home redirects to a Brightspace campus-selector page, not straight
// to Microsoft. Selecting West Lafayette / Indianapolis fires the SAML redirect
// chain (sso.purdue.edu -> login.microsoftonline.com). Verified via scratch probe.
const CAMPUS_BUTTON = /Purdue West Lafayette/i;

/**
 * Pure: build a RAW HTTP Cookie header value (no "cookie:" prefix) from the two
 * D2L session cookies, in a stable order.
 * @param {{name: string, value: string}[]} cookies
 * @returns {string}
 */
export function buildCookieHeader(cookies) {
  const order = ["d2lSessionVal", "d2lSecureSessionVal"];
  return cookies
    .filter((c) => order.includes(c.name))
    .sort((a, b) => order.indexOf(a.name) - order.indexOf(b.name))
    .map((c) => `${c.name}=${c.value}`)
    .join("; ");
}

/**
 * Pure: assemble the session.json output contract.
 * @param {object} facts
 * @returns {object}
 */
export function buildSession({ baseUrl, cookies, csrfToken, landedUrl, capturedAt }) {
  return {
    capturedAt,
    baseUrl,
    cookieHeader: buildCookieHeader(cookies),
    cookies: cookies.map((c) => ({ name: c.name, value: c.value })),
    csrfToken,
    landedUrl,
  };
}

export async function acquireSession({ email, password, baseUrl, artifactsDir, log }) {
  const logPath = path.join(artifactsDir, "run.log");
  // Every line goes to the caller's stderr logger AND to artifacts/run.log.
  const record = (msg) => {
    const line = `[${new Date().toISOString()}] [acquire] ${msg}`;
    log(msg);
    try {
      appendFileSync(logPath, line + "\n");
    } catch {
      /* run.log is best-effort observability, never fatal */
    }
  };

  const shot = async (page, name) => {
    const file = path.join(artifactsDir, `${name}.png`);
    try {
      await page.screenshot({ path: file, fullPage: false });
      record(`screenshot -> ${file}`);
    } catch (err) {
      record(`screenshot ${name} failed: ${err.message}`);
    }
  };

  let browser;
  let page;
  try {
    record("launching headed, non-persistent Chromium (no userDataDir)");
    browser = await chromium.launch({
      headless: false,
      args: ["--disable-blink-features=AutomationControlled"],
    });
    const context = await browser.newContext();
    page = await context.newPage();
    page.setDefaultTimeout(NAV_TIMEOUT_MS);

    // --- Observability wiring: navigations, console, page errors, auth traffic ---
    page.on("framenavigated", (frame) => {
      if (frame === page.mainFrame()) record(`framenavigated -> ${frame.url()}`);
    });
    page.on("console", (m) => record(`page.console [${m.type()}] ${m.text()}`));
    page.on("pageerror", (e) => record(`page.pageerror ${e.message}`));
    page.on("response", (res) => {
      const url = res.url();
      if (url.includes("login.microsoftonline.com") || url.includes("purdue.brightspace.com")) {
        record(`net ${res.request().method()} ${res.status()} ${url}`);
      }
    });

    // --- Phase: start ---
    record(`navigating to ${baseUrl}/d2l/home`);
    await page.goto(`${baseUrl}/d2l/home`, { waitUntil: "load", timeout: NAV_TIMEOUT_MS });
    await shot(page, "00-start");

    // Purdue's /d2l/home is a JS stub that window.location.replace()s to login.
    // Wait for the chain to settle on a recognizable surface before acting.
    await page
      .waitForURL(
        (url) => {
          const h = url.toString();
          return (
            h.includes("login.microsoftonline.com") ||
            h.includes("/d2l/login") ||
            h.includes("/d2l/lp/auth/") ||
            /\/d2l\/home\b.*[?#]/.test(h) ||
            /\/d2l\/home\/\d/.test(h)
          );
        },
        { timeout: 15_000 }
      )
      .catch(() => record("initial redirect did not settle in 15s — continuing"));

    record(`URL after initial settle: ${page.url()}`);

    // --- Phase: campus selector (Brightspace-hosted, buttons in shadow DOM) ---
    if (page.url().includes("/d2l/login")) {
      const campus = page.getByText(CAMPUS_BUTTON, { exact: false }).first();
      if (await campus.count()) {
        await campus.click().catch((e) => record(`campus click failed: ${e.message}`));
        record("clicked campus selector: Purdue West Lafayette / Indianapolis");
        await page
          .waitForURL((u) => u.toString().includes("login.microsoftonline.com"), {
            timeout: 30_000,
          })
          .catch(() => record("did not reach login.microsoftonline.com within 30s"));
      } else {
        record("campus selector button not found — the visible window allows manual selection");
      }
    }
    record(`URL after campus selection: ${page.url()}`);

    // --- Phase: Microsoft login (email, then password on the next view) ---
    if (page.url().includes("login.microsoftonline.com")) {
      await shot(page, "01-microsoft-login");
      await waitForFirst(page, EMAIL_SELECTORS, record, "email", 30_000);
      await fillFirst(page, EMAIL_SELECTORS, email, record, "email");
      await clickFirst(page, SUBMIT_SELECTORS, record, "email-next");
      record("email submitted");

      // --- Phase: password (AzureAD reveals the password view after Next) ---
      await waitForFirst(page, PASSWORD_SELECTORS, record, "password", 60_000);
      await shot(page, "02-password");
      await fillFirst(page, PASSWORD_SELECTORS, password, record, "password");
      await clickFirst(page, SUBMIT_SELECTORS, record, "password-submit");
      record("password submitted (value not logged)");
    } else {
      record(
        "did NOT land on login.microsoftonline.com — the visible window is " +
          "available for you to drive login manually"
      );
    }

    // --- Phase: awaiting MFA (human) ---
    await shot(page, "03-awaiting-mfa");
    record("==================================================================");
    record(">>> ACTION REQUIRED: approve the Microsoft Authenticator request on <<<");
    record(">>> your PHONE now (push / number-match). Waiting up to 5 minutes.   <<<");
    record("==================================================================");

    // Poll for a POSITIVE authenticated signal, never mere "not a login URL":
    // the d2lSessionVal cookie must be present AND the D2L JS context must exist.
    // Each iteration also dismisses a "Stay signed in?" prompt if one is showing,
    // tolerating the human clicking it first.
    const deadline = Date.now() + MFA_TIMEOUT_MS;
    let authed = false;
    while (Date.now() < deadline) {
      await tryDismissStaySignedIn(page, record);
      authed = await isAuthenticated(page, context, baseUrl, record);
      if (authed) break;
      await page.waitForTimeout(SETTLE_POLL_MS);
    }
    if (!authed) {
      throw new Error(
        `Timed out after ${MFA_TIMEOUT_MS / 60000} min waiting for an authenticated ` +
          "Brightspace session (d2lSessionVal cookie + D2L JS context)."
      );
    }

    // --- Phase: landed. Make sure we are on a real D2L page with JS context. ---
    if (!/\/d2l\/home/.test(page.url())) {
      record(`navigating to ${baseUrl}/d2l/home to reach D2L JS context`);
      await page
        .goto(`${baseUrl}/d2l/home`, { waitUntil: "networkidle", timeout: NAV_TIMEOUT_MS })
        .catch(() => undefined);
    }
    await page.waitForLoadState("networkidle", { timeout: 15_000 }).catch(() => undefined);
    await shot(page, "04-landed");
    record(`landed URL: ${page.url()}`);

    // --- Capture cookies ---
    const allCookies = await context.cookies(baseUrl);
    const d2lCookies = allCookies.filter(
      (c) => c.name === "d2lSessionVal" || c.name === "d2lSecureSessionVal"
    );
    record(`captured cookies: ${d2lCookies.map((c) => c.name).join(", ") || "(none)"}`);
    const session = d2lCookies.find((c) => c.name === "d2lSessionVal");
    const secure = d2lCookies.find((c) => c.name === "d2lSecureSessionVal");
    if (!session?.value || !secure?.value) {
      throw new Error(
        "Missing required D2L session cookies after login " +
          `(d2lSessionVal present=${Boolean(session?.value)}, ` +
          `d2lSecureSessionVal present=${Boolean(secure?.value)}).`
      );
    }
    record(
      `cookie lengths: d2lSessionVal=${session.value.length}, ` +
        `d2lSecureSessionVal=${secure.value.length}`
    );

    // --- Capture XSRF token ---
    const csrfToken = await extractXsrf(page, record);
    if (!csrfToken) {
      throw new Error("Could not extract XSRF token from D2L JS context or meta tag.");
    }
    record(`csrfToken length: ${csrfToken.length}`);

    // --- Write output contract ---
    const out = buildSession({
      baseUrl,
      cookies: d2lCookies,
      csrfToken,
      landedUrl: page.url(),
      capturedAt: Date.now(),
    });
    const outPath = path.join(artifactsDir, "session.json");
    writeFileSync(outPath, JSON.stringify(out, null, 2));
    record(`wrote ${outPath} (cookieHeader length=${out.cookieHeader.length})`);
  } catch (err) {
    record(`FAILURE: ${err.message}`);
    if (page) {
      try {
        await shot(page, "99-failure");
        record(`final URL: ${page.url()}`);
        record(`page title: ${await page.title().catch(() => "(unavailable)")}`);
        const body = await page
          .evaluate(() => document.body?.innerText?.slice(0, 500) ?? "")
          .catch(() => "(unavailable)");
        record(`visible body (first 500 chars): ${body}`);
      } catch {
        /* failure diagnostics are best-effort */
      }
    }
    throw err;
  } finally {
    // Always close so no stray Chromium survives a failure.
    if (browser) {
      await browser.close().catch(() => undefined);
      record("browser closed");
    }
  }
}

/** Fill the first VISIBLE matching selector; log which one matched. */
async function fillFirst(page, selectors, value, record, label) {
  for (const sel of selectors) {
    const el = page.locator(`${sel}:visible`).first();
    if (await el.count()) {
      await el.fill(value);
      record(`filled ${label} via ${sel}`);
      return;
    }
  }
  const present = await presentSelectors(page);
  record(`no visible ${label} selector found; present inputs: ${present}`);
}

/** Click the first VISIBLE matching selector; log which one matched. */
async function clickFirst(page, selectors, record, label) {
  for (const sel of selectors) {
    const el = page.locator(`${sel}:visible`).first();
    if (await el.count()) {
      await el.click().catch((e) => record(`click ${label} via ${sel} failed: ${e.message}`));
      record(`clicked ${label} via ${sel}`);
      return;
    }
  }
  record(`no visible ${label} submit selector found`);
}

/** Wait until one of the selectors is VISIBLE; keep waiting rather than throwing. */
async function waitForFirst(page, selectors, record, label, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (const sel of selectors) {
      if (await page.locator(`${sel}:visible`).first().count()) {
        record(`${label} field visible: ${sel}`);
        return;
      }
    }
    const present = await presentSelectors(page);
    record(`waiting for ${label}; present inputs: ${present}`);
    await page.waitForTimeout(2_000);
  }
  record(`${label} field never became visible within ${timeoutMs}ms — manual fallback available`);
}

/** Diagnostic: list the input types/names currently on the page. */
async function presentSelectors(page) {
  try {
    return await page.evaluate(() =>
      Array.from(document.querySelectorAll("input"))
        .map((i) => i.type + (i.name ? `[name=${i.name}]` : ""))
        .join(", ")
    );
  } catch {
    return "(unavailable)";
  }
}

/**
 * Best-effort "Stay signed in?" dismissal, called once per poll iteration. Only
 * clicks Yes when the KMSI heading is actually showing, so it can't misfire on the
 * password page's own submit button. Tolerates the human clicking first.
 */
async function tryDismissStaySignedIn(page, record) {
  try {
    const heading = page.getByText(/Stay signed in\?/i).first();
    if (!(await heading.count())) return;
    const yes = page
      .locator("#idSIButton0:visible, input[type=submit][value='Yes']:visible")
      .first();
    if (await yes.count()) {
      await yes.click().catch(() => undefined);
      record("clicked 'Stay signed in? -> Yes'");
    }
  } catch {
    /* prompt may never appear, or the human clicked it — both fine */
  }
}

/**
 * POSITIVE authentication check: the d2lSessionVal cookie must exist AND the D2L
 * JS context must be reachable. Never trusts "URL is not a login URL".
 */
async function isAuthenticated(page, context, baseUrl, record) {
  try {
    const cookies = await context.cookies(baseUrl);
    const hasSession = cookies.some((c) => c.name === "d2lSessionVal" && c.value);
    if (!hasSession) return false;
    // Cookie exists — confirm we can reach a genuine D2L JS context (not the stub).
    const hasD2L = await page
      .evaluate(() => typeof window.D2L !== "undefined" && !!window.D2L.LP)
      .catch(() => false);
    if (hasSession && hasD2L) {
      record("authenticated signal: d2lSessionVal cookie + D2L.LP JS context present");
      return true;
    }
    return false;
  } catch {
    return false;
  }
}

/** Extract XSRF via D2L JS, falling back to the meta tag. */
async function extractXsrf(page, record) {
  const token = await page
    .evaluate(() => {
      try {
        const t = window.D2L?.LP?.Web?.Authentication?.Xsrf?.GetXsrfToken?.();
        if (t) return t;
      } catch {
        /* fall through to meta */
      }
      const meta = document.querySelector('meta[name="d2l-xsrf-token"]');
      return meta ? meta.getAttribute("content") : null;
    })
    .catch(() => null);
  record(token ? "XSRF token extracted" : "XSRF token NOT found");
  return token;
}
