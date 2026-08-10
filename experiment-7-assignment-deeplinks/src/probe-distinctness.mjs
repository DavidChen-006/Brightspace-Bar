/**
 * The decisive check — and the one that nearly slipped past.
 *
 * The first pass classified a candidate as WORKS when the assignment's name appeared on
 * the rendered page. But the assignments LIST page contains every assignment's name, so
 * it scored WORKS too. "Name is present" is therefore too weak to prove a deep link:
 * it cannot tell "landed on that assignment" from "landed on a page that mentions it".
 *
 * The property that actually matters is DISTINCTNESS: folder n's link must open folder
 * n's page and not a neighbour's. So this probe visits every folder's deep link and
 * compares each page's own heading, requiring:
 *
 *   1. each page's heading matches ITS folder's name (not just contains it somewhere),
 *   2. the headings differ across folders — three links, three destinations,
 *   3. the deep-link heading differs from the list page's heading.
 *
 * Same reasoning as the app's "each course opens its own URL, never a neighbour" test:
 * with three targets, an index bug cannot pass by luck.
 *
 * Read-only navigation. Nothing submitted. Cookie never logged.
 */
import { chromium } from "playwright";
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const ARTIFACTS = path.join(ROOT, "artifacts");
const SESSION_PATH = path.join(homedir(), "Library/Application Support/BrightspaceBar/session.json");
const NAV_TIMEOUT = 30_000;

/** The template Brightspace's own UI renders (harvested in Approach B). */
const deepLink = (baseUrl, ou, db) =>
  `${baseUrl}/d2l/lms/dropbox/user/folder_submit_files.d2l?db=${db}&grpid=0&ou=${ou}`;

const TARGETS = [
  {
    ou: 440703,
    course: "Scholarly Project Milestones",
    folders: [
      { id: 445296, name: "Upload your CITI Certificate to Complete Module 2" },
      { id: 445297, name: "Report on your PURC Experience." },
      { id: 529524, name: "Getting Started on Scholarly Project Ideation" },
    ],
  },
  {
    ou: 412690,
    course: "Purdue Civics Knowledge Test",
    folders: [{ id: 648911, name: "Untitled" }],
  },
];

const log = (msg) => process.stderr.write(`[exp7-distinct] ${msg}\n`);

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
 * The page's own heading — what the page claims to be about, as opposed to any
 * name that merely appears somewhere in its body.
 */
async function heading(page) {
  for (const selector of ["h1", ".d2l-heading", "[role=heading]"]) {
    const text = await page.locator(selector).first().innerText().catch(() => "");
    if (text && text.trim()) return text.trim().replace(/\s+/g, " ").slice(0, 90);
  }
  return (await page.title().catch(() => "")).slice(0, 90);
}

async function open(page, url, shot) {
  let status = null;
  try {
    const response = await page.goto(url, { waitUntil: "domcontentloaded", timeout: NAV_TIMEOUT });
    status = response?.status() ?? null;
    await page.waitForTimeout(1200);
  } catch (error) {
    return { url, status, heading: null, error: error.message.slice(0, 100) };
  }
  const finalUrl = page.url();
  const isLogin = /login|microsoftonline|sso\.purdue|sessionExpired/i.test(finalUrl);
  const text = await heading(page);
  await page.screenshot({ path: path.join(ARTIFACTS, `${shot}.png`) }).catch(() => {});
  return { url, status, finalUrl, isLogin, heading: text, screenshot: `${shot}.png` };
}

async function main() {
  const session = JSON.parse(readFileSync(SESSION_PATH, "utf8"));
  const baseUrl = session.baseUrl;

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.addCookies(toCookies(session.cookieHeader, baseUrl));
  const page = await context.newPage();

  const results = { baseUrl, courses: [] };

  for (const target of TARGETS) {
    log(`OU ${target.ou} — list page baseline`);
    const list = await open(
      page,
      `${baseUrl}/d2l/lms/dropbox/user/folders_list.d2l?ou=${target.ou}`,
      `D-list-${target.ou}`,
    );
    log(`   list heading: ${JSON.stringify(list.heading)}`);

    const perFolder = [];
    for (const folder of target.folders) {
      const opened = await open(
        page,
        deepLink(baseUrl, target.ou, folder.id),
        `D-${target.ou}-${folder.id}`,
      );
      // Does the page's own heading name THIS folder?
      const needle = folder.name.slice(0, 20).toLowerCase();
      const headingMatchesOwn =
        !!opened.heading && opened.heading.toLowerCase().includes(needle);
      perFolder.push({ ...folder, ...opened, headingMatchesOwn });
      log(`   db=${folder.id} -> HTTP ${opened.status} heading=${JSON.stringify(opened.heading)} own=${headingMatchesOwn}`);
    }

    const headings = perFolder.map((f) => f.heading);
    const distinct = new Set(headings).size === headings.length;
    const differsFromList = headings.every((h) => h !== list.heading);
    const allOwn = perFolder.every((f) => f.headingMatchesOwn);
    const noLogin = perFolder.every((f) => !f.isLogin) && !list.isLogin;

    results.courses.push({
      ou: target.ou,
      course: target.course,
      listHeading: list.heading,
      listScreenshot: list.screenshot,
      folders: perFolder,
      checks: {
        everyHeadingNamesItsOwnFolder: allOwn,
        headingsDistinctAcrossFolders: distinct,
        deepLinkHeadingDiffersFromListPage: differsFromList,
        noLoginRedirects: noLogin,
        verdict: allOwn && distinct && differsFromList && noLogin ? "DERIVABLE" : "INCONCLUSIVE",
      },
    });
    log(`   => distinct=${distinct} differsFromList=${differsFromList} allOwn=${allOwn}`);
  }

  await browser.close();
  writeFileSync(path.join(ARTIFACTS, "approach-d-distinctness.json"), JSON.stringify(results, null, 2));
  log("wrote artifacts/approach-d-distinctness.json");
}

await main();
