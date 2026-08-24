/**
 * Experiment 3 — Does Brightspace support HTTP conditional requests?
 *
 * The seam from experiment 2 (mintJwt) does the token mint and nothing else, so
 * we reuse it as-is. But callApi throws away response headers, and headers are
 * the ENTIRE subject here — so this module owns its own header-capturing GET.
 *
 * Nothing in here logs the cookie, the CSRF token, or the JWT body. JWT length
 * only. All requests are read-only GETs except the single mint POST inside
 * mintJwt.
 */

import { mintJwt } from '../../experiment-2-cookie-to-jwt/src/mint-and-call.mjs';

const HTTP_TIMEOUT_MS = 30_000;

/** The endpoints we probe. myenrollments is the one that backs the course list. */
export const ENDPOINTS = [
  '/d2l/api/lp/1.62/users/whoami',
  '/d2l/api/lp/1.62/enrollments/myenrollments/?orgUnitTypeId=3&isActive=true',
  '/d2l/api/versions/',
];

/** Response headers we record verbatim when present. */
const CAPTURED_HEADERS = [
  'etag',
  'last-modified',
  'cache-control',
  'expires',
  'vary',
  'age',
  'x-request-id',
  'content-encoding',
];

const CLASSIFICATIONS = ['FULL_SUPPORT', 'HEADER_IGNORED', 'NO_VALIDATOR'];
const VERDICTS = ['FULL_SUPPORT', 'HEADER_IGNORED', 'NO_VALIDATOR', 'MIXED'];

/**
 * Brightspace signals auth failure as HTTP 200 + an HTML stub that JS-redirects
 * to /d2l/login?sessionExpired=1 — never 401. So a 200 is never on its own proof
 * of success. Anything keyed on status alone silently reports success on a dead
 * session; this is the guard against that.
 */
export const isSessionExpiredStub = (raw) =>
  typeof raw === 'string' && raw.includes('sessionExpired=1');

const noop = () => {};

/**
 * GET with full header capture. This is the piece experiment 2 did not expose.
 * Returns status, decoded body byte count, elapsed ms, the captured header
 * subset (verbatim), and whether the body was the sessionExpired stub.
 *
 * Byte count is of the DECODED body (undici auto-decompresses); a 304 has no
 * body and so reports 0 — which is exactly the saving we want to measure.
 */
export async function getWithHeaders({ baseUrl, jwt, path, extraHeaders = {} }) {
  const started = Date.now();
  const res = await fetch(`${baseUrl}${path}`, {
    method: 'GET',
    headers: { authorization: `Bearer ${jwt}`, ...extraHeaders },
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });
  const text = await res.text();
  const elapsedMs = Date.now() - started;

  const headers = {};
  for (const name of CAPTURED_HEADERS) {
    const v = res.headers.get(name);
    if (v != null) headers[name] = v;
  }

  return {
    status: res.status,
    bytes: Buffer.byteLength(text),
    elapsedMs,
    headers,
    isSessionStub: isSessionExpiredStub(text),
  };
}

/** Timestamped, SPEC-shaped request line. */
function reqLine(method, path, r) {
  return (
    `[${new Date().toISOString()}] ${method} ${path} → ` +
    `${r.status}, ${r.bytes} bytes, ${r.elapsedMs} ms`
  );
}

/**
 * Probe one endpoint through the four steps in the SPEC:
 *   1. baseline GET
 *   2. conditional by ETag        (only if an etag came back)
 *   3. conditional by Last-Modified (only if last-modified came back)
 *   4. bogus-validator control     (always — this is what makes a 304 trustworthy)
 *
 * Returns a self-describing record including the derived classification.
 */
export async function probeEndpoint({ baseUrl, jwt, path, log = noop }) {
  const baseline = await getWithHeaders({ baseUrl, jwt, path });
  log(reqLine('GET', path, baseline));
  log(`[${new Date().toISOString()}] HEADERS ${path} ${JSON.stringify(baseline.headers)}`);

  const record = {
    path,
    baseline,
    etagConditional: null, // { status, bytes } | null
    dateConditional: null, // { status, bytes } | null
    bogusControl: null, // { status, bytes } | null
    classification: null,
    savedBytes: null,
    savedPct: null,
    note: null,
  };

  // A baseline that came back as the sessionExpired stub means the JWT was not
  // honoured — do not derive validator conclusions from a refusal page.
  if (baseline.isSessionStub) {
    record.classification = 'NO_VALIDATOR';
    record.note = 'baseline was sessionExpired stub — result not trustworthy';
    return record;
  }

  const etag = baseline.headers['etag'];
  const lastMod = baseline.headers['last-modified'];

  // Step 2 — conditional by ETag.
  if (etag) {
    const r = await getWithHeaders({
      baseUrl,
      jwt,
      path,
      extraHeaders: { 'if-none-match': etag },
    });
    log(reqLine('GET(if-none-match)', path, r));
    record.etagConditional = { status: r.status, bytes: r.bytes };
  }

  // Step 3 — conditional by Last-Modified.
  if (lastMod) {
    const r = await getWithHeaders({
      baseUrl,
      jwt,
      path,
      extraHeaders: { 'if-modified-since': lastMod },
    });
    log(reqLine('GET(if-modified-since)', path, r));
    record.dateConditional = { status: r.status, bytes: r.bytes };
  }

  // Step 4 — bogus control. ALWAYS run it: without it an observed 304 cannot be
  // trusted, because a server that blanket-304s on any If-None-Match would look
  // identical to real support.
  {
    const r = await getWithHeaders({
      baseUrl,
      jwt,
      path,
      extraHeaders: { 'if-none-match': '"definitely-not-a-real-etag"' },
    });
    log(reqLine('GET(bogus-if-none-match)', path, r));
    record.bogusControl = { status: r.status, bytes: r.bytes };
  }

  // --- Classify -------------------------------------------------------------
  const observed304 =
    record.etagConditional?.status === 304 || record.dateConditional?.status === 304;
  const bogusIs200 = record.bogusControl?.status === 200;

  if (!etag && !lastMod) {
    record.classification = 'NO_VALIDATOR';
    record.note = 'no etag and no last-modified on the baseline response';
  } else if (observed304 && bogusIs200) {
    // A real 304, and the control proves the server actually evaluated the
    // validator rather than blindly returning 304.
    record.classification = 'FULL_SUPPORT';
    const condBytes = record.etagConditional?.status === 304
      ? record.etagConditional.bytes
      : record.dateConditional.bytes;
    record.savedBytes = baseline.bytes - condBytes;
    record.savedPct = baseline.bytes > 0 ? (record.savedBytes / baseline.bytes) * 100 : 0;
  } else if (observed304 && !bogusIs200) {
    // 304 came back but the bogus control ALSO 304'd — the value is ignored, so
    // the 304 is meaningless. Not real conditional support.
    record.classification = 'HEADER_IGNORED';
    record.note =
      `304 observed but bogus control returned ${record.bogusControl?.status} — 304 not trustworthy`;
  } else {
    // Validator header present, but a conditional re-request still returned the
    // full body. Decorative header, no saving.
    record.classification = 'HEADER_IGNORED';
    record.note = 'validator header present but conditional returned full 200 body';
  }

  return record;
}

/** Fold per-endpoint classifications into one overall verdict. */
export function deriveVerdict(records) {
  const set = new Set(records.map((r) => r.classification));
  if (set.size === 1) return [...set][0];
  return 'MIXED';
}

/**
 * The whole experiment, end to end. Returns a fully-determined result object;
 * the test asserts on it and writes the artifacts. `log(line)` receives each
 * timestamped observability line (defaults to no-op).
 */
export async function runEtagExperiment({ session, endpoints = ENDPOINTS, log = noop }) {
  const { baseUrl, cookieHeader, csrfToken, capturedAt } = session;
  const now = Date.now();
  const ageHours = capturedAt != null ? (now - capturedAt) / 3_600_000 : null;

  log(`[${new Date().toISOString()}] SESSION baseUrl=${baseUrl} capturedAt=${capturedAt} ageHours=${ageHours?.toFixed(2)}`);

  // --- Mint -----------------------------------------------------------------
  const mint = await mintJwt({ baseUrl, cookieHeader, csrfToken });
  const mintOk = mint.status === 200 && !!mint.accessToken;
  log(
    `[${new Date().toISOString()}] MINT status=${mint.status} ` +
      `jwtLen=${mint.accessToken ? mint.accessToken.length : 0} ` +
      `sessionStub=${isSessionExpiredStub(mint.raw)} ok=${mintOk}`,
  );

  // --- Dead cookie is a RESULT, not a failure -------------------------------
  if (!mintOk) {
    log(
      `[${new Date().toISOString()}] SESSION_EXPIRED cookie is dead ` +
        `(ageHours=${ageHours?.toFixed(2)}) — RE-RUN EXPERIMENT 1 to refresh session.json`,
    );
    return {
      outcome: 'SESSION_EXPIRED',
      verdict: 'SESSION_EXPIRED',
      capturedAt,
      diedWithinMs: capturedAt != null ? now - capturedAt : null,
      ageHours,
      mintStatus: mint.status,
      mintWasSessionStub: isSessionExpiredStub(mint.raw),
      endpoints: [],
    };
  }

  // --- Probe every endpoint -------------------------------------------------
  const records = [];
  for (const path of endpoints) {
    records.push(await probeEndpoint({ baseUrl, jwt: mint.accessToken, path, log }));
  }

  const verdict = deriveVerdict(records);
  log(`[${new Date().toISOString()}] VERDICT ${verdict}`);

  const totalBaselineBytes = records.reduce((s, r) => s + r.baseline.bytes, 0);
  const supported = records.filter((r) => r.classification === 'FULL_SUPPORT');
  const totalSavedBytes = supported.reduce((s, r) => s + (r.savedBytes ?? 0), 0);

  return {
    outcome: 'OK',
    verdict,
    capturedAt,
    ageHours,
    jwtLen: mint.accessToken.length,
    endpoints: records,
    totalBaselineBytes,
    totalSavedBytes,
    totalSavedPct: totalBaselineBytes > 0 ? (totalSavedBytes / totalBaselineBytes) * 100 : 0,
  };
}

export { CLASSIFICATIONS, VERDICTS };
