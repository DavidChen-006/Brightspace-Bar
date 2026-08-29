/**
 * Experiment 20 — the cookie transplant.
 *
 * THEORY. The daemon's session.json cookies (renewed every 30 min by the
 * refresh loop, so at most 30 min old) can be injected into a browser
 * context, letting a page navigation land signed in WITHOUT touching
 * Entra at all — no SAML wrap, no SSO cookies, no KMSI. If true, the
 * browser becomes a derivation of session.json (one source of truth)
 * and the dead-Entra-session password page disappears architecturally.
 *
 * FALSIFIER. D2L might bind the session to the client (user agent /
 * fingerprint): the cookies were minted by a Node HTTP client, this
 * presents a Chromium UA. If bound, the page bounces to /d2l/login.
 *
 * METHOD. A FRESH throwaway browser context (no profile dir at all —
 * deliberately, so nothing but the injected cookies can explain a
 * signed-in page), addCookies() from session.json, then navigate
 * straight to the deep link — no initiate-login wrap.
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const here = path.dirname(fileURLToPath(import.meta.url));
const sessionFile = path.join(
  process.env.BSB_ROOT ??
    path.join(process.env.HOME, "Library/Application Support/BrightspaceBar"),
  "session.json",
);

const session = JSON.parse(readFileSync(sessionFile, "utf8"));
const base = new URL(session.baseUrl);
const ageMin = (Date.now() - Date.parse(session.capturedAt)) / 60000;
console.log(`session.json captured ${ageMin.toFixed(1)} min ago (${session.baseUrl})`);

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext(); // fresh, profile-less
await context.addCookies(
  session.cookies.map(({ name, value }) => ({
    name,
    value,
    domain: base.hostname,
    path: "/",
    secure: true,
    httpOnly: name.startsWith("d2lS"),
    sameSite: "Lax",
  })),
);

const deepLink = `${base.origin}/d2l/home`;
const page = await context.newPage();
await page.goto(deepLink, { waitUntil: "domcontentloaded", timeout: 60000 });
await page.waitForTimeout(4000);

const landed = page.url();
const title = await page.title();
const loginMarkers =
  (await page.locator('input[type="password"], input[type="email"]').count()) +
  (landed.includes("/d2l/login") ? 1 : 0) +
  (landed.includes("microsoftonline") ? 1 : 0);
const signedInMarker = await page
  .locator('.d2l-navigation-s-header, d2l-navigation, [class*="d2l-navigation"]')
  .count();

console.log("landed:", landed);
console.log("title:", title);
console.log("login markers:", loginMarkers, "| navigation chrome:", signedInMarker);

await page.screenshot({ path: path.join(here, "artifacts/landing.png"), fullPage: false });

const verdict =
  loginMarkers === 0 && landed.startsWith(base.origin) && !landed.includes("/d2l/login")
    ? "CONFIRMED"
    : "REFUTED";
console.log(`\nVERDICT: ${verdict} — transplant ${verdict === "CONFIRMED" ? "signs the browser in with no Entra involvement" : "did not produce a signed-in page"}`);

writeFileSync(
  path.join(here, "artifacts/result.json"),
  JSON.stringify({ ranAt: new Date().toISOString(), sessionAgeMin: ageMin, landed, title, loginMarkers, signedInMarker, verdict }, null, 2),
);

await browser.close();
