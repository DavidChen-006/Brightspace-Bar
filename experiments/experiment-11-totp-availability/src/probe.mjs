/**
 * Experiment 11 — does Purdue's Entra tenant permit a TOTP method?
 *
 * TOTP (time-based one-time password) is the only known path to k=0: a local
 * secret + the clock produce the 6-digit code, so a script can authenticate
 * with no phone and no human. Whether it is OFFERED is tenant policy, not our
 * choice — this probe finds out.
 *
 * STRICTLY READ-ONLY. It enumerates what Microsoft offers on the Security Info
 * page and stops. It never adds, removes, or changes an authentication method:
 * changing how an account signs in is the human's decision, not an agent's.
 *
 * Auth: reuses the persistent profile (experiment 10) so no password is needed.
 * Microsoft may still demand fresh MFA for security-info — the probe reports
 * that as `reauth-required` rather than trying to satisfy it.
 *
 * Output: artifacts/journal.jsonl (one line, method names only) plus
 * screenshots for eyeball confirmation.
 */
import { chromium } from "playwright";
import { appendFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ARTIFACTS = path.join(__dirname, "..", "artifacts");
const PROFILE_DIR = path.join(ARTIFACTS, "profile");
const JOURNAL = path.join(ARTIFACTS, "journal.jsonl");
const SECURITY_INFO = "https://mysignins.microsoft.com/security-info";

const HEADED = process.env.HEADED === "1";
const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

/** TOTP goes by several names in Microsoft's UI, depending on template age. */
const TOTP_PATTERNS = [
  /authenticator app/i,
  /software oath/i,
  /verification code/i,
  /third-?party/i,
];

mkdirSync(ARTIFACTS, { recursive: true });

const context = await chromium.launchPersistentContext(PROFILE_DIR, { headless: !HEADED });
const entry = {
  ts: new Date().toISOString(),
  event: "totp-probe",
  reachedSecurityInfo: false,
  addMethodOpened: false,
  offeredMethods: [],
  totpOffered: null,
  outcome: null,
};

try {
  const page = context.pages()[0] ?? (await context.newPage());
  page.on("framenavigated", (f) => {
    if (f === page.mainFrame()) log(`→ ${f.url()}`);
  });

  log(`opening ${SECURITY_INFO} with the persistent Entra session`);
  await page
    .goto(SECURITY_INFO, { waitUntil: "domcontentloaded", timeout: 60_000 })
    .catch((e) => log(`navigation: ${e.message}`));

  // Let redirects settle, then WAIT FOR THE SPA TO RENDER. The URL settling on
  // mysignins means nothing — the page is a single-page app that paints blank
  // for seconds. Poll until the body carries real text.
  await page.waitForTimeout(3000);
  for (let i = 0; i < 30; i++) {
    const length = await page
      .evaluate(() => document.body?.innerText?.trim().length ?? 0)
      .catch(() => 0);
    if (length > 150) break;
    await page.waitForTimeout(1000);
  }
  await page.screenshot({ path: path.join(ARTIFACTS, "01-landed.png") }).catch(() => {});

  // Did Microsoft demand fresh proof for this sensitive page?
  // Entra's step-up wall can also appear as a METHOD PICKER ("Verify your
  // identity") rather than a password box or a number. Its option list is
  // itself evidence — it enumerates what this tenant accepts — so record it,
  // then choose the push option to get through.
  const pickerOptions = await page
    .evaluate(() =>
      [...document.querySelectorAll('button, a[role="button"], [role="button"], [role="listitem"]')]
        .map((b) => b.textContent?.trim())
        .filter((t) => t && t.length > 2 && t.length < 60)
    )
    .catch(() => []);
  if (pickerOptions.some((o) => /verify your identity/i.test(o)) ||
      (await page.getByText(/verify your identity/i).first().isVisible().catch(() => false))) {
    entry.stepUpMethodsOffered = [...new Set(pickerOptions)];
    entry.totpAcceptedForVerification = entry.stepUpMethodsOffered.some((o) =>
      /verification code/i.test(o)
    );
    log(`step-up method picker offers: ${JSON.stringify(entry.stepUpMethodsOffered)}`);

    if (HEADED) {
      const push = page.getByRole("button", { name: /approve a request/i }).first();
      if (await push.isVisible().catch(() => false)) {
        await push.click().catch(() => {});
        log("chose the push-approval method — APPROVE IT ON YOUR PHONE (up to 3 min)");
        await page
          .waitForURL((u) => u.toString().includes("mysignins.microsoft.com/security-info"), {
            timeout: 180_000,
          })
          .catch(() => log("did not clear the step-up wall in 3 minutes"));
        for (let i = 0; i < 30; i++) {
          const length = await page
            .evaluate(() => document.body?.innerText?.trim().length ?? 0)
            .catch(() => 0);
          if (length > 150) break;
          await page.waitForTimeout(1000);
        }
        await page.screenshot({ path: path.join(ARTIFACTS, "01c-after-stepup.png") }).catch(() => {});
      }
    }
  }

  const passwordVisible = await page
    .locator('input[type="password"]')
    .first()
    .isVisible()
    .catch(() => false);
  const numberMatch = await page
    .locator("#idRichContext_DisplaySign")
    .first()
    .isVisible()
    .catch(() => false);

  if (passwordVisible || numberMatch) {
    entry.reauthDemanded = passwordVisible ? "password" : "number-match";
    if (!HEADED) {
      entry.outcome = "reauth-required";
      log(
        `Microsoft demanded fresh authentication (${entry.reauthDemanded}) — security-info ` +
          "is a step-up surface (ngcmfa). Rerun with HEADED=1 and approve to continue."
      );
    } else {
      // The number is plain text in the DOM (proven in experiment 10) — show it
      // here so the human does not have to look at the browser window.
      const digits = await page
        .locator("#idRichContext_DisplaySign")
        .first()
        .textContent()
        .catch(() => null);
      console.error("");
      console.error("  ╔══════════════════════════════════════════════════════╗");
      console.error(`  ║  APPROVE ON YOUR PHONE${digits ? ` — the number is ${digits.trim().padEnd(3)}` : ""}${digits ? "".padEnd(9) : "".padEnd(22)}║`);
      console.error("  ╚══════════════════════════════════════════════════════╝");
      console.error("");
      log("waiting up to 3 minutes for approval…");
      await page
        .waitForURL((u) => u.toString().includes("mysignins.microsoft.com"), { timeout: 180_000 })
        .catch(() => log("did not reach Security Info within 3 minutes"));
      await page.waitForTimeout(4000);
      await page.screenshot({ path: path.join(ARTIFACTS, "01b-after-reauth.png") }).catch(() => {});
    }
  }

  if (entry.outcome !== null) {
    // already classified (headless reauth-required) — fall through to reporting
  } else if (!page.url().includes("mysignins.microsoft.com")) {
    entry.outcome = "blocked";
    log(`did not reach the Security Info page (at ${page.url()})`);
  } else {
    entry.reachedSecurityInfo = true;
    log("reached Security Info with the existing session — no human needed");

    // Open the "Add sign-in method" dialog: this is where the tenant's ALLOWED
    // method list is enumerated. Opening a dialog changes nothing.
    const addButton = page
      .getByRole("button", { name: /add (sign-?in )?method/i })
      .first();
    if (await addButton.isVisible().catch(() => false)) {
      await addButton.click().catch(() => {});
      entry.addMethodOpened = true;
      await page.waitForTimeout(2500);
      await page.screenshot({ path: path.join(ARTIFACTS, "02-add-method.png") }).catch(() => {});

      // The dialog holds a <select> or a listbox. Read both shapes.
      const options = await page
        .evaluate(() => {
          const texts = new Set();
          for (const opt of document.querySelectorAll("option")) {
            const t = opt.textContent?.trim();
            if (t) texts.add(t);
          }
          for (const opt of document.querySelectorAll('[role="option"], [role="menuitem"]')) {
            const t = opt.textContent?.trim();
            if (t) texts.add(t);
          }
          return [...texts];
        })
        .catch(() => []);

      // A combobox may need opening before its options exist in the DOM.
      if (options.length === 0) {
        const combo = page.getByRole("combobox").first();
        if (await combo.isVisible().catch(() => false)) {
          await combo.click().catch(() => {});
          await page.waitForTimeout(1500);
          await page.screenshot({ path: path.join(ARTIFACTS, "03-dropdown.png") }).catch(() => {});
          const more = await page
            .evaluate(() =>
              [...document.querySelectorAll('option, [role="option"], [role="menuitem"]')]
                .map((o) => o.textContent?.trim())
                .filter(Boolean)
            )
            .catch(() => []);
          options.push(...more);
        }
      }

      entry.offeredMethods = [...new Set(options)];
      entry.totpOffered = entry.offeredMethods.some((m) =>
        TOTP_PATTERNS.some((p) => p.test(m))
      );
      entry.outcome = entry.offeredMethods.length ? "enumerated" : "dialog-unreadable";
    } else {
      entry.outcome = "add-button-not-found";
      log("could not find the \"Add sign-in method\" button — dumping what IS on the page:");
      const text = await page
        .evaluate(() => document.body?.innerText?.trim().slice(0, 1200) ?? "")
        .catch(() => "");
      console.error("─── page text ───");
      console.error(text || "(empty)");
      console.error("─────────────────");
      const buttons = await page
        .evaluate(() =>
          [...document.querySelectorAll('button, a[role="button"], [role="button"]')]
            .map((b) => b.textContent?.trim())
            .filter((t) => t && t.length < 60)
        )
        .catch(() => []);
      console.error(`buttons present: ${JSON.stringify(buttons)}`);
    }
  }
} finally {
  await context.close();
}

appendFileSync(JOURNAL, JSON.stringify(entry) + "\n");

console.error("");
console.error(`  outcome: ${entry.outcome}`);
if (entry.offeredMethods.length) {
  console.error("  methods this tenant offers to ADD:");
  for (const method of entry.offeredMethods) console.error(`    • ${method}`);
  console.error("");
  console.error(
    entry.totpOffered
      ? "  ✓ A TOTP-style method IS offered — k=0 is reachable."
      : "  ✗ No TOTP-style method offered — number-match relay is the ceiling."
  );
}
console.error("");
process.exitCode = entry.outcome === "enumerated" ? 0 : 1;
