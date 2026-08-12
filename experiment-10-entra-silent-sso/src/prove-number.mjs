/**
 * PROOF: the MFA number-match digits are plain text in the DOM — no screenshot,
 * no OCR needed.
 *
 * This is the evidence behind "approach 2" (headless login + relay the number
 * to the menu bar). A NON-persistent browser is used deliberately, so the Entra
 * session cannot short-circuit the login and MFA is actually demanded.
 *
 * You type your own credentials into the visible window — this script never
 * reads, stores, or logs a credential. DevTools opens automatically so you can
 * inspect the element yourself while the script reads the same element
 * programmatically and prints it here. Three sources should agree: your eyes,
 * this terminal, and your phone.
 *
 * The browser stays open until you press Enter, so nothing vanishes mid-inspect.
 */
import { chromium } from "playwright";

const BASE_URL = process.env.BS_BASE_URL ?? "https://purdue.brightspace.com";
const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

// The classic Entra number-match element, plus fallbacks in case the tenant
// renders a newer template. Order matters: most specific first.
const NUMBER_SELECTORS = [
  "#idRichContext_DisplaySign",
  "[data-testid='displaySign']",
  ".displaySign",
  "#idDiv_RemoteNGC_DisplaySign",
];

const browser = await chromium.launch({
  headless: false,
  args: ["--auto-open-devtools-for-tabs"],
});
try {
  // Non-persistent context: a fresh cookie jar, so Entra treats this as a new
  // device and the full password + MFA ceremony is required.
  const context = await browser.newContext();
  const page = await context.newPage();

  log(`opening ${BASE_URL} in a FRESH (non-persistent) browser`);
  await page.goto(`${BASE_URL}/d2l/home`, { waitUntil: "domcontentloaded", timeout: 60_000 });

  console.error("");
  console.error("  ┌────────────────────────────────────────────────────────────┐");
  console.error("  │  Sign in yourself: campus → email → password.              │");
  console.error("  │  Nothing is typed for you; no credential is read here.     │");
  console.error("  │                                                            │");
  console.error("  │  When the two-digit number appears, this terminal will     │");
  console.error("  │  print what it read STRAIGHT OUT OF THE DOM.               │");
  console.error("  │  Compare: screen vs terminal vs phone.                     │");
  console.error("  └────────────────────────────────────────────────────────────┘");
  console.error("");

  // Poll for the number for up to 5 minutes.
  const deadline = Date.now() + 5 * 60 * 1000;
  let found = null;
  while (Date.now() < deadline && !found) {
    for (const selector of NUMBER_SELECTORS) {
      const locator = page.locator(selector).first();
      if (await locator.isVisible().catch(() => false)) {
        const text = (await locator.textContent().catch(() => null))?.trim();
        if (text) {
          found = { selector, text };
          break;
        }
      }
    }
    // Last-ditch: any element whose whole text is exactly two digits, inside
    // the Microsoft login page. Proves readability even if the id changed.
    if (!found && page.url().includes("login.microsoftonline.com")) {
      const scanned = await page
        .evaluate(() => {
          for (const el of document.querySelectorAll("div, span, strong, h1, h2")) {
            const t = el.textContent?.trim() ?? "";
            if (/^\d{2}$/.test(t) && el.children.length === 0) {
              return { text: t, id: el.id || null, cls: el.className || null };
            }
          }
          return null;
        })
        .catch(() => null);
      if (scanned) found = { selector: `scan(id=${scanned.id}, class=${scanned.cls})`, text: scanned.text };
    }
    if (!found) await page.waitForTimeout(500);
  }

  console.error("");
  if (found) {
    console.error("  ╔════════════════════════════════════════════════════════════╗");
    console.error(`  ║  READ FROM THE DOM: ${found.text.padEnd(38)}║`);
    console.error(`  ║  via selector: ${found.selector.slice(0, 43).padEnd(43)}║`);
    console.error("  ║                                                            ║");
    console.error("  ║  Plain text. No screenshot, no OCR. A headless browser     ║");
    console.error("  ║  could read this and relay it to the menu bar.             ║");
    console.error("  ╚════════════════════════════════════════════════════════════╝");
  } else {
    console.error("  No number-match element found (timed out, or the tenant used");
    console.error("  a different challenge — push-approve without a number).");
  }
  console.error("");

  log("browser stays open — inspect freely. Press Enter here to close.");
  await new Promise((resolve) => process.stdin.once("data", resolve));
} finally {
  await browser.close();
}
