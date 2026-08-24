/**
 * The measurement: with ZERO human input, can the persistent profile walk the
 * whole lineage?
 *
 *   Entra cookie → (silent SSO) → d2lSessionVal → (page load) → XSRF
 *                → (POST mint) → JWT → (Bearer call) → whoami 200
 *
 * Headless by default (HEADED=1 to watch). Run it any time; run it DAILY to
 * measure the Entra session's real lifetime instead of trusting any README.
 * Every run appends one JSONL line to artifacts/journal.jsonl. Outcomes:
 *
 *   already-alive     the D2L cookie in the profile was still valid — no SSO
 *                     exercised. Uninteresting for the hypothesis; rerun later.
 *   silent-sso        D2L cookie was dead, Microsoft was visited, and we landed
 *                     authenticated with no human. THE RESULT WE ARE HUNTING.
 *   password-required the flow stalled on a password field: the Entra session
 *                     itself is dead. The date gap since seed = wristband life.
 *   mfa-required      password was not asked but MFA was — partial silence.
 *   stalled           none of the above within the deadline; screenshot saved.
 *
 * The only interaction this script permits itself is clicking "Yes" on the
 * "Stay signed in?" page — that requires no secret and no human, and declining
 * to click it would fail runs for a reason we don't care about.
 *
 * Secrets discipline: cookie values, tokens, and JWTs are never written to the
 * journal or the console — statuses and lengths only.
 */
import { chromium } from "playwright";
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ARTIFACTS = path.join(__dirname, "..", "artifacts");
// PROFILE=<name> selects a sibling profile under artifacts/ (default "profile").
// Exists for the token-succession test: freeze a copy of the profile, mint a
// new Entra token in the original, then run the attempt against the frozen
// copy to learn whether the OLD token was revoked by the new login.
const PROFILE_NAME = process.env.PROFILE ?? "profile";
const PROFILE_DIR = path.join(ARTIFACTS, PROFILE_NAME);
const JOURNAL = path.join(ARTIFACTS, "journal.jsonl");
const BASE_URL = process.env.BS_BASE_URL ?? "https://purdue.brightspace.com";

const CLASSIFY_TIMEOUT_MS = 90_000;
const POLL_MS = 1000;

const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

/** Hours since the journal's last `seed` entry — the wristband's age. */
function hoursSinceSeed() {
  try {
    const lines = readFileSync(JOURNAL, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    const seed = lines.filter((e) => e.event === "seed").at(-1);
    if (!seed) return null;
    return Math.round((Date.now() - Date.parse(seed.ts)) / 36e5 * 10) / 10;
  } catch {
    return null;
  }
}

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

async function extractXsrf(page) {
  for (let attempt = 0; attempt < 10; attempt++) {
    const token = await page
      .evaluate(() => {
        try {
          const t = window.D2L?.LP?.Web?.Authentication?.Xsrf?.GetXsrfToken?.();
          if (t) return t;
        } catch { /* fall through */ }
        return document.querySelector('meta[name="d2l-xsrf-token"]')?.getAttribute("content") ?? null;
      })
      .catch(() => null);
    if (token) return token;
    await page.waitForTimeout(1000);
  }
  return null;
}

mkdirSync(ARTIFACTS, { recursive: true });

const context = await chromium.launchPersistentContext(PROFILE_DIR, {
  headless: process.env.HEADED !== "1",
});

const entry = {
  ts: new Date().toISOString(),
  event: "attempt",
  profile: PROFILE_NAME,
  hoursSinceSeed: hoursSinceSeed(),
  visitedMicrosoft: false,
  campusClicked: false,
  kmsiClicked: false,
  outcome: null,
  xsrfFound: null,
  jwtMintStatus: null,
  whoamiStatus: null,
};

try {
  const page = context.pages()[0] ?? (await context.newPage());
  page.on("framenavigated", (frame) => {
    if (frame !== page.mainFrame()) return;
    const url = frame.url();
    log(`→ ${url}`);
    if (url.includes("login.microsoftonline.com")) entry.visitedMicrosoft = true;
  });

  log(`navigating to ${BASE_URL}/d2l/home (profile age: ${entry.hoursSinceSeed ?? "?"}h since seed)`);
  await page.goto(`${BASE_URL}/d2l/home`, { waitUntil: "domcontentloaded", timeout: 60_000 })
    .catch((e) => log(`initial goto: ${e.message} — continuing to classify`));

  // Classification loop: poll until one terminal state is observed.
  const deadline = Date.now() + CLASSIFY_TIMEOUT_MS;
  while (entry.outcome === null && Date.now() < deadline) {
    if (await isAuthenticated(page, context)) {
      entry.outcome = entry.visitedMicrosoft ? "silent-sso" : "already-alive";
      break;
    }

    // Brightspace's campus selector precedes the Microsoft redirect when the
    // D2L session is dead. Choosing a campus involves no secret — permitted,
    // same as KMSI below.
    if (page.url().includes("/d2l/login")) {
      const campus = page.getByText(/Purdue West Lafayette/i).first();
      if (await campus.isVisible().catch(() => false)) {
        await campus.click().catch(() => {});
        entry.campusClicked = true;
        log("clicked the campus selector");
        await page.waitForTimeout(POLL_MS);
        continue;
      }
    }

    if (page.url().includes("login.microsoftonline.com")) {
      // "Stay signed in?" — the one permitted click (no secret involved).
      const kmsiYes = page.locator("#idSIButton9");
      if (await kmsiYes.isVisible().catch(() => false)) {
        await kmsiYes.click().catch(() => {});
        entry.kmsiClicked = true;
        log("clicked Yes on \"Stay signed in?\"");
        await page.waitForTimeout(POLL_MS);
        continue;
      }

      // Number-match / authenticator challenge → MFA is being demanded.
      const numberMatch = page.locator("#idRichContext_DisplaySign");
      if (await numberMatch.isVisible().catch(() => false)) {
        entry.outcome = "mfa-required";
        break;
      }

      // A visible password field → the Entra session itself is dead.
      const password = page.locator('input[type="password"]');
      if (await password.isVisible().catch(() => false)) {
        entry.outcome = "password-required";
        break;
      }
    }

    await page.waitForTimeout(POLL_MS);
  }

  if (entry.outcome === null) {
    entry.outcome = "stalled";
    const shot = path.join(ARTIFACTS, `stalled-${Date.now()}.png`);
    await page.screenshot({ path: shot, fullPage: true }).catch(() => {});
    log(`STALLED at ${page.url()} — screenshot saved`);
  }

  // If authenticated by any path, prove the REST of the lineage: XSRF → JWT →
  // an authenticated API answer. This is what makes the run end-to-end evidence
  // rather than "the URL looked right".
  if (entry.outcome === "silent-sso" || entry.outcome === "already-alive") {
    const xsrf = await extractXsrf(page);
    entry.xsrfFound = xsrf !== null;
    if (xsrf) {
      const cookieHeader = (await context.cookies(BASE_URL))
        .filter((c) => ["d2lSessionVal", "d2lSecureSessionVal"].includes(c.name))
        .sort((a, b) => a.name === "d2lSessionVal" ? -1 : 1)
        .map((c) => `${c.name}=${c.value}`)
        .join("; ");

      const mint = await fetch(`${BASE_URL}/d2l/lp/auth/oauth2/token`, {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          cookie: cookieHeader,
          "x-csrf-token": xsrf,
        },
        body: "scope=*:*:*",
        signal: AbortSignal.timeout(30_000),
      });
      entry.jwtMintStatus = mint.status;

      if (mint.status === 200) {
        const { access_token } = await mint.json();
        const whoami = await fetch(`${BASE_URL}/d2l/api/lp/1.31/users/whoami`, {
          headers: { authorization: `Bearer ${access_token}` },
          signal: AbortSignal.timeout(30_000),
        });
        entry.whoamiStatus = whoami.status;
      }
    }
  }
} finally {
  await context.close();
}

appendFileSync(JOURNAL, JSON.stringify(entry) + "\n");
log(`outcome: ${entry.outcome}` +
  (entry.jwtMintStatus !== null ? ` | mint ${entry.jwtMintStatus} | whoami ${entry.whoamiStatus}` : ""));

// Exit code says whether the FULL zero-human lineage was proven THIS run.
process.exitCode = entry.outcome === "silent-sso" && entry.whoamiStatus === 200 ? 0
  : entry.outcome === "already-alive" ? 0
  : 1;
