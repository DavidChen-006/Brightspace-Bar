// E2E: acquire a FRESH Brightspace session cookie via headed Entra SSO.
//
// The single expensive act (headed browser + human-approved MFA) happens once in
// beforeAll; the two tests below map 1:1 to SPEC.md's "Assertions" section and
// assert only on the observable contract: artifacts/session.json plus a live
// whoami call. The implementation (src/acquire-session.mjs) owns all browser
// driving; this file owns the verification.

import { beforeAll, describe, expect, it } from "vitest";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { acquireSession } from "../src/acquire-session.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const artifactsDir = path.resolve(__dirname, "..", "artifacts");
const sessionPath = path.join(artifactsDir, "session.json");
const baseUrl = "https://purdue.brightspace.com";

// A human approves MFA mid-run; allow 5 minutes of human time plus slack.
const TEST_TIMEOUT_MS = 300_000;
const ACQUIRE_TIMEOUT_MS = 330_000;

function log(msg) {
  process.stderr.write(`[${new Date().toISOString()}] [test] ${msg}\n`);
}

/** Arrange/Act state shared by both assertions (one acquisition per run). */
let runStart; // ms epoch recorded immediately before the acquisition
let priorCookieValues; // Set of cookie values from a previous run's session.json
let session; // parsed artifacts/session.json written by acquireSession

describe("fresh Brightspace session cookie via headed Entra SSO", () => {
  beforeAll(async () => {
    // Arrange — credentials come only from the environment (SPEC: fail fast).
    const email = process.env.BS_EMAIL;
    const password = process.env.BS_PASSWORD;
    if (!email || !password) {
      throw new Error(
        "BS_EMAIL and BS_PASSWORD must be set in the environment. " +
          "Run: BS_EMAIL='you@purdue.edu' BS_PASSWORD='...' npm test " +
          "(never put them in a .env file)."
      );
    }
    mkdirSync(artifactsDir, { recursive: true });

    // Arrange — remember any prior run's cookie values BEFORE they are overwritten,
    // so freshness can assert the new session is not a carry-over.
    priorCookieValues = new Set();
    if (existsSync(sessionPath)) {
      try {
        const prior = JSON.parse(readFileSync(sessionPath, "utf8"));
        for (const c of prior.cookies ?? []) priorCookieValues.add(c.value);
        log(
          `prior artifacts/session.json found (${priorCookieValues.size} cookie value(s)); ` +
            "the new session must differ from all of them"
        );
      } catch {
        log("prior artifacts/session.json exists but is unreadable; skipping carry-over check");
      }
    }

    // Act — the one expensive action. Record runStart first so the freshness
    // assertion has something to compare capturedAt against.
    runStart = Date.now();
    log("ACTION REQUIRED: a Chromium window will open and log in automatically.");
    log("When prompted, approve the Microsoft Authenticator request on your phone.");
    await acquireSession({ email, password, baseUrl, artifactsDir, log });

    session = JSON.parse(readFileSync(sessionPath, "utf8"));
  }, ACQUIRE_TIMEOUT_MS);

  it(
    "captures non-empty d2lSessionVal, d2lSecureSessionVal, and csrfToken (SPEC assertion 1)",
    () => {
      // Assert
      const byName = Object.fromEntries(
        (session.cookies ?? []).map((c) => [c.name, c.value])
      );
      expect(byName.d2lSessionVal, "d2lSessionVal cookie value").toBeTruthy();
      expect(byName.d2lSecureSessionVal, "d2lSecureSessionVal cookie value").toBeTruthy();
      expect(session.csrfToken, "csrfToken").toBeTruthy();
      // cookieHeader must be directly usable as an HTTP Cookie header.
      expect(session.cookieHeader).toContain("d2lSessionVal=");
      expect(session.cookieHeader).toContain("d2lSecureSessionVal=");
    },
    TEST_TIMEOUT_MS
  );

  it(
    "captured cookie is fresh: minted this run, not carried over, and live right now (SPEC assertion 2)",
    async () => {
      // Assert — fresh in time: captured during THIS run.
      expect(
        session.capturedAt,
        "capturedAt must fall within this test run"
      ).toBeGreaterThanOrEqual(runStart);

      // Assert — not a carried-over session from a prior run's session.json.
      for (const c of session.cookies ?? []) {
        expect(
          priorCookieValues.has(c.value),
          `cookie ${c.name} must differ from the prior run's value`
        ).toBe(false);
      }

      // Act + Assert — the clause that actually matters: the cookie is LIVE.
      // whoami with ONLY the Cookie header must return 200 with an Identifier.
      const res = await fetch(`${session.baseUrl}/d2l/api/lp/1.62/users/whoami`, {
        headers: { Cookie: session.cookieHeader },
        redirect: "manual", // a dead cookie 302s to login; that must fail, not follow
      });
      expect(res.status, "whoami HTTP status with only the Cookie header").toBe(200);
      const body = await res.json();
      expect(body.Identifier, "whoami response Identifier").toBeTruthy();
      log(`whoami OK — Identifier=${body.Identifier}`);
    },
    TEST_TIMEOUT_MS
  );
});
