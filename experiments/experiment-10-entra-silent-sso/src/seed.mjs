/**
 * Seed the PERSISTENT browser profile with one full human login.
 *
 * This is the wristband ceremony: a headed Chromium opens on a persistent
 * `userDataDir` (unlike every earlier capture script, which launched amnesiac
 * browsers and threw the Entra session away). You sign in completely — campus,
 * credentials, MFA — and when Microsoft asks "Stay signed in?", answer YES:
 * that page is exactly the offer of a persistent Entra cookie, and this
 * experiment is about whether that cookie can silently mint D2L sessions later.
 *
 * No credential is typed for you, read, stored, or logged. The profile
 * directory that results DOES hold live auth cookies — it is gitignored and
 * must stay that way.
 *
 * On success this records a `seed` line in artifacts/journal.jsonl with the
 * NAMES and EXPIRY DATES (never values) of the Entra cookies that now exist,
 * so we know what the wristband claims about its own lifetime.
 */
import { chromium } from "playwright";
import { appendFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ARTIFACTS = path.join(__dirname, "..", "artifacts");
const PROFILE_DIR = path.join(ARTIFACTS, "profile");
const JOURNAL = path.join(ARTIFACTS, "journal.jsonl");
const BASE_URL = process.env.BS_BASE_URL ?? "https://purdue.brightspace.com";

const LOGIN_TIMEOUT_MS = 6 * 60 * 1000;
const POLL_MS = 2000;

const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

/** POSITIVE auth check — cookie present AND D2L JS context reachable. */
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

mkdirSync(PROFILE_DIR, { recursive: true });

const context = await chromium.launchPersistentContext(PROFILE_DIR, { headless: false });
try {
  const page = context.pages()[0] ?? (await context.newPage());

  log(`opening ${BASE_URL} on the PERSISTENT profile at artifacts/profile`);
  await page.goto(BASE_URL, { waitUntil: "domcontentloaded", timeout: 60_000 });

  console.error("");
  console.error("  ┌────────────────────────────────────────────────────────────┐");
  console.error("  │  Sign in in the window that just opened.                   │");
  console.error("  │  Campus → credentials → MFA, all typed by YOU.             │");
  console.error("  │                                                            │");
  console.error("  │  IMPORTANT: when asked \"Stay signed in?\" click YES.        │");
  console.error("  │  That page is the persistent Entra cookie being offered —  │");
  console.error("  │  the thing this whole experiment measures.                 │");
  console.error("  └────────────────────────────────────────────────────────────┘");
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
    log("TIMED OUT waiting for sign-in — nothing recorded");
    process.exitCode = 1;
  } else {
    // Inventory the Entra cookies the profile now holds: names + expiry only.
    // ESTSAUTHPERSISTENT is the wristband; its absence would mean "Stay signed
    // in?" was declined (or never offered) and silent SSO is unlikely to work.
    const entraCookies = (await context.cookies("https://login.microsoftonline.com"))
      .map((c) => ({
        name: c.name,
        expires: c.expires > 0 ? new Date(c.expires * 1000).toISOString() : "session",
      }));

    const entry = {
      ts: new Date().toISOString(),
      event: "seed",
      entraCookies,
      hasPersistentEntraCookie: entraCookies.some((c) => c.name === "ESTSAUTHPERSISTENT"),
    };
    appendFileSync(JOURNAL, JSON.stringify(entry) + "\n");

    log(`authenticated — profile seeded`);
    log(`Entra cookies now in profile: ${entraCookies.map((c) => c.name).join(", ")}`);
    log(
      entry.hasPersistentEntraCookie
        ? "ESTSAUTHPERSISTENT present — the wristband exists"
        : "WARNING: no ESTSAUTHPERSISTENT — was \"Stay signed in?\" answered Yes?"
    );
    log("journal: seed recorded. Run `npm run attempt` after the D2L cookie dies (~tomorrow).");
  }
} finally {
  await context.close();
}
