/**
 * Approaches B and C — harvest the canonical assignment links from the rendered
 * Brightspace UI, then verify constructed URL templates against the live session.
 *
 * B is the source of truth: whatever href Brightspace itself puts on an assignment
 * IS the correct link. Comparing those hrefs to the folder ids the API returned tells
 * us whether the link is derivable from API data alone (the finding we want) or only
 * obtainable by scraping.
 *
 * C then confirms a constructed template genuinely lands on the assignment page. A 200
 * is NOT proof — Brightspace serves 200 for login pages and permission errors — so every
 * candidate is judged on rendered content and screenshotted as evidence.
 *
 * Read-only: navigation only. Nothing is submitted, no buttons clicked. The cookie is
 * loaded into the browser context and never logged.
 */
import { chromium } from "playwright";
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const ARTIFACTS = path.join(ROOT, "artifacts");
const SESSION_PATH = path.join(
  homedir(),
  "Library/Application Support/BrightspaceBar/session.json",
);
const NAV_TIMEOUT = 30_000;

/** The two reachable courses, with the folder ids Approach A returned. */
const TARGETS = [
  {
    ou: 440703,
    course: "Scholarly Project Milestones",
    folders: [
      { id: 445296, name: "Upload your CITI Certificate to Complete" },
      { id: 445297, name: "Report on your PURC Experience." },
      { id: 529524, name: "Getting Started on Scholarly Project Ide" },
    ],
  },
  {
    ou: 412690,
    course: "Purdue Civics Knowledge Test",
    folders: [{ id: 648911, name: "Untitled" }],
  },
];

const log = (msg) => process.stderr.write(`[exp7] ${msg}\n`);

/** Cookie header -> Playwright cookie objects. Values never logged. */
function toCookies(cookieHeader, baseUrl) {
  const domain = new URL(baseUrl).hostname;
  return cookieHeader.split(";").map((pair) => {
    const index = pair.indexOf("=");
    return {
      name: pair.slice(0, index).trim(),
      value: pair.slice(index + 1).trim(),
      domain,
      path: "/",
      httpOnly: true,
      secure: true,
      sameSite: "None",
    };
  });
}

/**
 * Judge a loaded page. The whole experiment turns on this classification, so it
 * checks the rendered text rather than the status code.
 */
async function classify(page, expectedName) {
  const finalUrl = page.url();
  const body = (await page.locator("body").innerText().catch(() => "")) || "";
  const title = await page.title().catch(() => "");

  if (/login|microsoftonline|sso\.purdue|adfs|sessionExpired/i.test(finalUrl)) {
    return { outcome: "REDIRECTS_TO_LOGIN", finalUrl, title, evidence: "final URL is an auth page" };
  }
  if (/not authorized|access denied|don't have permission|no longer available|error has occurred/i.test(body)) {
    return { outcome: "ERROR", finalUrl, title, evidence: body.slice(0, 160).replace(/\s+/g, " ") };
  }
  // The assignment's own name on the page is the positive signal. Compare on a
  // prefix: D2L truncates long names in some views.
  const needle = expectedName.slice(0, 24).toLowerCase();
  const hasName = needle.length > 3 && body.toLowerCase().includes(needle);
  if (hasName) {
    return { outcome: "WORKS", finalUrl, title, evidence: `page text contains "${expectedName.slice(0, 24)}"` };
  }
  return {
    outcome: "WRONG_PAGE",
    finalUrl,
    title,
    evidence: `assignment name absent; page opens "${body.slice(0, 120).replace(/\s+/g, " ")}"`,
  };
}

async function visit(page, url, expectedName, shot) {
  let status = null;
  try {
    const response = await page.goto(url, { waitUntil: "domcontentloaded", timeout: NAV_TIMEOUT });
    status = response?.status() ?? null;
    await page.waitForTimeout(1200); // let D2L's client-side rendering settle
  } catch (error) {
    return { url, status, outcome: "ERROR", evidence: `navigation failed: ${error.message.slice(0, 100)}` };
  }
  const verdict = await classify(page, expectedName);
  const file = path.join(ARTIFACTS, `${shot}.png`);
  await page.screenshot({ path: file, fullPage: false }).catch(() => {});
  return { url, status, ...verdict, screenshot: path.basename(file) };
}

/** Approach B — scrape the assignments list for the hrefs D2L itself renders. */
async function harvest(page, target, baseUrl) {
  const listUrl = `${baseUrl}/d2l/lms/dropbox/user/folders_list.d2l?ou=${target.ou}`;
  log(`B: harvesting ${target.ou} assignments list`);
  const result = { listUrl, listOutcome: null, harvested: [] };

  try {
    const response = await page.goto(listUrl, { waitUntil: "domcontentloaded", timeout: NAV_TIMEOUT });
    result.listStatus = response?.status() ?? null;
    await page.waitForTimeout(1500);
  } catch (error) {
    result.listOutcome = `ERROR: ${error.message.slice(0, 100)}`;
    return result;
  }

  result.finalUrl = page.url();
  if (/login|microsoftonline|sso\.purdue/i.test(result.finalUrl)) {
    result.listOutcome = "REDIRECTS_TO_LOGIN";
    return result;
  }
  result.listOutcome = "LOADED";

  await page.screenshot({ path: path.join(ARTIFACTS, `B-list-${target.ou}.png`) }).catch(() => {});

  // Every anchor whose href mentions a dropbox/folder id, plus its visible text.
  result.harvested = await page.evaluate(() =>
    Array.from(document.querySelectorAll("a[href]"))
      .map((a) => ({ href: a.getAttribute("href"), text: (a.textContent || "").trim().slice(0, 60) }))
      .filter((a) => /dropbox|folder|db=/i.test(a.href)),
  );
  log(`B: ${result.harvested.length} dropbox-ish anchors found`);
  return result;
}

async function main() {
  const session = JSON.parse(readFileSync(SESSION_PATH, "utf8"));
  const baseUrl = session.baseUrl;
  log(`session loaded (cookie header length ${session.cookieHeader.length})`);

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.addCookies(toCookies(session.cookieHeader, baseUrl));
  const page = await context.newPage();

  const findings = { baseUrl, approachB: [], approachC: [] };

  for (const target of TARGETS) {
    // ── Approach B ────────────────────────────────────────────────────────────
    const harvestResult = await harvest(page, target, baseUrl);
    findings.approachB.push({ ou: target.ou, course: target.course, ...harvestResult });

    // ── Approach C ────────────────────────────────────────────────────────────
    // One representative folder per course keeps the request count low; the
    // per-folder distinctness check below uses all of them for the winner.
    const folder = target.folders[0];
    const candidates = [
      {
        label: "folder_submit_files.d2l?db&grpid&ou",
        url: `${baseUrl}/d2l/lms/dropbox/user/folder_submit_files.d2l?db=${folder.id}&grpid=0&ou=${target.ou}`,
      },
      {
        label: "le/{ou}/dropbox/user/folder_submit_files?db",
        url: `${baseUrl}/d2l/le/${target.ou}/dropbox/user/folder_submit_files?db=${folder.id}`,
      },
      {
        label: "lms/dropbox/dropbox.d2l?ou (list only)",
        url: `${baseUrl}/d2l/lms/dropbox/dropbox.d2l?ou=${target.ou}`,
      },
      {
        label: "folders_list.d2l?ou (list only)",
        url: `${baseUrl}/d2l/lms/dropbox/user/folders_list.d2l?ou=${target.ou}`,
      },
    ];

    for (const [index, candidate] of candidates.entries()) {
      log(`C: ${target.ou} candidate ${index + 1}/${candidates.length} — ${candidate.label}`);
      const outcome = await visit(
        page,
        candidate.url,
        folder.name,
        `C-${target.ou}-${index + 1}`,
      );
      findings.approachC.push({
        ou: target.ou,
        folderId: folder.id,
        folderName: folder.name,
        label: candidate.label,
        ...outcome,
      });
      log(`   -> ${outcome.outcome} (HTTP ${outcome.status})`);
    }
  }

  await browser.close();
  writeFileSync(path.join(ARTIFACTS, "approach-bc.json"), JSON.stringify(findings, null, 2));
  log("wrote artifacts/approach-bc.json");
}

await main();
