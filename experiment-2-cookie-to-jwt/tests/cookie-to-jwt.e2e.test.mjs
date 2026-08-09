/**
 * Experiment 2 — Cookie -> JWT -> authenticated GET, over pure HTTP.
 *
 * End-to-end proof, run once in beforeAll and asserted on in focused tests.
 * Priorities defended:
 *   1. Authenticity of the auth flow (whoami.Identifier === jwt.sub is the crux).
 *   2. The pure-HTTP constraint (no Playwright — asserted structurally).
 *
 * The seam (mintJwt/callApi) does the HTTP only. Decoding, assertions, and
 * observability live HERE.
 */

import { describe, it, expect, beforeAll } from 'vitest';
import { readFileSync, existsSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { mintJwt, callApi } from '../src/mint-and-call.mjs';

// --- Paths ------------------------------------------------------------------

const SESSION_JSON =
  process.env.SESSION_JSON ?? '../experiment-1-fresh-cookie/artifacts/session.json';
const RUN_LOG = fileURLToPath(new URL('../artifacts/run.log', import.meta.url));
const FINDINGS_JSON = fileURLToPath(new URL('../artifacts/findings.json', import.meta.url));
const PACKAGE_JSON = fileURLToPath(new URL('../package.json', import.meta.url));

const WHOAMI_PATH = '/d2l/api/lp/1.62/users/whoami';
const ENROLLMENTS_PATH =
  '/d2l/api/lp/1.62/enrollments/myenrollments/?orgUnitTypeId=3&isActive=true';
const HOME_PATH = '/d2l/home';

// --- Small independent helpers (source of truth = the SPEC, not the impl) ----

/** base64url-decode a JWT's middle segment and JSON-parse it. */
function decodeJwtPayload(jwt) {
  const parts = String(jwt).split('.');
  if (parts.length !== 3) {
    throw new Error(`expected 3 JWT segments, got ${parts.length}`);
  }
  let b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
  while (b64.length % 4 !== 0) b64 += '=';
  return JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
}

const nowSeconds = () => Math.floor(Date.now() / 1000);
const byteLen = (v) => (v == null ? 0 : Buffer.byteLength(JSON.stringify(v)));

/**
 * The token endpoint and /d2l/home do NOT return 401/403 when the cookie is
 * dead — they return HTTP 200 with an HTML stub that JS-redirects to
 * /d2l/login?sessionExpired=1. So a 200 is never on its own proof of success:
 * success at the token endpoint means an actual access_token came back, and
 * this recognises the refusal stub so a reader can tell "refused" from "some
 * other failure".
 */
const isSessionExpiredStub = (raw) =>
  typeof raw === 'string' && raw.includes('sessionExpired=1');

// --- Observability ----------------------------------------------------------

const logLines = [];
function stage(name, detail) {
  const line = `[${new Date().toISOString()}] ${name} ${detail}`;
  logLines.push(line);
  process.stderr.write(line + '\n');
}
function flushLog() {
  try {
    writeFileSync(RUN_LOG, logLines.join('\n') + '\n');
  } catch {
    /* best-effort */
  }
}

// --- The run: populated by beforeAll, asserted on by the tests --------------

const run = {
  mint: null, // { status, accessToken, expiresAt, raw }
  claims: null, // decoded JWT payload
  whoami: null, // { status, body }
  enroll: null, // { status, body }
};

const findings = {
  csrfRequired: null, // true | false | 'unknown'
  csrfOmittedMintStatus: null,
  csrfOmittedMintSucceeded: null, // boolean — a usable token actually came back
  csrfOmittedWasSessionStub: null, // boolean — 200 was the sessionExpired redirect stub
  mintRepeatable: null, // boolean | 'unknown'
  secondJwtDiffers: null,
  bothJwtsValid: null,
  freshXsrfObtainable: null, // boolean | 'unknown'
  freshXsrfSource: null, // 'meta' | 'js' | null
  freshXsrfWasSessionStub: null, // boolean — /d2l/home 200 was the sessionExpired stub
};

beforeAll(async () => {
  try {
    // Arrange: load the session captured by experiment 1 (fail fast if absent).
    if (!existsSync(SESSION_JSON)) {
      throw new Error('Run experiment 1 first.');
    }
    const session = JSON.parse(readFileSync(SESSION_JSON, 'utf8'));
    const { baseUrl, cookieHeader, csrfToken } = session;
    stage('SESSION', `loaded baseUrl=${baseUrl} capturedAt=${session.capturedAt}`);

    // Stage 1 — Mint.
    let t = Date.now();
    run.mint = await mintJwt({ baseUrl, cookieHeader, csrfToken });
    stage(
      'MINT',
      `POST /d2l/lp/auth/oauth2/token status=${run.mint.status} ` +
        `bytes=${byteLen(run.mint.raw)} elapsedMs=${Date.now() - t}`,
    );

    // A 200 alone is not proof: a dead cookie returns 200 + a sessionExpired
    // HTML stub with no token. Only a real token means the mint succeeded.
    const mintOk = run.mint.status === 200 && !!run.mint.accessToken;
    if (!mintOk) {
      stage(
        'MINT',
        `no usable access_token (sessionStub=${isSessionExpiredStub(run.mint.raw)}) ` +
          `— skipping decode/spend; assertions will fail`,
      );
    }

    // Stage 2 — Decode (claims only; never the token itself).
    if (mintOk) {
      run.claims = decodeJwtPayload(run.mint.accessToken);
      stage(
        'DECODE',
        `jwtLen=${String(run.mint.accessToken).length} ` +
          `sub=${run.claims.sub} scope=${run.claims.scope} ` +
          `exp=${run.claims.exp} nbf=${run.claims.nbf} ` +
          `lifetime=${run.claims.exp - run.claims.nbf}s`,
      );
    }

    // Stage 3 — Spend: whoami (strong cross-check) then enrollments (weak).
    if (mintOk) {
      t = Date.now();
      run.whoami = await callApi({ baseUrl, jwt: run.mint.accessToken, path: WHOAMI_PATH });
      stage(
        'SPEND whoami',
        `GET ${WHOAMI_PATH} status=${run.whoami.status} ` +
          `bytes=${byteLen(run.whoami.body)} elapsedMs=${Date.now() - t}`,
      );

      t = Date.now();
      run.enroll = await callApi({ baseUrl, jwt: run.mint.accessToken, path: ENROLLMENTS_PATH });
      const items = run.enroll.body?.Items ?? [];
      stage(
        'SPEND enrollments',
        `GET ${ENROLLMENTS_PATH} status=${run.enroll.status} ` +
          `courses=${items.length} bytes=${byteLen(run.enroll.body)} elapsedMs=${Date.now() - t}`,
      );
      for (const e of items) {
        stage('COURSE', `id=${e?.OrgUnit?.Id} name=${e?.OrgUnit?.Name}`);
      }
    }

    // --- Secondary questions: determine, never throw, record outcomes -------

    // Q1: Is x-csrf-token required? Repeat the mint with the header omitted.
    try {
      const noCsrf = await mintJwt({ baseUrl, cookieHeader, csrfToken: null });
      // Success is a usable token, NOT a 200 — the endpoint returns 200 + an
      // HTML sessionExpired stub when it refuses the request.
      const noCsrfOk = noCsrf.status === 200 && !!noCsrf.accessToken;
      findings.csrfOmittedMintStatus = noCsrf.status;
      findings.csrfOmittedMintSucceeded = noCsrfOk;
      findings.csrfOmittedWasSessionStub = isSessionExpiredStub(noCsrf.raw);
      findings.csrfRequired = !noCsrfOk;
      stage(
        'FINDING csrf',
        `omittedMintStatus=${noCsrf.status} succeeded=${noCsrfOk} ` +
          `sessionStub=${findings.csrfOmittedWasSessionStub} required=${findings.csrfRequired}`,
      );
    } catch (err) {
      findings.csrfRequired = 'unknown';
      stage('FINDING csrf', `unknown (${err.message})`);
    }

    // Q2: Is the mint repeatable? Mint twice, compare, validate both.
    try {
      const again = await mintJwt({ baseUrl, cookieHeader, csrfToken });
      const firstOk = run.mint.status === 200 && !!run.mint.accessToken;
      const secondOk = again.status === 200 && !!again.accessToken;
      findings.secondJwtDiffers =
        firstOk && secondOk ? again.accessToken !== run.mint.accessToken : 'unknown';
      let bothValid = false;
      if (firstOk && secondOk) {
        try {
          decodeJwtPayload(run.mint.accessToken);
          decodeJwtPayload(again.accessToken);
          bothValid = true;
        } catch {
          bothValid = false;
        }
      }
      findings.bothJwtsValid = firstOk && secondOk ? bothValid : 'unknown';
      findings.mintRepeatable = firstOk && secondOk;
      stage(
        'FINDING repeatable',
        `repeatable=${findings.mintRepeatable} differs=${findings.secondJwtDiffers} bothValid=${findings.bothJwtsValid}`,
      );
    } catch (err) {
      findings.mintRepeatable = 'unknown';
      stage('FINDING repeatable', `unknown (${err.message})`);
    }

    // Q3: Can a fresh XSRF token be obtained over plain HTTP from the cookie alone?
    try {
      const res = await fetch(`${baseUrl}${HOME_PATH}`, {
        method: 'GET',
        headers: { cookie: cookieHeader },
      });
      const html = await res.text();
      // A dead cookie yields 200 + the sessionExpired stub here too, so a 200
      // is not proof we were authenticated. Only trust a token from a real page.
      const wasStub = isSessionExpiredStub(html);
      const metaHit = /<meta[^>]+name=["']d2l-xsrf-token["'][^>]*>/i.test(html);
      const jsHit = /["']?[Xx]srf(?:Token)?["']?\s*[:=]\s*["'][^"']+["']/.test(html);
      findings.freshXsrfWasSessionStub = wasStub;
      findings.freshXsrfObtainable = !wasStub && (metaHit || jsHit);
      findings.freshXsrfSource = wasStub ? null : metaHit ? 'meta' : jsHit ? 'js' : null;
      stage(
        'FINDING xsrf',
        `homeStatus=${res.status} sessionStub=${wasStub} ` +
          `obtainable=${findings.freshXsrfObtainable} source=${findings.freshXsrfSource}`,
      );
    } catch (err) {
      findings.freshXsrfObtainable = 'unknown';
      stage('FINDING xsrf', `unknown (${err.message})`);
    }

    writeFileSync(FINDINGS_JSON, JSON.stringify(findings, null, 2) + '\n');
    stage('FINDINGS', `written to ${FINDINGS_JSON}`);
  } finally {
    flushLog();
  }
}, 120_000);

// --- Assertion 5 is structural and independent of the network: keep it apart.

describe('Pure-HTTP constraint', () => {
  it('Assertion 5: Playwright is never a dependency of this experiment', () => {
    const pkg = JSON.parse(readFileSync(PACKAGE_JSON, 'utf8'));
    const deps = { ...pkg.dependencies, ...pkg.devDependencies };
    const playwrightKeys = Object.keys(deps).filter((k) => /playwright/i.test(k));
    expect(playwrightKeys).toEqual([]);
  });
});

describe('Cookie -> JWT -> authenticated GET (e2e)', () => {
  it('Assertion 1: mint returns 200 with an access_token', () => {
    expect(run.mint.status).toBe(200);
    expect(typeof run.mint.accessToken).toBe('string');
    expect(run.mint.accessToken.length).toBeGreaterThan(0);
  });

  it('Assertion 2: JWT decodes; scope is *:*:*, lifetime is 3600s, exp is in the future', () => {
    expect(run.claims, 'mint produced no JWT to decode').not.toBeNull();
    expect(run.claims.scope).toBe('*:*:*');
    expect(run.claims.exp - run.claims.nbf).toBe(3600);
    expect(run.claims.exp).toBeGreaterThan(nowSeconds());
  });

  it('Assertion 3 (crux): whoami returns 200 AND its Identifier equals the JWT sub', () => {
    expect(run.whoami, 'mint produced no token to spend').not.toBeNull();
    expect(run.whoami.status).toBe(200);
    // The strongest available proof the token is genuinely ours and accepted.
    expect(String(run.whoami.body.Identifier)).toBe(String(run.claims.sub));
  });

  it('Assertion 4: myenrollments returns 200 with an Items array', () => {
    expect(run.enroll, 'mint produced no token to spend').not.toBeNull();
    expect(run.enroll.status).toBe(200);
    expect(Array.isArray(run.enroll.body.Items)).toBe(true);
  });
});

describe('Secondary questions (determined, not gated on the outcome)', () => {
  it('Finding: whether x-csrf-token is required was determined', () => {
    expect(findings.csrfRequired).not.toBeNull();
  });

  it('Finding: whether the mint is repeatable was determined', () => {
    expect(findings.mintRepeatable).not.toBeNull();
  });

  it('Finding: whether a fresh XSRF token is obtainable over plain HTTP was determined', () => {
    expect(findings.freshXsrfObtainable).not.toBeNull();
  });
});
