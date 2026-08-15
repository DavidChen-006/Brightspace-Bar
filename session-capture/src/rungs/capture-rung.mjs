/**
 * What both rungs are, minus the browser: call a capture, judge its answer, and
 * land the credential at `paths.sessionFile`.
 *
 * The rungs differ in exactly two things — the `kind` the orchestrator's
 * permission gate reads, and which capture they drive — so everything else lives
 * here once. A rung's return value is only a verdict; the actual product is the
 * session.json a fetcher can pick up on the very next call, which is why the
 * write is the part with the invariants:
 *
 *  - it lands at paths.sessionFile, in the `buildSession` shape, or the ladder
 *    climbs forever against a file nobody reads;
 *  - mode 0600, re-applied even when the file already existed, because a live
 *    D2L cookie is a login;
 *  - nothing is written at all when the capture failed — the ladder is climbed
 *    BECAUSE the session looked dead, and a failed rung must not be the thing
 *    that destroys what was there.
 *
 * D7: cookie values never reach the log; a length is the most that is ever said.
 */
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { buildSession } from "../session.mjs";

const DEFAULT_BASE_URL = "https://purdue.brightspace.com";

/**
 * @param {{kind: "silent"|"full",
 *          capture: (world: {profileDir: string, baseUrl: string,
 *                            log: (m: string) => void}) => Promise<object>,
 *          baseUrl?: string}} spec
 */
export function createCaptureRung({ kind, capture, baseUrl }) {
  // Read when the rung is BUILT, not when the module is imported, so a test (or
  // a wrapper script) can set BS_BASE_URL before wiring the ladder.
  const tenant = baseUrl ?? process.env.BS_BASE_URL ?? DEFAULT_BASE_URL;

  return {
    kind,
    /** @param {{paths: object, log: (m: string) => void}} world */
    async attempt({ paths, log }) {
      let captured;
      try {
        captured = await capture({ profileDir: paths.profileDir, baseUrl: tenant, log });
      } catch (error) {
        // A locked profile, a missing chromium: real, and not the orchestrator's
        // problem to interpret. A rung reports, it never throws.
        return { ok: false, reason: String(error?.message ?? error) };
      }
      if (!captured?.ok) {
        return { ok: false, reason: captured?.reason ?? "the capture gave no reason" };
      }

      const session = buildSession({
        baseUrl: tenant,
        cookies: captured.cookies ?? [],
        csrfToken: captured.csrfToken ?? null,
        landedUrl: captured.landedUrl ?? "",
        capturedAt: Date.now(),
      });
      // A login stub sets cookies too, so "some cookies" is not authentication.
      // Writing this as a success would be a credential file that can never work.
      if (!session.cookieHeader.includes("d2lSessionVal=")) {
        return { ok: false, reason: "the capture came back without a d2lSessionVal cookie" };
      }

      writeSession(paths.sessionFile, session);
      log(`wrote session.json (cookieHeader ${session.cookieHeader.length} chars)`);
      return { ok: true };
    },
  };
}

/** 0600, and re-applied: a rewrite must not inherit a loose mode from the old file. */
function writeSession(file, session) {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(session, null, 2)}\n`, { mode: 0o600 });
  chmodSync(file, 0o600);
}
