// Probe 2: from the Purdue campus selector, click "Purdue West Lafayette /
// Indianapolis" and observe where it lands (Microsoft Entra? Shibboleth?).
// Types NO credentials — stops as soon as the login form appears.
import { chromium } from "playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(__dirname);
const baseUrl = "https://purdue.brightspace.com";
const log = (m) => process.stderr.write(`[${new Date().toISOString()}] [probe2] ${m}\n`);

const browser = await chromium.launch({ headless: false });
try {
  const context = await browser.newContext();
  const page = await context.newPage();
  page.on("framenavigated", (f) => {
    if (f === page.mainFrame()) log(`framenavigated -> ${f.url()}`);
  });

  await page.goto(`${baseUrl}/d2l/home`, { waitUntil: "load", timeout: 30000 });
  await page.waitForURL(/\/d2l\/login/, { timeout: 20000 }).catch(() => undefined);
  await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => undefined);
  log(`campus selector URL: ${page.url()}`);

  // Try several ways to reach the campus button (it may be in shadow DOM).
  const candidates = [
    () => page.getByText("Purdue West Lafayette", { exact: false }),
    () => page.getByRole("button", { name: /West Lafayette/i }),
    () => page.getByRole("link", { name: /West Lafayette/i }),
    () => page.locator("text=Purdue West Lafayette"),
  ];
  let clicked = false;
  for (const make of candidates) {
    const loc = make().first();
    const n = await loc.count().catch(() => 0);
    log(`candidate count=${n}`);
    if (n) {
      await loc.click({ timeout: 5000 }).catch((e) => log(`click failed: ${e.message}`));
      clicked = true;
      break;
    }
  }
  log(`clicked campus button: ${clicked}`);

  // Wait to see where we land.
  await page
    .waitForURL(
      (u) => {
        const h = u.toString();
        return (
          h.includes("login.microsoftonline.com") ||
          h.includes("sso.purdue.edu") ||
          h.includes("idp.purdue.edu") ||
          h.includes("login.purdue.edu")
        );
      },
      { timeout: 25000 }
    )
    .catch(() => log("no known IdP URL within 25s"));
  await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => undefined);

  log(`landed after campus select: ${page.url()}`);
  log(`title: ${await page.title().catch(() => "(n/a)")}`);
  const inputs = await page
    .evaluate(() =>
      Array.from(document.querySelectorAll("input"))
        .map((i) => i.type + (i.name ? `[name=${i.name}]` : "") + (i.id ? `#${i.id}` : ""))
        .join(", ")
    )
    .catch(() => "(n/a)");
  log(`inputs on IdP page: ${inputs}`);
  await page.screenshot({ path: path.join(outDir, "probe2.png") });
  log(`screenshot -> ${path.join(outDir, "probe2.png")}`);
} finally {
  await browser.close();
  log("closed");
}
