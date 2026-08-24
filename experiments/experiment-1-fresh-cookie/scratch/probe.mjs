// Structural probe: headed Chromium -> purdue.brightspace.com/d2l/home, let the
// redirect chain settle, report which login selectors exist on the REAL page, and
// screenshot it. Types NO credentials. Highest-value unknown: the live Entra page.
import { chromium } from "playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(__dirname);
const baseUrl = "https://purdue.brightspace.com";
const log = (m) => process.stderr.write(`[${new Date().toISOString()}] [probe] ${m}\n`);

const EMAIL_SELECTORS = ["input[type=email]", "input[name=loginfmt]"];
const PASSWORD_SELECTORS = ["input[type=password]", "input[name=passwd]"];
const SUBMIT_SELECTORS = ["#idSIButton0", "input[type=submit]", "button[type=submit]"];

const browser = await chromium.launch({ headless: false });
try {
  const context = await browser.newContext();
  const page = await context.newPage();
  page.on("framenavigated", (f) => {
    if (f === page.mainFrame()) log(`framenavigated -> ${f.url()}`);
  });

  log(`goto ${baseUrl}/d2l/home`);
  await page.goto(`${baseUrl}/d2l/home`, { waitUntil: "load", timeout: 30000 });
  await page
    .waitForURL((u) => u.toString().includes("login.microsoftonline.com"), { timeout: 20000 })
    .catch(() => log("did not reach microsoftonline in 20s"));
  await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => undefined);

  log(`final URL: ${page.url()}`);
  log(`title: ${await page.title().catch(() => "(n/a)")}`);

  for (const [label, sels] of [
    ["email", EMAIL_SELECTORS],
    ["password", PASSWORD_SELECTORS],
    ["submit", SUBMIT_SELECTORS],
  ]) {
    for (const sel of sels) {
      const n = await page.locator(sel).first().count();
      log(`selector ${label} ${sel}: ${n ? "PRESENT" : "absent"}`);
    }
  }
  const inputs = await page
    .evaluate(() =>
      Array.from(document.querySelectorAll("input"))
        .map((i) => i.type + (i.name ? `[name=${i.name}]` : ""))
        .join(", ")
    )
    .catch(() => "(n/a)");
  log(`all inputs on page: ${inputs}`);

  const shot = path.join(outDir, "probe.png");
  await page.screenshot({ path: shot });
  log(`screenshot -> ${shot}`);
} finally {
  await browser.close();
  log("closed");
}
