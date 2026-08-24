/**
 * Open a Brightspace deep link in the daemon's already-signed-in Chromium.
 *
 * This is the daemon half of the app's `.chromium` browser target: the Swift
 * `ChromiumURLOpener` spawns `node src/browser-open.mjs <url>` on a menu click,
 * and this opens that URL in the SAME persistent profile the login ladder keeps
 * warm — so the page lands authenticated with no browser login.
 *
 * The one non-obvious move is `initiateLoginTarget`: navigating straight to a
 * raw deep link on a cold page-session lands on Brightspace's MANUAL
 * `/d2l/login` page and stops (measured — experiment 19). Wrapping the link in
 * Purdue's SAML `initiate-login` endpoint instead drives D2L -> Shibboleth ->
 * Entra and carries the deep link across as `target`, so a profile whose Entra
 * wristband is still alive re-mints the session silently and lands on the page.
 * A warm session passes straight through it, so the wrap is safe to apply
 * always and is what makes the click reliable rather than usually-fine.
 *
 * SECOND CLICKS ADD A TAB. The profile is single-instance, so a second launch
 * while the first window is open would fail. Instead, the first click launches
 * with a CDP port open (localhost only), and every later click connects to the
 * running browser over that port and opens the link as a NEW TAB — additive,
 * nothing tracked, the browser window is the only state. If nothing answers
 * the port, this IS the first click and a fresh launch happens.
 *
 * REMAINING LIMITATION (deferred by decision): a click while a headless
 * REFRESH holds the profile still fails — the refresh launches without the
 * port. It degrades to a clear message and a non-zero exit, never a crash;
 * the app treats the spawn as fire-and-forget.
 */
import { pathToFileURL } from "node:url";

/**
 * Purdue's Shibboleth IdP entityId, the one Brightspace's own login page names
 * in its campus-picker links. Hardcoded because this is a Purdue app; a
 * multi-tenant version would scrape it from `/d2l/login`.
 */
export const SAML_ENTITY_ID = "https://idp.purdue.edu/idp/shibboleth";

/**
 * A deep link, wrapped so it authenticates on the way in.
 *
 * Pure and total: parses the link, keeps only its path+query as the SAML
 * `target` (the origin is taken from the link itself, so a link to any D2L
 * host builds a matching initiate-login URL), and encodes both parameters.
 *
 * @param {string} deepLink a full Brightspace URL
 * @param {string} [entityId]
 * @returns {string} the initiate-login URL that lands on `deepLink`
 */
export function initiateLoginTarget(deepLink, entityId = SAML_ENTITY_ID) {
  const url = new URL(deepLink);
  const target = url.pathname + url.search;
  return (
    `${url.origin}/d2l/lp/auth/saml/initiate-login` +
    `?entityId=${encodeURIComponent(entityId)}&target=${encodeURIComponent(target)}`
  );
}

/**
 * The rendezvous for tab-adding: the first click launches Chromium with CDP on
 * this port (bound to localhost by Chromium itself), and later clicks find the
 * running browser here. Fixed, not discovered — a port is the whole protocol.
 */
export const CDP_PORT = Number(process.env.BSB_OPEN_CDP_PORT ?? 9223);

/**
 * Try to add `deepLink` as a new tab in an already-running view browser.
 * @returns {Promise<boolean>} true if a running browser took the tab.
 */
async function addTabToRunningBrowser(chromium, deepLink) {
  let browser;
  try {
    browser = await chromium.connectOverCDP(`http://127.0.0.1:${CDP_PORT}`, { timeout: 2_000 });
  } catch {
    return false; // Nothing listening: this is the first click.
  }
  try {
    const context = browser.contexts()[0];
    if (!context) return false;
    const page = await context.newPage();
    await page.goto(initiateLoginTarget(deepLink), { waitUntil: "domcontentloaded", timeout: 60_000 });
    return true;
  } finally {
    // Detach only — the browser and its tabs are the user's, not this
    // process's; disconnecting leaves everything on screen.
    await browser.close().catch(() => {});
  }
}

/** Open `deepLink` in the persistent profile, headed, and hold the window. */
async function openInProfile(deepLink) {
  // Imported lazily and locally so the pure function above stays importable by
  // tests without paying for playwright, paths, or a profile on disk.
  const { chromium } = await import("playwright");
  const { resolvePaths } = await import("./paths.mjs");
  const { mkdirSync } = await import("node:fs");

  // A browser from an earlier click already up? Add a tab and get out.
  if (await addTabToRunningBrowser(chromium, deepLink)) return;

  const { profileDir } = resolvePaths();
  mkdirSync(profileDir, { recursive: true });

  let context;
  try {
    context = await chromium.launchPersistentContext(profileDir, {
      headless: false,
      viewport: null,
      // Leaves the door open for every subsequent click to add its tab.
      args: [`--remote-debugging-port=${CDP_PORT}`],
    });
  } catch (error) {
    // A headless refresh holds the profile (the one launch path with no CDP
    // port), or the launch lost a race with another first click.
    console.error("could not open the browser — the profile is in use");
    console.error(String(error?.message ?? error).split("\n")[0]);
    process.exit(1);
  }

  const page = context.pages()[0] ?? (await context.newPage());
  await page.goto(initiateLoginTarget(deepLink), { waitUntil: "domcontentloaded", timeout: 60_000 });

  // The window is the user's now; hold the process open until they close it.
  await new Promise((resolve) => context.on("close", resolve));
}

// CLI only when run directly — an import (the tests) triggers no browser.
if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const deepLink = process.argv[2];
  if (!deepLink) {
    console.error("usage: node src/browser-open.mjs <brightspace-url>");
    process.exit(1);
  }
  await openInProfile(deepLink);
}
