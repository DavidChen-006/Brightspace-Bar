/**
 * Force a LOCAL sign-out of the main profile: clear every cookie it holds
 * (Entra, Shibboleth, D2L — all of it), so the next `npm run seed` is a
 * genuine from-scratch login that mints a NEW Entra token.
 *
 * Part of the token-succession test: freeze a copy of the profile first
 * (`cp -R artifacts/profile artifacts/profile-old`), sign the original out
 * here, re-seed, then attempt against BOTH profiles to see whether the new
 * login revoked the old token server-side.
 *
 * Local-only: this clears the browser's jar; it tells no server anything.
 */
import { chromium } from "playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROFILE_DIR = path.join(__dirname, "..", "artifacts", "profile");

const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

const context = await chromium.launchPersistentContext(PROFILE_DIR, { headless: true });
try {
  const before = (await context.cookies()).length;
  await context.clearCookies();
  const after = (await context.cookies()).length;
  log(`cleared ${before - after} cookies from artifacts/profile (${after} remain)`);
} finally {
  await context.close();
}
