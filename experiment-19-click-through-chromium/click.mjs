#!/usr/bin/env node
/**
 * Experiment 19 — the Option-1 click-through.
 *
 * QUESTION: when a deep link opens in the daemon's own (already-authenticated)
 * Chromium instead of the real browser, does it land on the Brightspace page
 * with NO login — and how long does each stage take, as a user would feel it?
 *
 * WHAT IT DOES: launches the production persistent profile HEADED, navigates
 * to one deep link, prints a stage-by-stage timeline, waits out any client-side
 * redirect (the dead-session answer here is an HTTP 200 stub whose script
 * redirects to /d2l/login — measured in experiment 2, so a status check alone
 * would lie), then prints a verdict. The window stays open for live inspection.
 *
 * WHAT IT DELIBERATELY IS NOT: production code, or a wiring of the app's click
 * path. Nothing under session-capture/ or BrightspaceBar/ is imported or
 * touched — playwright is resolved out of session-capture's node_modules only
 * so this directory needs NO install of its own (the installer hangs on this
 * machine; see the playwright-install-hang note).
 *
 * RUN:  node click.mjs [url]
 *   - default url is a real recorded assignment deep link (Civics, db=648911)
 *   - BSB_ROOT overrides the root, same as everywhere else (default:
 *     ~/Library/Application Support/BrightspaceBar)
 *
 * OUT OF SCOPE by David's decision: sign-out edge cases, and the second-click-
 * while-a-window-is-open case (the profile is single-instance; a second launch
 * fails — close the window first).
 */
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { createRequire } from "node:module";
import path from "node:path";

// Resolved from session-capture's own dependency tree: same playwright, same
// version-locked browser build the daemon logs in with, zero new installs.
const require = createRequire(new URL("../session-capture/package.json", import.meta.url));
const { chromium } = require("playwright");

const DEFAULT_URL =
  "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=648911&grpid=0&ou=412690";
const deepLink = process.argv[2] ?? DEFAULT_URL;

// The load-bearing fix: a RAW deep link on a cold page-session lands on
// Brightspace's manual /d2l/login page and stops. The SAML initiate-login URL
// instead jumps straight into Shibboleth -> Entra (warm in this profile) and
// carries the deep link across as `target`, landing on the page with no click.
// Pass RAW=1 to test the naive raw-deep-link path instead.
const SAML_ENTITY = "https://idp.purdue.edu/idp/shibboleth";
const initiateLogin = (url) =>
  "https://purdue.brightspace.com/d2l/lp/auth/saml/initiate-login" +
  `?entityId=${encodeURIComponent(SAML_ENTITY)}&target=${encodeURIComponent(new URL(url).pathname + new URL(url).search)}`;

const target = process.env.RAW === "1" ? deepLink : initiateLogin(deepLink);

const root =
  process.env.BSB_ROOT ?? path.join(homedir(), "Library", "Application Support", "BrightspaceBar");
const profile = path.join(root, "profile");

const log = (message) => console.log(message);
const stamp = (from, to) => `${Math.round(to - from)}ms`;

if (!existsSync(profile)) {
  console.error(`no profile at ${profile}`);
  console.error("a login has to have seeded it — run the daemon once, then retry");
  process.exit(1);
}

log(`profile : ${profile}`);
log(`target  : ${target}`);
log("");

// ---------------------------------------------------------------------------
// The click, timed the way a user feels it: click → window → page → settled.
// ---------------------------------------------------------------------------
const t0 = performance.now();

let context;
try {
  // Headed on the SAME persistent profile the daemon refreshes — that is the
  // whole experiment. viewport:null hands window sizing back to the OS so the
  // page renders like a browser, not like a test.
  context = await chromium.launchPersistentContext(profile, { headless: false, viewport: null });
} catch (error) {
  console.error("launch failed — most likely the profile is in use");
  console.error("(a refresh mid-flight, or another experiment window still open)");
  console.error(String(error?.message ?? error).split("\n")[0]);
  process.exit(1);
}
const t1 = performance.now();
log(`window up            ${stamp(t0, t1)}`);

const page = context.pages()[0] ?? (await context.newPage());
await page.goto(target, { waitUntil: "domcontentloaded", timeout: 60_000 });
const t2 = performance.now();
log(`first content        ${stamp(t0, t2)}  (+${stamp(t1, t2)} after window)`);

await page.waitForLoadState("load", { timeout: 60_000 }).catch(() => {});
const t3 = performance.now();
log(`page fully loaded    ${stamp(t0, t3)}`);

// The settle: the initiate-login URL transits sso.purdue.edu and
// microsoftonline before landing back on Brightspace. Those hops are silent
// (<1s each) when the sessions are warm and a DEAD STOP when they need input.
// So poll for REST — the URL unchanged for 2s — rather than snapshot at a
// fixed time, or a mid-redirect frame reads as a false login wall.
const inTransit = (u) =>
  u.hostname.includes("microsoftonline") ||
  u.hostname.includes("live.com") ||
  u.hostname === "sso.purdue.edu" ||
  u.pathname.startsWith("/d2l/login");

let last = page.url();
let restSince = performance.now();
while (performance.now() - restSince < 2000 && performance.now() - t2 < 20_000) {
  await page.waitForTimeout(400);
  const now = page.url();
  if (now !== last) {
    last = now;
    restSince = performance.now();
  }
}
const t4 = performance.now();

const settled = new URL(page.url());
const loginWall = inTransit(settled);

log(`settled              ${stamp(t0, t4)}  at ${settled.origin}${settled.pathname}`);
log("");
if (loginWall) {
  log("VERDICT: LOGIN WALL — the profile's session did not carry the click.");
  log("(is the session live? run the daemon's refresh, then retry)");
} else {
  log("VERDICT: LANDED AUTHENTICATED — no login.");
  log(`user-felt cost: click → page in ${stamp(t0, t3)}`);
}
log("");
log("the window stays open — inspect it live; close it (or Ctrl+C) to finish");

await new Promise((resolve) => {
  context.on("close", resolve);
  process.on("SIGINT", () => context.close().then(resolve, resolve));
});
