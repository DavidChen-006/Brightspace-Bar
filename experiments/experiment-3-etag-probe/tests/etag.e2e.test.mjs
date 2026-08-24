/**
 * Experiment 3 — Does Brightspace honour HTTP conditional requests?
 *
 * The probe module (src/etag-probe.mjs) owns the network and the classification.
 * This test owns orchestration, observability (run.log), the artifact
 * (findings.json), and the assertions.
 *
 * "Green" means we DETERMINED the truth — not that ETags work. A clean run
 * concluding "no validator headers at all" is a complete success. A dead cookie
 * is likewise a result: the ETag assertions SKIP, they do not fail.
 */

import { describe, it, expect, beforeAll } from 'vitest';
import { readFileSync, existsSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  runEtagExperiment,
  CLASSIFICATIONS,
  VERDICTS,
} from '../src/etag-probe.mjs';

const SESSION_JSON =
  process.env.SESSION_JSON ?? '../experiment-1-fresh-cookie/artifacts/session.json';
const RUN_LOG = fileURLToPath(new URL('../artifacts/run.log', import.meta.url));
const FINDINGS_JSON = fileURLToPath(new URL('../artifacts/findings.json', import.meta.url));
const PACKAGE_JSON = fileURLToPath(new URL('../package.json', import.meta.url));

// --- Observability: capture every probe line, mirror to stderr, flush to disk.
const logLines = [];
function log(line) {
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

// The run, populated once in beforeAll and asserted on below.
const state = { result: null, sessionExpired: false };

beforeAll(async () => {
  try {
    if (!existsSync(SESSION_JSON)) {
      throw new Error('Run experiment 1 first — session.json is missing.');
    }
    const session = JSON.parse(readFileSync(SESSION_JSON, 'utf8'));

    state.result = await runEtagExperiment({ session, log });
    state.sessionExpired = state.result.outcome === 'SESSION_EXPIRED';

    if (state.sessionExpired) {
      log(
        `[${new Date().toISOString()}] !!! SESSION EXPIRED — cookie age ` +
          `${state.result.ageHours?.toFixed(2)}h. Re-run experiment 1. ETag ` +
          `assertions will be SKIPPED, not failed.`,
      );
    }

    writeFileSync(FINDINGS_JSON, JSON.stringify(state.result, null, 2) + '\n');
    log(`[${new Date().toISOString()}] FINDINGS written to ${FINDINGS_JSON}`);
  } finally {
    flushLog();
  }
}, 180_000);

// --- Structural assertion, independent of the network ----------------------

describe('Constraints', () => {
  it('no Playwright and no browser deps', () => {
    const pkg = JSON.parse(readFileSync(PACKAGE_JSON, 'utf8'));
    const deps = { ...pkg.dependencies, ...pkg.devDependencies };
    const banned = Object.keys(deps).filter((k) => /playwright|puppeteer/i.test(k));
    expect(banned).toEqual([]);
  });
});

// --- Assertion 1 holds in BOTH worlds --------------------------------------

describe('The experiment reached a determinate outcome', () => {
  it('Assertion 1: a JWT was minted, OR the run correctly identified SESSION_EXPIRED', () => {
    expect(state.result).not.toBeNull();
    if (state.sessionExpired) {
      expect(state.result.outcome).toBe('SESSION_EXPIRED');
      expect(typeof state.result.ageHours).toBe('number');
    } else {
      expect(state.result.outcome).toBe('OK');
      expect(state.result.jwtLen).toBeGreaterThan(0);
    }
  });
});

// --- Assertions 2–5 are ETag-specific: they SKIP on a dead cookie ----------

describe('Conditional-request behaviour (skipped if the cookie is dead)', () => {
  // beforeAll has already run by the time these bodies execute, so we skip at
  // RUNTIME via the test context — skipIf would be evaluated too early (before
  // we know whether the cookie was alive).
  const skipIfDead = (ctx) => {
    if (state.sessionExpired) ctx.skip();
  };

  it('Assertion 2: every endpoint has a baseline with a recorded status', (ctx) => {
    skipIfDead(ctx);
    for (const r of state.result.endpoints) {
      expect(typeof r.baseline.status).toBe('number');
    }
  });

  it('Assertion 3: every endpoint carries an allowed classification', (ctx) => {
    skipIfDead(ctx);
    for (const r of state.result.endpoints) {
      expect(CLASSIFICATIONS).toContain(r.classification);
    }
  });

  it('Assertion 4: an overall verdict exists and is one of the allowed values', (ctx) => {
    skipIfDead(ctx);
    expect(VERDICTS).toContain(state.result.verdict);
  });

  it('Assertion 5: any observed 304 is trustworthy — its bogus control returned 200', (ctx) => {
    skipIfDead(ctx);
    for (const r of state.result.endpoints) {
      const observed304 =
        r.etagConditional?.status === 304 || r.dateConditional?.status === 304;
      if (observed304) {
        expect(r.bogusControl?.status).toBe(200);
      }
    }
  });
});
